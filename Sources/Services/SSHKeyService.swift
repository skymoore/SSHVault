import Foundation
import AppKit

/// Represents an SSH key pair found on disk
struct SSHKeyInfo: Identifiable, Hashable {
    let id: String  // filename of private key
    let privateKeyPath: String
    let publicKeyPath: String?
    let keyType: String
    let fingerprint: String
    let comment: String
    var isLoadedInAgent: Bool = false

    var name: String { id }
    var hasPublicKey: Bool { publicKeyPath != nil }
}

/// A key that exists in the agent but has no corresponding file in ~/.ssh/
/// (e.g. smartcard / YubiKey keys loaded via gpg-agent)
struct AgentKeyInfo: Identifiable, Hashable {
    let id: String      // fingerprint — unique per key
    let fingerprint: String
    let comment: String
    let keyType: String
    let bits: Int
    let publicKey: String?  // full OpenSSH public key line from ssh-add -L, if available
}

/// Manages SSH keys in ~/.ssh/
final class SSHKeyService {
    static let shared = SSHKeyService()

    private let sshDir: URL
    private let fm = FileManager.default

    private init() {
        sshDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    // MARK: - Agent Socket Resolution

    /// Resolves the SSH agent socket path using a priority-ordered search:
    /// 1. User-configured custom path (Settings)
    /// 2. SSH_AUTH_SOCK environment variable
    /// 3. gpg-agent socket via `gpgconf --list-dirs agent-ssh-socket`
    /// 4. Well-known ~/.gnupg/S.gpg-agent.ssh
    /// 5. macOS launchd ssh-agent  (/private/tmp/com.apple.launchd.*/Listeners)
    /// 6. User-session ssh-agent   (/tmp/ssh-*/agent.*)
    func resolveAgentSocket() -> String? {
        let prefs = TerminalPreferences.shared

        // 1. User-configured custom path
        let custom = prefs.customAgentSocket.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let expanded = expandTilde(custom)
            if fm.fileExists(atPath: expanded) { return expanded }
        }

        // 2. SSH_AUTH_SOCK env var (set when launched from a shell)
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           fm.fileExists(atPath: sock) {
            return sock
        }

        // 3. gpgconf (covers non-default GNUPGHOME locations)
        if let gpgSocket = runShell("gpgconf --list-dirs agent-ssh-socket"),
           fm.fileExists(atPath: gpgSocket) {
            return gpgSocket
        }

        // 4. Default gpg-agent socket location
        let gnupg = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".gnupg/S.gpg-agent.ssh").path
        if fm.fileExists(atPath: gnupg) { return gnupg }

        // 5. macOS launchd-managed ssh-agent (socket path changes each boot)
        if let sock = glob(pattern: "/private/tmp/com.apple.launchd.*/Listeners").first {
            return sock
        }

        // 6. User-session ssh-agent started manually (Linux convention, also works on macOS)
        if let sock = glob(pattern: "/tmp/ssh-*/agent.*").first {
            return sock
        }

