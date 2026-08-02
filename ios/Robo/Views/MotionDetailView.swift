import SwiftUI

struct MotionDetailView: View {
    let motion: MotionRecord

    @State private var shareURL: URL?

    private var distanceMiles: Double {
        motion.distanceMeters * MotionService.metersToMiles
    }

    private var activities: [[String: Any]]? {
        guard let dict = try? JSONSerialization.jsonObject(with: motion.activityJSON) as? [String: Any],
              let arr = dict["activities"] as? [[String: Any]] else { return nil }
        return arr
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text("\(motion.stepCount) steps")
                        .font(.title2.bold())
                    Text(motion.capturedAt, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section("Pedometer") {
                LabeledContent("Steps", value: "\(motion.stepCount)")
                LabeledContent("Distance", value: String(format: "%.1f mi (%.0f m)", distanceMiles, motion.distanceMeters))
                LabeledContent("Floors Up", value: "\(motion.floorsAscended)")
                LabeledContent("Floors Down", value: "\(motion.floorsDescended)")
            }

            if let activities, !activities.isEmpty {
                Section("Activity Periods (\(activities.count))") {
                    ForEach(Array(activities.enumerated()), id: \.offset) { _, period in
                        let actType = period["activity_type"] as? String ?? "unknown"
                        let durationMin = period["duration_minutes"] as? Int
                        HStack {
                            Image(systemName: activityIcon(actType))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(actType.capitalized)
                                if let time = period["start_time"] as? String {
                                    Text(formatTime(time))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let mins = durationMin {
                                Text(formatDuration(mins))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(period["confidence"] as? String ?? "")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Section("Data") {
                LabeledContent("Activity JSON", value: formatBytes(motion.activityJSON.count))
            }

            Section {
                Button {
                    exportMotion()
                } label: {
                    Label("Share as ZIP", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Motion Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
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

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return iso }
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }

    private func exportMotion() {
        let data = motion.activityJSON
        Task.detached {
            do {
                let url = try ExportService.createMotionExportZip(activityJSON: data)
                await MainActor.run {
                    shareURL = url
                }
            } catch {
                // Silently fail — export is best-effort
            }
        }
    }
}
