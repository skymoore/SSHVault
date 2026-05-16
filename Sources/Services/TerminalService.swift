import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.lzdevs.sshvault", category: "terminal")

/// Launches SSH connections in configurable terminal applications
struct TerminalService {
    private static let prefs = TerminalPreferences.shared

    static let defaultSSHPort = 22

    /// Shell-escape a string for safe use in sh -c
    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Expand ~ to the full home directory path
    private static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        return path
    }

    /// Launch an SSH connection using the resolved terminal for this host
    static func connect(to host: SSHHost) {
        var cmd = "ssh"
        if !host.identityFile.isEmpty {
            cmd += " -i \(shellEscape(expandTilde(host.identityFile)))"
        }
        if let port = host.port, port != Self.defaultSSHPort {
            cmd += " -p \(port)"
        }
        if host.forwardAgent {
            cmd += " -A"
        }
        if !host.proxyJump.isEmpty {
            cmd += " -J \(shellEscape(host.proxyJump))"
        }
        let target: String
        if !host.user.isEmpty {
            target = "\(host.user)@\(host.hostName)"
        } else {
            target = host.hostName
        }
        cmd += " \(shellEscape(target))"

        if host.sshInitPath && !host.sftpPath.isEmpty {
            cmd += " -t \(shellEscape("cd \(host.sftpPath) && exec $SHELL -l"))"
        }

        let terminal   = prefs.resolvedTerminal(for: host.host)
        let customPath = prefs.resolvedCustomPath(for: host.host)
        let envVars    = evaluateEnvVars(prefs.resolvedEnvVars(for: host.host))
        launchTerminal(shellCommand: cmd, using: terminal, customAppPath: customPath, extraEnv: envVars)
    }

    /// Open an SFTP connection in the system's preferred SFTP app via URL scheme.
    static func openSFTP(to host: SSHHost) {
        let path = host.sftpPath.isEmpty ? "" : "/\(host.sftpPath)"
        guard let url = URL(string: "sftp://\(host.host)\(path)") else {
            logger.warning("Failed to build SFTP URL for \(host.displayName)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Launch an interactive SFTP session to the host
    static func sftpBrowse(to host: SSHHost) {
        var cmd = "sftp"
        if !host.identityFile.isEmpty {
            cmd += " -i \(shellEscape(expandTilde(host.identityFile)))"
        }
        if let port = host.port, port != Self.defaultSSHPort {
            cmd += " -P \(port)"
        }
        if !host.proxyJump.isEmpty {
            cmd += " -J \(shellEscape(host.proxyJump))"
        }
        let target: String
        if !host.user.isEmpty {
            target = "\(host.user)@\(host.hostName)"
        } else {
            target = host.hostName
        }
        cmd += " \(shellEscape(target))"

        let terminal   = prefs.resolvedTerminal(for: host.host)
        let customPath = prefs.resolvedCustomPath(for: host.host)
        let envVars    = evaluateEnvVars(prefs.resolvedEnvVars(for: host.host))
        launchTerminal(shellCommand: cmd, using: terminal, customAppPath: customPath, extraEnv: envVars)
    }

    /// Run ssh-copy-id to push a public key to the host
    static func copyKeyToHost(_ host: SSHHost, keyPath: String) {
        let fullPath = expandTilde(keyPath)
        var cmd = "ssh-copy-id"
        cmd += " -i \(shellEscape(fullPath))"
        if let port = host.port, port != Self.defaultSSHPort {
            cmd += " -p \(port)"
        }
        let target: String
        if !host.user.isEmpty {
            target = "\(host.user)@\(host.hostName)"
        } else {
            target = host.hostName
        }
        cmd += " \(shellEscape(target))"

        let terminal   = prefs.resolvedTerminal(for: host.host)
        let customPath = prefs.resolvedCustomPath(for: host.host)
        let envVars    = evaluateEnvVars(prefs.resolvedEnvVars(for: host.host))
        launchTerminal(shellCommand: cmd, using: terminal, customAppPath: customPath, extraEnv: envVars)
    }

    // MARK: - Terminal launch

    /// Launch a shell command in the specified terminal app
    private static func launchTerminal(
        shellCommand: String,
        using terminal: TerminalApp,
        customAppPath: String = "",
        extraEnv: [String: String] = [:]
    ) {
        switch terminal {
        case .ghostty:
            // Set TERM=xterm-256color so remote servers don't need the xterm-ghostty terminfo.
            // extraEnv is injected into the process environment directly (most reliable for GUI apps).
            launchDirectBinary(
                binPath: TerminalApp.ghostty.appPath + "/Contents/MacOS/ghostty",
                shellCommand: "TERM=xterm-256color " + shellCommand,
                extraEnv: extraEnv
            )
        case .terminal:
            launchViaAppleScript(
                script: "tell application \"Terminal\" to do script \"\(escapeAppleScript(applyEnvToCommand(shellCommand, env: extraEnv)))\"",
                appName: "Terminal"
            )
        case .iterm2:
            launchViaAppleScript(
                script: "tell application \"iTerm2\" to create window with default profile command \"\(escapeAppleScript(applyEnvToCommand(shellCommand, env: extraEnv)))\"",
                appName: "iTerm2"
            )
        case .custom:
            guard !customAppPath.isEmpty else {
                logger.warning("Custom terminal path not configured")
                return
            }
            guard customAppPath.hasSuffix(".app") else {
                logger.warning("Custom terminal path must end with .app")
                return
            }
            let appName = URL(fileURLWithPath: customAppPath).deletingPathExtension().lastPathComponent
            let binPath = customAppPath + "/Contents/MacOS/\(appName)"
            guard FileManager.default.fileExists(atPath: binPath) else {
                logger.warning("Custom terminal binary not found at expected path")
                return
            }
            launchDirectBinary(binPath: binPath, shellCommand: shellCommand, extraEnv: extraEnv)
        }
    }

    // MARK: - Env var evaluation

    /// Evaluate enabled EnvVarEntries into a concrete [String: String] dictionary.
    /// Command-type values are executed synchronously (expected to be short-lived tools like gpgconf).
    static func evaluateEnvVars(_ entries: [EnvVarEntry]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries where entry.enabled && !entry.key.isEmpty {
            switch entry.value {
            case .literal(let v):
                result[entry.key] = v
            case .command(let cmd):
                if let output = runShellCommand(cmd) {
                    result[entry.key] = output
                } else {
                    logger.warning("env var command produced no output: \(cmd, privacy: .public)")
                }
            }
        }
        return result
    }

    /// Run a short shell command via /bin/sh and return trimmed stdout, or nil on failure.
    private static func runShellCommand(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Give /bin/sh a minimal PATH that covers common tool locations
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data   = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            logger.warning("env var command failed '\(command, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Prepend env var assignments to a shell command string.
    /// Used for AppleScript-based terminals that don't support process.environment injection.
    private static func applyEnvToCommand(_ cmd: String, env: [String: String]) -> String {
        guard !env.isEmpty else { return cmd }
        let prefix = env.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(shellEscape($0.value))" }
            .joined(separator: " ")
        return prefix + " " + cmd
    }

    // MARK: - Launch helpers

    /// Launch a terminal via direct binary execution with optional extra environment variables.
    /// Extra env is merged on top of the current process environment so the terminal inherits
    /// everything it normally would, plus the explicitly injected vars.
    private static func launchDirectBinary(
        binPath: String,
        shellCommand: String,
        extraEnv: [String: String] = [:]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["-e", "/bin/sh", "-c", shellCommand]

        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env.merge(extraEnv) { _, new in new }
            process.environment = env
        }

        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch terminal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Launch a terminal via AppleScript (Terminal.app, iTerm2)
    private static func launchViaAppleScript(script: String, appName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Escape a string for safe embedding in AppleScript double-quoted strings
    private static func escapeAppleScript(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { $0.value >= 32 || $0 == "\t" }
            .map { String($0) }.joined()
        return cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
