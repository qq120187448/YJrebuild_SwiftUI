import SwiftUI
import SwiftData
import AudioToolbox

struct MotionCaptureView: View {
    var captureContext: CaptureContext? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var phase: CapturePhase = .instructions
    @State private var snapshot: MotionSnapshot?
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
                        MotionResultView(
                            snapshot: snapshot,
                            onSave: saveMotion,
                            onDiscard: { dismiss() }
                        )
                    }
                }
            }
            .navigationTitle(phase == .instructions ? "Motion Capture" : "Motion Results")
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

            Image(systemName: "figure.walk.motion")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Motion & Activity")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                tipRow(icon: "shoe", text: "Captures the last 7 days of step count and distance")
                tipRow(icon: "arrow.up.right", text: "Includes floors ascended and descended")
                tipRow(icon: "figure.run", text: "Detects activity types: walking, running, driving")
                tipRow(icon: "lock.shield", text: "All data stays on your device until you share it")
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                captureMotion()
            } label: {
                if isCapturing {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Capture Motion Data")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(isCapturing)
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

    private func captureMotion() {
        isCapturing = true
        Task {
            do {
                let result = try await MotionService.capture(daysBack: 7)

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

    private func saveMotion() {
        guard let snapshot else { return }

        do {
            let activityJSON = try MotionService.encodeSnapshot(snapshot)

            let record = MotionRecord(
                stepCount: snapshot.stepCount,
                distanceMeters: snapshot.distanceMeters,
                floorsAscended: snapshot.floorsAscended,
                floorsDescended: snapshot.floorsDescended,
                activityJSON: activityJSON
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

#Preview {
    MotionCaptureView()
        .modelContainer(for: MotionRecord.self, inMemory: true)
}