        return nil
    }

    /// Returns a human-readable label for the resolved socket, e.g. "gpg-agent" or "ssh-agent"
    func agentLabel(for socketPath: String) -> String {
        if socketPath.contains("gpg-agent") || socketPath.contains(".gnupg") {
            return "gpg-agent"
        }
        return "ssh-agent"
    }

    /// Expands a glob pattern and returns matching paths that exist as socket files.
    private func glob(pattern: String) -> [String] {
        var gl = glob_t()
        defer { globfree(&gl) }
        guard Foundation.glob(pattern, GLOB_TILDE, nil, &gl) == 0 else { return [] }
        return (0 ..< Int(gl.gl_matchc)).compactMap { i in
            guard let path = gl.gl_pathv[i].map({ String(cString: $0) }) else { return nil }
            // Confirm it's actually a socket (not just any file)
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
            return path
        }
    }

    /// Check if an SSH agent is accessible
    func isAgentRunning() -> Bool {
        resolveAgentSocket() != nil
    }

    // MARK: - Key Discovery

    /// Scan ~/.ssh/ for key pairs
    func listKeys() -> [SSHKeyInfo] {
        guard let files = try? fm.contentsOfDirectory(atPath: sshDir.path) else {
            return []
        }

        let pubFiles = Set(files.filter { $0.hasSuffix(".pub") })
        var keys: [SSHKeyInfo] = []

        let knownKeyNames: Set<String> = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
        let skipFiles: Set<String> = ["config", "config.bak", "config.tmp", "known_hosts",
                                       "known_hosts.old", "authorized_keys", "environment"]

        for file in files.sorted() {
            if file.hasPrefix(".") || file.hasSuffix(".pub") || skipFiles.contains(file) { continue }

            let hasPub  = pubFiles.contains(file + ".pub")
            let isKnown = knownKeyNames.contains(file)

            if hasPub || isKnown {
                let privatePath = sshDir.appendingPathComponent(file).path
                let publicPath  = hasPub ? sshDir.appendingPathComponent(file + ".pub").path : nil
                let info = getKeyInfo(name: file, privatePath: privatePath, publicPath: publicPath)
                keys.append(info)
            }
        }

        // Mark file keys that are also loaded in the agent
        let loadedFingerprints = agentFingerprints()
        for i in keys.indices {
            if loadedFingerprints.contains(keys[i].fingerprint) {
                keys[i].isLoadedInAgent = true
            }
        }

        return keys
    }

    /// Returns all keys currently in the agent that have NO corresponding file in ~/.ssh/.
    /// These are smartcard / YubiKey / hardware token keys.
    func listAgentOnlyKeys(fileKeys: [SSHKeyInfo]) -> [AgentKeyInfo] {
        let fileFingerprints = Set(fileKeys.map { $0.fingerprint })
        return listRawAgentKeys().filter { !fileFingerprints.contains($0.fingerprint) }
    }

    /// Returns all keys reported by the agent (ssh-add -l + -L), regardless of file presence.
    func listRawAgentKeys() -> [AgentKeyInfo] {
        guard let sock = resolveAgentSocket() else { return [] }

        var agentEnv = ProcessInfo.processInfo.environment
        agentEnv["SSH_AUTH_SOCK"] = sock

        func run(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            p.arguments = args
            p.environment = agentEnv
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()
            try? p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }

        guard let listOutput = run(["-l"]) else { return [] }
        let pubOutput = run(["-L"])   // best-effort; nil if agent doesn't support it

        let pubLines = pubOutput?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        return parseAgentKeys(listOutput, publicKeys: pubLines)
    }

    /// Returns the set of fingerprints in the agent (for fast matching against file keys).
    private func agentFingerprints() -> Set<String> {
        Set(listRawAgentKeys().map { $0.fingerprint })
    }

    // MARK: - Parsing

    /// Parse `ssh-add -l` output, optionally zipping with `ssh-add -L` public key lines.
    /// Both commands output keys in the same order, so we can match by index.
    private func parseAgentKeys(_ output: String, publicKeys: [String] = []) -> [AgentKeyInfo] {
        // Each line: "256 SHA256:xxx comment (ED25519)"
        var result: [AgentKeyInfo] = []
        var keyIndex = 0
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: " ")
            guard parts.count >= 2,
                  let bits = Int(parts[0]),
                  parts[1].hasPrefix("SHA256:") else { continue }

            let fingerprint = parts[1]

            var keyType = "unknown"
            if let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") {
                keyType = String(last.dropFirst().dropLast())
            }

            let comment: String
            if parts.count >= 3 {
                comment = parts[2 ..< (parts.count - 1)].joined(separator: " ")
            } else {
                comment = ""
            }

            let pubKey = keyIndex < publicKeys.count ? publicKeys[keyIndex] : nil

            result.append(AgentKeyInfo(
                id:          fingerprint,
                fingerprint: fingerprint,
                comment:     comment,
                keyType:     keyType,
                bits:        bits,
                publicKey:   pubKey
            ))
            keyIndex += 1
        }
        return result
    }

    // MARK: - File Key Info

    private func getKeyInfo(name: String, privatePath: String, publicPath: String?) -> SSHKeyInfo {
        var keyType    = "unknown"
        var fingerprint = ""
        var comment    = ""

        let targetPath = publicPath ?? privatePath
        let process    = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-f", targetPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()

        if let _ = try? process.run() {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                let parts = output.components(separatedBy: " ")
                if parts.count >= 2 { fingerprint = parts[1] }
                if let typeMatch = output.components(separatedBy: "(").last?.dropLast() {
                    keyType = String(typeMatch)
                }
                if parts.count >= 3 {
                    let commentParts = parts[2 ..< parts.count].joined(separator: " ")
                    if let parenIdx = commentParts.lastIndex(of: "(") {
                        comment = String(commentParts[commentParts.startIndex ..< parenIdx])
                            .trimmingCharacters(in: .whitespaces)
                    } else {
                        comment = commentParts
                    }
                }
            }
        }

        return SSHKeyInfo(
            id:             name,
            privateKeyPath: privatePath,
            publicKeyPath:  publicPath,
            keyType:        keyType,
            fingerprint:    fingerprint,
            comment:        comment
        )
    }

    // MARK: - Key Generation

    func generateKey(name: String, type: String = "ed25519", comment: String = "", passphrase: String = "") -> Bool {
        let safeName = name.trimmingCharacters(in: .whitespaces)
        let allowed  = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !safeName.isEmpty,
              !safeName.contains("/"),
              !safeName.contains("\\"),
              !safeName.hasPrefix("."),
              safeName.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let keyPath = sshDir.appendingPathComponent(safeName).path
        if fm.fileExists(atPath: keyPath) { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", type, "-f", keyPath, "-N", passphrase, "-C", comment.isEmpty ? name : comment]
        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - Clipboard

    func copyPublicKey(_ key: SSHKeyInfo) -> Bool {
        guard let pubPath = key.publicKeyPath,
              let content = try? String(contentsOfFile: pubPath, encoding: .utf8) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        return true
    }

    // MARK: - Agent Operations

    func addKeyToAgent(keyPath: String) -> Bool {
        guard let sock = resolveAgentSocket() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["--apple-use-keychain", keyPath]
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"]        = sock
        env["SSH_ASKPASS"]          = askPassScriptPath
        env["SSH_ASKPASS_REQUIRE"]  = "prefer"
        env["DISPLAY"]              = ":0"
        process.environment = env
        process.standardInput  = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    func removeKeyFromAgent(keyPath: String) -> Bool {
        guard let sock = resolveAgentSocket() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["-d", keyPath]
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = sock
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    func removeAllKeysFromAgent() -> Bool {
        guard let sock = resolveAgentSocket() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["-D"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = sock
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - Helpers

    private func expandTilde(_ path: String) -> String {
        path.hasPrefix("~/")
            ? fm.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
            : path
    }

    /// Run a short shell command with a sane PATH and return trimmed stdout.
    private func runShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out?.isEmpty == false ? out : nil
        } catch { return nil }
    }

    private lazy var askPassScriptPath: String = {
        let path   = NSTemporaryDirectory() + "sshvault-askpass.sh"
        let script = """
        #!/bin/bash
        exec osascript - "$1" <<'APPLESCRIPT'
        on run argv
            set promptText to item 1 of argv
            display dialog promptText default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with title "SSHVault" with icon caution
            return text returned of result
        end run
        APPLESCRIPT
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }()
}
