import Foundation

// MARK: - EnvVarMode

/// How a per-host env var list relates to the global list
enum EnvVarMode: String, Codable, CaseIterable {
    case inheritAndAppend   // use global vars, then add/override with host-specific ones
    case replaceAll         // ignore global entirely, use only host-specific vars

    var displayName: String {
        switch self {
        case .inheritAndAppend: return "Inherit global + add"
        case .replaceAll:       return "Replace global"
        }
    }
}

// MARK: - EnvVarValue

/// The value of an env var — either a static string or a shell command whose stdout is used
enum EnvVarValue: Codable, Equatable {
    case literal(String)
    case command(String)    // evaluated at launch time; stdout trimmed and used as value

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type  = try c.decode(String.self, forKey: .type)
        let value = try c.decode(String.self, forKey: .value)
        self = type == "command" ? .command(value) : .literal(value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let v): try c.encode("literal", forKey: .type); try c.encode(v, forKey: .value)
        case .command(let v): try c.encode("command", forKey: .type); try c.encode(v, forKey: .value)
        }
    }

    /// The raw string stored — the command string or the literal value
    var rawValue: String {
        switch self { case .literal(let v), .command(let v): return v }
    }

    /// Human-readable representation shown in the UI
    var displayValue: String {
        switch self {
        case .literal(let v): return v
        case .command(let v): return "$(\(v))"
        }
    }

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}

// MARK: - EnvVarEntry

/// A single environment variable entry in a list
struct EnvVarEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var key: String
    var value: EnvVarValue
    var enabled: Bool

    init(id: UUID = UUID(), key: String, value: EnvVarValue, enabled: Bool = true) {
        self.id      = id
        self.key     = key
        self.value   = value
        self.enabled = enabled
    }
}

// MARK: - EnvPreset

/// Built-in presets that produce ready-made EnvVarEntry arrays
enum EnvPreset: CaseIterable {
    case gpgSSHAgent
    case homebrew

    var label: String {
        switch self {
        case .gpgSSHAgent: return "GPG SSH Agent"
        case .homebrew:    return "Homebrew PATH"
        }
    }

    var description: String {
        switch self {
        case .gpgSSHAgent: return "Route SSH auth through gpg-agent (YubiKey / smartcard)"
        case .homebrew:    return "Prepend /opt/homebrew/bin to PATH"
        }
    }

    /// Returns new entry instances ready to be appended to a list
    var entries: [EnvVarEntry] {
        switch self {
        case .gpgSSHAgent:
            return [
                EnvVarEntry(
                    key:   "SSH_AUTH_SOCK",
                    value: .command("gpgconf --list-dirs agent-ssh-socket")
                )
            ]
        case .homebrew:
            return [
                EnvVarEntry(
                    key:   "PATH",
                    value: .literal("/opt/homebrew/bin:/usr/local/bin:$PATH")
                )
            ]
        }
    }
}
