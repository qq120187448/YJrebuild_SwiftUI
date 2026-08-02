import SwiftUI

struct MotionResultView: View {
    let snapshot: MotionSnapshot
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var shareURL: URL?
    @State private var isExporting = false
    @State private var exportError: String?

    private var distanceMiles: Double {
        snapshot.distanceMeters * MotionService.metersToMiles
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .padding(.top, 24)

                Text("Capture Complete")
                    .font(.title.bold())

                // Headline stat
                VStack(spacing: 4) {
                    Text("\(snapshot.stepCount)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("steps (last 7 days)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)

                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    statCard(value: String(format: "%.1f mi", distanceMiles), label: "Distance", icon: "map")
                    statCard(value: "\(snapshot.floorsAscended)", label: "Floors Up", icon: "arrow.up")
                    statCard(value: "\(snapshot.floorsDescended)", label: "Floors Down", icon: "arrow.down")
                    statCard(value: "\(snapshot.activities.count)", label: "Activities", icon: "figure.walk")
                }
                .padding(.horizontal, 24)

                // Activity breakdown
                if !snapshot.activities.isEmpty {
                    VStack(spacing: 12) {
                        Text("Activity Periods")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(Array(snapshot.activities.prefix(10).enumerated()), id: \.offset) { _, period in
                            HStack {
                                Image(systemName: activityIcon(period.type))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(period.type.capitalized)
                                Spacer()
                                Text(period.startDate, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(period.confidence)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }

                        if snapshot.activities.count > 10 {
                            Text("+\(snapshot.activities.count - 10) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                }

                // Actions
                VStack(spacing: 12) {
                    Button {
                        onSave()
                    } label: {
                        Label("Save to History", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        exportMotion()
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .tint(.accentColor)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text("Share as ZIP")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.secondary.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isExporting)

                    Button("Discard", role: .destructive) {
                        onDiscard()
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
        .alert("Export Failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            if let exportError {
                Text(exportError)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "automotive": return "car"
        case "cycling": return "bicycle"
        case "stationary": return "figure.stand"
        default: return "questionmark"
        }
    }

    private func exportMotion() {
        isExporting = true
        Task.detached {
            do {
                let json = try MotionService.encodeSnapshot(snapshot)
                let url = try ExportService.createMotionExportZip(activityJSON: json)
                await MainActor.run {
                    shareURL = url
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}
