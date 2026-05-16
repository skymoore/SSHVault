import Foundation
import SwiftUI

/// Supported terminal applications
enum TerminalApp: String, CaseIterable, Codable {
    case ghostty
    case terminal
    case iterm2
    case custom

    var displayName: String {
        switch self {
        case .ghostty:  return "Ghostty"
        case .terminal: return "Terminal"
        case .iterm2:   return "iTerm2"
        case .custom:   return "Custom"
        }
    }

    var appPath: String {
        switch self {
        case .ghostty:  return "/Applications/Ghostty.app"
        case .terminal: return "/System/Applications/Utilities/Terminal.app"
        case .iterm2:   return "/Applications/iTerm.app"
        case .custom:   return ""
        }
    }

    var isInstalled: Bool {
        switch self {
        case .custom: return true
        default:      return FileManager.default.fileExists(atPath: appPath)
        }
    }
}

/// Per-host override for terminal and/or environment variables.
/// Both `terminal` and env vars are independently optional so a host can
/// override just env vars without changing which terminal app is used.
struct HostTerminalOverride: Codable {
    var hostID: String

    /// nil = use the global default terminal
    var terminal: TerminalApp?
    var customAppPath: String?

    /// How this host's envVars list relates to the global list
    var envMode: EnvVarMode
    /// Host-specific env var entries (empty = no host-level entries)
    var envVars: [EnvVarEntry]

    init(
        hostID: String,
        terminal: TerminalApp? = nil,
        customAppPath: String? = nil,
        envMode: EnvVarMode = .inheritAndAppend,
        envVars: [EnvVarEntry] = []
    ) {
        self.hostID       = hostID
        self.terminal     = terminal
        self.customAppPath = customAppPath
        self.envMode      = envMode
        self.envVars      = envVars
    }

    /// True if this override record actually customises anything
    var isEmpty: Bool {
        terminal == nil && envVars.isEmpty
    }
}

/// Manages global terminal preferences and per-host overrides
final class TerminalPreferences: ObservableObject {
    static let shared = TerminalPreferences()

    @AppStorage("defaultTerminal") var defaultTerminal: TerminalApp = .ghostty
    @AppStorage("customTerminalPath") var customTerminalPath: String = ""
    @AppStorage("maskHostIP") var maskHostIP: Bool = false
    @AppStorage("customAgentSocket") var customAgentSocket: String = ""

    @Published var hostOverrides: [String: HostTerminalOverride] = [:]
    @Published var globalEnvVars: [EnvVarEntry] = []

    // MARK: - Storage URLs

    private static func appSupportDir() -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable")
        }
        let url = base.appendingPathComponent("SSHVault", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static let overridesURL: URL =
        appSupportDir().appendingPathComponent("host_terminal_prefs.json")

    private static let globalEnvVarsURL: URL =
        appSupportDir().appendingPathComponent("global_env_vars.json")

    // MARK: - Init

    private init() {
        loadOverrides()
        loadGlobalEnvVars()
    }

    // MARK: - Terminal resolution

    func resolvedTerminal(for hostAlias: String) -> TerminalApp {
        hostOverrides[hostAlias]?.terminal ?? defaultTerminal
    }

    func resolvedCustomPath(for hostAlias: String) -> String {
        if let override = hostOverrides[hostAlias],
           override.terminal == .custom,
           let path = override.customAppPath, !path.isEmpty {
            return path
        }
        return customTerminalPath
    }

    // MARK: - Env var resolution

    /// Returns the effective env var list for a host, respecting global + host mode.
    func resolvedEnvVars(for hostAlias: String) -> [EnvVarEntry] {
        guard let override = hostOverrides[hostAlias], !override.envVars.isEmpty || override.envMode == .replaceAll else {
            return globalEnvVars
        }
        switch override.envMode {
        case .replaceAll:
            return override.envVars
        case .inheritAndAppend:
            // Global entries first; host entries with the same key win (append = override)
            var merged = globalEnvVars
            for entry in override.envVars {
                if let idx = merged.firstIndex(where: { $0.key == entry.key }) {
                    merged[idx] = entry
                } else {
                    merged.append(entry)
                }
            }
            return merged
        }
    }

    // MARK: - Per-host overrides

    func setOverride(
        for hostAlias: String,
        terminal: TerminalApp?,
        customPath: String? = nil,
        envMode: EnvVarMode = .inheritAndAppend,
        envVars: [EnvVarEntry] = []
    ) {
        let override = HostTerminalOverride(
            hostID:        hostAlias,
            terminal:      terminal,
            customAppPath: customPath,
            envMode:       envMode,
            envVars:       envVars
        )
        if override.isEmpty {
            hostOverrides.removeValue(forKey: hostAlias)
        } else {
            hostOverrides[hostAlias] = override
        }
        saveOverrides()
    }

    func removeOverride(for hostAlias: String) {
        hostOverrides.removeValue(forKey: hostAlias)
        saveOverrides()
    }

    func hasOverride(for hostAlias: String) -> Bool {
        hostOverrides[hostAlias] != nil
    }

    // MARK: - Global env vars

    func saveGlobalEnvVars() {
        guard let data = try? JSONEncoder().encode(globalEnvVars) else { return }
        try? data.write(to: Self.globalEnvVarsURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.globalEnvVarsURL.path
        )
    }

    // MARK: - Persistence

    private func loadOverrides() {
        guard FileManager.default.fileExists(atPath: Self.overridesURL.path),
              let data = try? Data(contentsOf: Self.overridesURL),
              let list = try? JSONDecoder().decode([HostTerminalOverride].self, from: data)
        else { return }
        hostOverrides = Dictionary(uniqueKeysWithValues: list.map { ($0.hostID, $0) })
    }

    private func saveOverrides() {
        let list = Array(hostOverrides.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: Self.overridesURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.overridesURL.path
        )
    }

    private func loadGlobalEnvVars() {
        guard FileManager.default.fileExists(atPath: Self.globalEnvVarsURL.path),
              let data = try? Data(contentsOf: Self.globalEnvVarsURL),
              let list = try? JSONDecoder().decode([EnvVarEntry].self, from: data)
        else { return }
        globalEnvVars = list
    }
}
