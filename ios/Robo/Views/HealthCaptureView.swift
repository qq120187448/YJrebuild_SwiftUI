import SwiftUI
import SwiftData
import AudioToolbox

struct HealthCaptureView: View {
    var captureContext: CaptureContext? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var phase: CapturePhase = .instructions
    @State private var snapshot: HealthSnapshot?
    @State private var error: String?
    @State private var isCapturing = false

    private enum CapturePhase {
        case instructions
        case results
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .instructions:
                    instructionsView
                case .results:
                    if let snapshot {
                        HealthResultView(
                            snapshot: snapshot,
                            onSave: saveHealth,
                            onDiscard: { dismiss() }
                        )
                    }
                }
            }
            .navigationTitle(phase == .instructions ? "Health Data" : "Health Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .instructions {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            .alert("Capture Error", isPresented: .constant(error != nil)) {
                Button("OK") {
                    error = nil
                }
            } message: {
                if let error {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Instructions

    private var instructionsView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "heart.fill")
                .font(.system(size: 64))
                .foregroundColor(.pink)

            Text("Health & Activity")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                tipRow(icon: "bed.double", text: "Captures 30 days of sleep analysis with stages")
                tipRow(icon: "figure.run", text: "Includes workout summaries (type, duration, calories)")
                tipRow(icon: "flame", text: "Daily activity: steps, active calories, exercise minutes")
                tipRow(icon: "lock.shield", text: "Only non-medical data — no heart rate or vitals")
            }
            .padding(.horizontal, 24)

            Spacer()

            if !HealthKitService.isAvailable {
                Text("HealthKit is not available on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }

            Button {
                captureHealth()
            } label: {
                if isCapturing {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.pink)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Capture Health Data")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(HealthKitService.isAvailable ? Color.pink : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(isCapturing || !HealthKitService.isAvailable)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Capture

    private func captureHealth() {
        isCapturing = true
        Task {
            do {
                try await HealthKitService.requestAuthorization()
                let result = try await HealthKitService.capture(daysBack: 30)

                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                AudioServicesPlaySystemSound(1057)

                snapshot = result
                phase = .results
            } catch {
                self.error = error.localizedDescription
            }
            isCapturing = false
        }
    }

    // MARK: - Save

    private func saveHealth() {
        guard let snapshot else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let summaryJSON = try encoder.encode(HealthSummaryExport(snapshot: snapshot))

            let record = HealthRecord(
                dataType: "combined",
                dateRangeStart: snapshot.dateRangeStart,
                dateRangeEnd: snapshot.dateRangeEnd,
                summaryJSON: summaryJSON,
                sleepEntryCount: snapshot.sleep.count,
                workoutCount: snapshot.workouts.count,
                totalSteps: snapshot.activity.reduce(0) { $0 + $1.steps }
            )
            record.agentId = captureContext?.agentId
            record.agentName = captureContext?.agentName
            modelContext.insert(record)
            try modelContext.save()

            dismiss()
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Export Helper

private struct HealthSummaryExport: Codable {
    let sleep: [HealthSnapshot.SleepEntry]
    let workouts: [HealthSnapshot.WorkoutEntry]
    let activity: [HealthSnapshot.DailyActivity]

    init(snapshot: HealthSnapshot) {
        self.sleep = snapshot.sleep
        self.workouts = snapshot.workouts
        self.activity = snapshot.activity
    }
}

// MARK: - Health Result View

struct HealthResultView: View {
    let snapshot: HealthSnapshot
    let onSave: () -> Void
    let onDiscard: () -> Void

    private var totalSteps: Int {
        snapshot.activity.reduce(0) { $0 + $1.steps }
    }

    private var totalSleepHours: Double {
        snapshot.sleep.reduce(0.0) { $0 + $1.durationMinutes } / 60
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .padding(.top, 24)

                Text("Health Data Captured")
                    .font(.title.bold())

                Text("Last 30 days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Summary stats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    statCard(value: "\(totalSteps)", label: "Total Steps", icon: "figure.walk", color: .green)
                    statCard(value: String(format: "%.0fh", totalSleepHours), label: "Total Sleep", icon: "bed.double", color: .indigo)
                    statCard(value: "\(snapshot.workouts.count)", label: "Workouts", icon: "flame.fill", color: .orange)
                    statCard(value: "\(snapshot.activity.count)d", label: "Days Tracked", icon: "calendar", color: .blue)
                }
                .padding(.horizontal, 24)

                // Sleep section
                if !snapshot.sleep.isEmpty {
                    sectionView(title: "Sleep Analysis", icon: "moon.fill") {
                        let nights = groupSleepByNight(snapshot.sleep)
                        ForEach(Array(nights.prefix(7).enumerated()), id: \.offset) { _, night in
                            HStack {
                                Text(night.date, style: .date)
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.1fh", night.totalHours))
                                    .font(.subheadline.bold())
                            }
                        }
                        if nights.count > 7 {
                            Text("+\(nights.count - 7) more nights")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Workouts section
                if !snapshot.workouts.isEmpty {
                    sectionView(title: "Workouts", icon: "flame.fill") {
                        ForEach(Array(snapshot.workouts.prefix(10).enumerated()), id: \.offset) { _, workout in
                            HStack {
                                Text(workout.activityType)
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.0f min", workout.durationMinutes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(workout.startDate, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if snapshot.workouts.count > 10 {
                            Text("+\(snapshot.workouts.count - 10) more workouts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                            .background(Color.pink)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

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
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionView<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content()
        }
        .padding()
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private struct SleepNight {
        let date: Date
        let totalHours: Double
    }

    private func groupSleepByNight(_ entries: [HealthSnapshot.SleepEntry]) -> [SleepNight] {
        let calendar = Calendar.current
        var nightMap: [Date: Double] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.startDate)
            nightMap[day, default: 0] += entry.durationMinutes / 60
        }
        return nightMap.map { SleepNight(date: $0.key, totalHours: $0.value) }
            .sorted { $0.date > $1.date }
    }
}

#Preview {
    HealthCaptureView()
        .modelContainer(for: HealthRecord.self, inMemory: true)
}
