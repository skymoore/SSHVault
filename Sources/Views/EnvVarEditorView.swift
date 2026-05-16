import SwiftUI

/// Reusable editor for a list of EnvVarEntry values.
/// Used in SettingsView (global vars) and HostFormView (per-host vars).
struct EnvVarEditorView: View {
    @Binding var entries: [EnvVarEntry]
    var onSave: (() -> Void)? = nil

    @ObservedObject private var tm = ThemeManager.shared
    private var t: AppTheme { tm.current }

    @State private var editingID:    UUID?  = nil
    @State private var isAddingNew:  Bool   = false
    @State private var pendingKey:   String = ""
    @State private var pendingValue: String = ""
    @State private var pendingIsCmd: Bool   = false

    private var isBusy: Bool { editingID != nil || isAddingNew }

    var body: some View {
        VStack(spacing: 6) {
            if entries.isEmpty && !isBusy {
                emptyState
            } else {
                ForEach($entries) { $entry in
                    if editingID == entry.id {
                        inlineEditRow(id: entry.id)
                    } else {
                        entryRow(entry: $entry)
                    }
                }
            }

            if isAddingNew {
                inlineAddRow
            }

            HStack(spacing: 6) {
                addButton
                presetsMenu
                Spacer()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text("No environment variables")
            .font(.system(size: 11))
            .foregroundColor(t.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    // MARK: - Entry row (read mode)

    private func entryRow(entry: Binding<EnvVarEntry>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: entry.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .scaleEffect(0.8)

            Text(entry.wrappedValue.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(t.foreground)
                .frame(minWidth: 80, alignment: .leading)

            Text("=")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(t.secondary.opacity(0.5))

            if entry.wrappedValue.value.isCommand {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundColor(t.cyan)
                    Text(entry.wrappedValue.value.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(t.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.wrappedValue.value.rawValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(t.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button { beginEdit(entry.wrappedValue) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(t.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Button {
                entries.removeAll { $0.id == entry.wrappedValue.id }
                onSave?()
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10))
                    .foregroundColor(t.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.surface.opacity(0.4)))
    }

    // MARK: - Inline edit row (editing an existing entry)

    private func inlineEditRow(id: UUID) -> some View {
        pendingForm(
            onCommit: {
                let key   = pendingKey.trimmingCharacters(in: .whitespaces)
                let value = pendingIsCmd ? EnvVarValue.command(pendingValue) : EnvVarValue.literal(pendingValue)
                if let idx = entries.firstIndex(where: { $0.id == id }) {
                    entries[idx].key   = key
                    entries[idx].value = value
                }
                editingID = nil
                resetPending()
                onSave?()
            },
            onCancel: {
                editingID = nil
                resetPending()
            }
        )
    }

    // MARK: - Inline add row (new entry)

    private var inlineAddRow: some View {
        pendingForm(
            onCommit: {
                let key   = pendingKey.trimmingCharacters(in: .whitespaces)
                let value = pendingIsCmd ? EnvVarValue.command(pendingValue) : EnvVarValue.literal(pendingValue)
                entries.append(EnvVarEntry(key: key, value: value))
                isAddingNew = false
                resetPending()
                onSave?()
            },
            onCancel: {
                isAddingNew = false
                resetPending()
            }
        )
    }

    // MARK: - Shared pending form

    private func pendingForm(onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("KEY", text: $pendingKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 80, maxWidth: 130)

                Text("=")
                    .font(.system(size: 11))
                    .foregroundColor(t.secondary)

                TextField(
                    pendingIsCmd ? "gpgconf --list-dirs agent-ssh-socket" : "value",
                    text: $pendingValue
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

                Toggle(isOn: $pendingIsCmd) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .help("Evaluate as shell command at launch time")
            }

            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                Button("Save", action: onCommit)
                    .font(.system(size: 11))
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.accent.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            guard !isBusy else { return }
            resetPending()
            isAddingNew = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                Text("Add")
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
    }

    // MARK: - Presets menu

    private var presetsMenu: some View {
        Menu {
            ForEach(EnvPreset.allCases, id: \.label) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    Text(preset.label)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                Text("Presets")
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(t.secondary.opacity(0.3), lineWidth: 0.5))
        .disabled(isBusy)
    }

    // MARK: - Helpers

    private func beginEdit(_ entry: EnvVarEntry) {
        pendingKey   = entry.key
        pendingValue = entry.value.rawValue
        pendingIsCmd = entry.value.isCommand
        editingID    = entry.id
    }

    private func resetPending() {
        pendingKey   = ""
        pendingValue = ""
        pendingIsCmd = false
    }

    private func applyPreset(_ preset: EnvPreset) {
        for entry in preset.entries {
            if let idx = entries.firstIndex(where: { $0.key == entry.key }) {
                entries[idx] = entry
            } else {
                entries.append(entry)
            }
        }
        onSave?()
    }
}
