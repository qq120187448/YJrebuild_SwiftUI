import SwiftUI

struct DeveloperPortalView: View {
    @Environment(DeviceService.self) private var deviceService
    @Environment(APIService.self) private var apiService
    @State private var apiKeys: [APIKeyMeta] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreateAlert = false
    @State private var newKeyLabel = ""
    @State private var copiedId: String?
    @State private var isDeleting: Set<String> = []

    var body: some View {
        Form {
            deviceSection
            apiKeysSection
            whatsWorkingSection
            quickStartSection
        }
        .navigationTitle("Developer Portal")
        .task { await loadKeys() }
    }

    // MARK: - Device Section

    private var deviceSection: some View {
        Section("Your Device") {
            CopyableRow(label: "Device ID", value: deviceService.config.id, copiedId: $copiedId, id: "device")
            if let token = deviceService.config.mcpToken {
                CopyableRow(label: "MCP Token", value: token, masked: "••••\(String(token.suffix(4)))", copiedId: $copiedId, id: "token")
            }
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        Section {
            if isLoading && apiKeys.isEmpty {
                ProgressView()
            } else if apiKeys.isEmpty {
                Text("No API keys yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apiKeys) { key in
                    Button {
                        UIPasteboard.general.string = key.keyHint
                        withAnimation { copiedId = key.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copiedId == key.id { copiedId = nil }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if let label = key.label {
                                    Text(label).font(.subheadline.weight(.medium))
                                }
                                Text(key.keyHint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let days = key.daysRemaining {
                                    Text("Expires in \(days) day\(days == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(days <= 7 ? .orange : .secondary)
                                }
                            }
                            Spacer()
                            if isDeleting.contains(key.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: copiedId == key.id ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedId == key.id ? .green : .accentColor)
                                    .font(.caption)
                            }
                        }
                    }
                    .tint(.primary)
                }
                .onDelete(perform: deleteKeys)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Button {
                newKeyLabel = ""
                showCreateAlert = true
            } label: {
                Label("Create API Key", systemImage: "plus")
            }
            .disabled(apiKeys.count >= 3)
        } header: {
            Text("API Keys")
        } footer: {
            Text("Maximum 3 keys per device. Keys expire after 30 days. Full key is auto-copied on creation. Tap a key to copy. Swipe to delete.")
        }
        .alert("New API Key", isPresented: $showCreateAlert) {
            TextField("Label (optional)", text: $newKeyLabel)
            Button("Create") { Task { await createKey() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - What's Working

    private var whatsWorkingSection: some View {
        Section("What's Working") {
            capability("Barcode scanning", icon: "barcode.viewfinder", detail: "via MCP")
            capability("LiDAR room scanning", icon: "camera.metering.matrix", detail: "via MCP")
            capability("Photo capture", icon: "camera", detail: "via MCP")
            capability("HIT links", icon: "link", detail: "shareable tasks")
            capability("Push notifications", icon: "bell", detail: "via APNs")
        }
    }

    private func capability(_ name: String, icon: String, detail: String) -> some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary).font(.caption)
        } label: {
            Label(name, systemImage: icon)
        }
    }

    // MARK: - Quick Start

    private var quickStartSection: some View {
        Section {
            let config = mcpConfigJSON
            VStack(alignment: .leading, spacing: 8) {
                Text(config)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button {
                UIPasteboard.general.string = config
                withAnimation { copiedId = "quickstart" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedId == "quickstart" { copiedId = nil }
                }
            } label: {
                Label(copiedId == "quickstart" ? "Copied!" : "Copy Config", systemImage: copiedId == "quickstart" ? "checkmark" : "doc.on.doc")
            }
        } header: {
            Text("Quick Start — MCP Config")
        } footer: {
            Text("Paste into your Claude Desktop or MCP client config.")
        }
    }

    private var mcpConfigJSON: String {
        let token = deviceService.config.mcpToken ?? "<your-mcp-token>"
        return """
        {
          "mcpServers": {
            "robo": {
              "type": "http",
              "url": "https://mcp.robo.app/mcp",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }

    // MARK: - Actions

    private func loadKeys() async {
        isLoading = true
        error = nil
        do {
            apiKeys = try await apiService.fetchAPIKeys()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func createKey() async {
        error = nil
        do {
            let label = newKeyLabel.isEmpty ? nil : newKeyLabel
            let created = try await apiService.createAPIKey(label: label)
            // Copy the full key — this is the only time it's visible
            UIPasteboard.general.string = created.keyValue
            withAnimation { copiedId = created.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copiedId == created.id { copiedId = nil }
            }
            // Reload to get masked list
            await loadKeys()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let key = apiKeys[index]
            isDeleting.insert(key.id)
            Task {
                do {
                    try await apiService.deleteAPIKey(id: key.id)
                    apiKeys.removeAll { $0.id == key.id }
                } catch {
                    self.error = error.localizedDescription
                }
                isDeleting.remove(key.id)
            }
        }
    }
}

// MARK: - Copyable Row

private struct CopyableRow: View {
    let label: String
    let value: String
    var masked: String?
    @Binding var copiedId: String?
    let id: String

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            withAnimation { copiedId = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copiedId == id { copiedId = nil }
            }
        } label: {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    Text(masked ?? value)
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: copiedId == id ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copiedId == id ? .green : .accentColor)
                        .font(.caption)
                }
            }
        }
        .tint(.primary)
    }
}
