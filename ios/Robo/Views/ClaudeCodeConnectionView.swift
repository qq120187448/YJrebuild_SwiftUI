import SwiftUI

struct ClaudeCodeConnectionView: View {
    let mcpToken: String

    @State private var copied = false

    private var connectionCommand: String {
        "claude mcp add robo --transport http https://mcp.robo.app/mcp --header \"Authorization: Bearer \(mcpToken)\""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect to Claude Code", systemImage: "terminal")
                .font(.headline)

            Text("Paste this in your terminal:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(connectionCommand)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .cornerRadius(8)

            Button {
                UIPasteboard.general.string = connectionCommand
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied!" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
