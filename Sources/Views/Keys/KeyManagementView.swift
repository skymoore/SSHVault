import SwiftUI

struct KeyManagementView: View {
    var isInline: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tm = ThemeManager.shared
    @State private var keys: [SSHKeyInfo] = []
    @State private var showingGenerate = false
    @State private var newKeyName = ""
    @State private var newKeyType = "ed25519"
    @State private var newKeyComment = ""
    @State private var newKeyPassphrase = ""
    @State private var generationResult: String?
    @State private var copiedKeyID: String?
    @State private var agentRunning: Bool = false
    @State private var agentSocket: String? = nil
    @State private var agentOnlyKeys: [AgentKeyInfo] = []

    private let keyService = SSHKeyService.shared
    private var t: AppTheme { tm.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH Keys")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(t.foreground)
                Spacer()
                Button { showingGenerate = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Generate").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(t.green)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.green.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.green.opacity(0.25), lineWidth: 0.5))
                }.buttonStyle(.plain)
                if !isInline {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Rectangle().fill(t.secondary.opacity(0.2)).frame(height: 0.5)

            HStack(spacing: 6) {
                Circle()
                    .fill(agentRunning ? t.green : t.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                if agentRunning, let sock = agentSocket {
                    let label = keyService.agentLabel(for: sock)
                    Text(label)
                        .font(.system(size: 10.5))
                        .foregroundColor(t.green)
                    Text(sock)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(t.secondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No SSH agent detected")
                        .font(.system(size: 10.5))
                        .foregroundColor(t.secondary)
                }
                Spacer()
                if agentRunning {
                    let totalInAgent = keys.filter(\.isLoadedInAgent).count + agentOnlyKeys.count
                    Text("\(totalInAgent) loaded")
                        .font(.system(size: 10.5))
                        .foregroundColor(t.secondary.opacity(0.7))
                    if totalInAgent > 0 {
                        Button {
                            _ = keyService.removeAllKeysFromAgent()
                            refreshKeys()
                        } label: {
                            Text("Remove All")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(t.pink)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(t.pink.opacity(0.1)))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 6)

            Rectangle().fill(t.secondary.opacity(0.2)).frame(height: 0.5)

            if keys.isEmpty && agentOnlyKeys.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if !agentOnlyKeys.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                agentOnlySectionHeader
                                VStack(spacing: 8) {
                                    ForEach(agentOnlyKeys) { key in agentOnlyKeyCard(key) }
                                }
                            }
                        }
                        if !keys.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(keys) { key in keyCard(key) }
                            }
                        }
                    }.padding(16)
                }
            }

            Rectangle().fill(t.secondary.opacity(0.2)).frame(height: 0.5)
            HStack {
                Image(systemName: "folder").font(.system(size: 11)).foregroundColor(t.secondary.opacity(0.6))
                Text("~/.ssh/").font(.system(size: 10.5, design: .monospaced)).foregroundColor(t.secondary.opacity(0.6))
                Spacer()
                if agentRunning {
                    let totalInAgent = keys.filter(\.isLoadedInAgent).count + agentOnlyKeys.count
                    Text("\(totalInAgent) in agent /")
                        .font(.system(size: 10.5)).foregroundColor(t.secondary.opacity(0.7))
                }
                Text("\(keys.count) file key\(keys.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundColor(t.secondary.opacity(0.7))
            }.padding(.horizontal, 16).padding(.vertical, 6)
        }
        .background(t.background)
        .task { refreshKeys() }
        .sheet(isPresented: $showingGenerate) { generateKeySheet }
        .alert("Key Generated", isPresented: .init(
            get: { generationResult != nil }, set: { if !$0 { generationResult = nil } }
        )) { Button("OK") { generationResult = nil } } message: { Text(generationResult ?? "") }
    }

    // MARK: - Agent-Only Section

    private var agentOnlySectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(t.cyan)
            Text("HARDWARE / SMARTCARD KEYS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(t.cyan)
                .tracking(0.6)
            Rectangle()
                .fill(t.cyan.opacity(0.2))
                .frame(height: 0.5)
        }
    }

    private func agentOnlyKeyCard(_ key: AgentKeyInfo) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(t.cyan.opacity(0.12)).frame(width: 34, height: 34)
                Image(systemName: "creditcard").font(.system(size: 13, weight: .medium)).foregroundColor(t.cyan)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(key.comment.isEmpty ? key.fingerprint : key.comment)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(t.foreground)
                    .lineLimit(1)
                Text(key.fingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(t.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("\(key.bits)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(t.secondary.opacity(0.6))
            Text(key.keyType.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(t.cyan)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(t.cyan.opacity(0.1)))
                .overlay(Capsule().strokeBorder(t.cyan.opacity(0.2), lineWidth: 0.5))
            Text("In Agent")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(t.green)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(t.green.opacity(0.1)))
                .overlay(Capsule().strokeBorder(t.green.opacity(0.2), lineWidth: 0.5))
            if key.publicKey != nil {
                Button {
                    copyAgentPublicKey(key)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedKeyID == key.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copiedKeyID == key.id ? "Copied!" : "Copy Pub")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(copiedKeyID == key.id ? t.green : t.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(
                        copiedKeyID == key.id ? t.green.opacity(0.12) : t.accent.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(t.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(t.cyan.opacity(0.2), lineWidth: 0.5))
    }

    private func copyAgentPublicKey(_ key: AgentKeyInfo) {
        guard let pub = key.publicKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pub, forType: .string)
        copiedKeyID = key.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedKeyID == key.id { copiedKeyID = nil }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(t.accent.opacity(0.08)).frame(width: 64, height: 64)
                Image(systemName: "key.fill").font(.system(size: 28)).foregroundColor(t.accent.opacity(0.5))
            }
            Text("No SSH keys found").font(.system(size: 15, weight: .semibold)).foregroundColor(t.foreground.opacity(0.7))
            Text("Keys in ~/.ssh/ will appear here").font(.system(size: 12)).foregroundColor(t.secondary)
            Button { showingGenerate = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("Generate New Key").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundColor(t.green)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(t.green.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(t.green.opacity(0.3), lineWidth: 0.5))
            }.buttonStyle(.plain).padding(.top, 4)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Key Card

    func keyCard(_ key: SSHKeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(t.pink.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: "key.fill").font(.system(size: 13, weight: .medium)).foregroundColor(t.pink)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(key.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(t.foreground)
                    if !key.comment.isEmpty {
                        Text(key.comment).font(.system(size: 10.5)).foregroundColor(t.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(key.keyType.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(t.cyan)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(t.cyan.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(t.cyan.opacity(0.2), lineWidth: 0.5))
                if agentRunning {
                    if key.isLoadedInAgent {
                        Text("In Agent")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(t.green)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(t.green.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(t.green.opacity(0.2), lineWidth: 0.5))
                        Button {
                            _ = keyService.removeKeyFromAgent(keyPath: key.privateKeyPath)
                            refreshKeys()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(t.pink.opacity(0.7))
                        }.buttonStyle(.plain).help("Remove from agent")
                    } else {
                        Button {
                            _ = keyService.addKeyToAgent(keyPath: key.privateKeyPath)
                            refreshKeys()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle").font(.system(size: 10))
                                Text("Add to Agent").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(t.orange)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(t.orange.opacity(0.1)))
                        }.buttonStyle(.plain)
                    }
                }
                if key.hasPublicKey {
                    Button {
                        if keyService.copyPublicKey(key) {
                            copiedKeyID = key.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copiedKeyID == key.id { copiedKeyID = nil } }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedKeyID == key.id ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                            Text(copiedKeyID == key.id ? "Copied!" : "Copy Pub").font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundColor(copiedKeyID == key.id ? t.green : t.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(
                            copiedKeyID == key.id ? t.green.opacity(0.12) : t.accent.opacity(0.1)))
                    }.buttonStyle(.plain)
                }
            }
            if !key.fingerprint.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "number").font(.system(size: 9, weight: .medium)).foregroundColor(t.secondary.opacity(0.5))
                    Text(key.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundColor(t.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 9, weight: .medium)).foregroundColor(t.secondary.opacity(0.4))
                Text(key.privateKeyPath).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(t.secondary.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(t.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(t.secondary.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - Generate Sheet

    var generateKeySheet: some View {
        VStack(spacing: 0) {
            HStack { Text("Generate SSH Key").font(.headline); Spacer() }.padding()
            Divider()
            Form {
                TextField("Key Name", text: $newKeyName).help("Filename for the key (e.g., id_ed25519_work)")
                Picker("Key Type", selection: $newKeyType) {
                    Text("Ed25519 (Recommended)").tag("ed25519")
                    Text("RSA (4096-bit)").tag("rsa")
                    Text("ECDSA").tag("ecdsa")
                }
                TextField("Comment", text: $newKeyComment).help("Optional label for the key")
                SecureField("Passphrase", text: $newKeyPassphrase).help("Leave empty for no passphrase")
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { showingGenerate = false }.keyboardShortcut(.cancelAction)
                Button("Generate") { generateKey() }.keyboardShortcut(.defaultAction)
                    .disabled(!isValidKeyName(newKeyName))
            }.padding()
        }.frame(width: 400, height: 320)
    }

    private func generateKey() {
        let name = newKeyName.trimmingCharacters(in: .whitespaces)
        let success = keyService.generateKey(name: name, type: newKeyType, comment: newKeyComment, passphrase: newKeyPassphrase)
        generationResult = success
            ? "Key \"\(name)\" generated successfully."
            : "Failed to generate key. A key with this name may already exist."
        newKeyName = ""; newKeyComment = ""; newKeyPassphrase = ""
        showingGenerate = false
        refreshKeys()
    }

    private func isValidKeyName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !trimmed.isEmpty
            && !trimmed.hasPrefix(".")
            && !trimmed.contains("/")
            && trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) })
    }

    private func refreshKeys() {
        agentSocket  = keyService.resolveAgentSocket()
        agentRunning = agentSocket != nil
        keys         = keyService.listKeys()
        agentOnlyKeys = agentRunning ? keyService.listAgentOnlyKeys(fileKeys: keys) : []
    }
}
