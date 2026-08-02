import SwiftUI
@preconcurrency import FoundationModels

struct HitDetailView: View {
    @Environment(APIService.self) private var apiService

    let hitId: String
    private let roboBlue = Color(red: 0.15, green: 0.39, blue: 0.92)
    @Environment(\.dismiss) private var dismiss

    @State private var hit: HitSummary?
    @State private var photos: [HitPhotoItem] = []
    @State private var responses: [HitResponseItem] = []
    @State private var groupHits: [HitSummary] = []
    @State private var isLoading = true
    @State private var isInitialLoad = true
    @State private var errorMessage: String?
    @State private var copiedText: String?
    @State private var showDeleteConfirm = false
    @State private var summaryText: String?
    @State private var isSummarizing = false

    var body: some View {
        Group {
            if isLoading && isInitialLoad {
                ProgressView("Loading...")
            } else if let hit {
                ScrollView {
                    VStack(spacing: 16) {
                        // Header card
                        headerCard(hit)

                        // Actions row
                        actionsRow(hit)

                        // Apple Intelligence summary
                        if !responses.isEmpty {
                            if #available(iOS 26, *) {
                                summarizeCard(hit)
                            }
                        }

                        // Poll results (group_poll)
                        if hit.hitType == "group_poll" && !responses.isEmpty {
                            pollResultsCard(hit)
                        }

                        // Availability results
                        if hit.hitType == "availability" && !responses.isEmpty {
                            availabilityCard
                        }

                        // Photos
                        if hit.photoCount > 0 {
                            photosCard(hit)
                        }

                        // Responses list (non-poll types)
                        if hit.hitType != "group_poll" && hit.hitType != "availability" && !responses.isEmpty {
                            responsesCard
                        }

                        // Empty state when no responses yet
                        if responses.isEmpty && hit.status != "completed" {
                            VStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Waiting for responses...")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Share the link and responses will appear here")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .padding(.horizontal, 16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ContentUnavailableView {
                    Label("HIT Not Found", systemImage: "questionmark.circle")
                } description: {
                    Text("This HIT may have been deleted.")
                }
            }
        }
        .navigationTitle(hit?.recipientName ?? "HIT")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hit != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .confirmationDialog("Delete this HIT?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteHitAndPop() }
            }
        } message: {
            Text("This will permanently delete this HIT and all its responses.")
        }
        .refreshable { await loadHit() }
        .task { await loadHit() }
        .overlay(alignment: .top) {
            if let text = copiedText {
                copiedToast(text)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header Card

    private func headerCard(_ hit: HitSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Type + status row
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: typeIcon(hit.hitType))
                        .font(.caption2)
                    Text(typeLabel(hit.hitType).uppercased())
                        .font(.caption2.bold())
                        .tracking(0.5)
                }
                .foregroundStyle(roboBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(roboBlue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()

                StatusPill(status: hit.status)
            }

            // Task description
            Text(hit.taskDescription)
                .font(.body)
                .foregroundStyle(.primary)

            // Metadata grid
            HStack(spacing: 16) {
                MetadataItem(label: "TO", value: hit.recipientName)
                MetadataItem(label: "CREATED", value: relativeTime(hit.createdAt))
                if let completed = hit.completedAt {
                    MetadataItem(label: "DONE", value: relativeTime(completed))
                }
            }

            // ID
            Text(hit.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions Row

    private func actionsRow(_ hit: HitSummary) -> some View {
        HStack(spacing: 12) {
            // Copy link
            ActionButton(
                icon: copiedText == "link" ? "checkmark.circle.fill" : "link",
                label: copiedText == "link" ? "Copied!" : "Copy Link",
                color: copiedText == "link" ? .green : roboBlue
            ) {
                let url = "https://robo.app/hit/\(hit.id)"
                UIPasteboard.general.string = url
                showCopied("link")
            }

            // Share (includes results text when available)
            ActionButton(icon: "square.and.arrow.up", label: "Share", color: roboBlue) {
                let url = "https://robo.app/hit/\(hit.id)"
                var items: [Any] = [URL(string: url)!]
                if !responses.isEmpty {
                    let summary = buildResultsSummary(hit)
                    items.append(summary)
                }
                let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = windowScene.windows.first?.rootViewController {
                    root.present(activityVC, animated: true)
                }
            }

            // Copy results (for polls with responses)
            if (hit.hitType == "group_poll" || hit.hitType == "availability") && !responses.isEmpty {
                ActionButton(
                    icon: copiedText == "results" ? "checkmark.circle.fill" : "doc.on.clipboard",
                    label: copiedText == "results" ? "Copied!" : "Copy Results",
                    color: copiedText == "results" ? .green : .orange
                ) {
                    let summary = buildResultsSummary(hit)
                    UIPasteboard.general.string = summary
                    showCopied("results")
                }
            }
        }
    }

    // MARK: - Poll Results Card (group_poll)

    private func pollResultsCard(_ hit: HitSummary) -> some View {
        let tallies = computePollTallies()
        let maxVotes = tallies.map(\.count).max() ?? 1
        let config = hit.config != nil ? (try? JSONSerialization.jsonObject(with: Data((hit.config ?? "{}").utf8)) as? [String: Any]) ?? [:] : [:]
        let title = config["title"] as? String ?? config["context"] as? String ?? "Poll"
        let participants = config["participants"] as? [String] ?? []
        let totalParticipants = participants.isEmpty ? responses.count : participants.count
        let respondedCount = Set(responses.map(\.respondentName)).count

        return VStack(alignment: .leading, spacing: 14) {
            // Section header
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(respondedCount)/\(totalParticipants) voted")
                    .font(.caption.bold())
                    .foregroundStyle(respondedCount == totalParticipants ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((respondedCount == totalParticipants ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
            }

            // Bar chart
            let winnerCount = tallies.filter { $0.count == maxVotes }.count
            ForEach(Array(tallies.enumerated()), id: \.element.slot) { index, tally in
                let isWinner = index == 0 && winnerCount == 1
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tally.slot)
                            .font(.subheadline.weight(isWinner ? .bold : .regular))
                            .foregroundStyle(isWinner ? .primary : .secondary)

                        Spacer()

                        Text("\(tally.count) vote\(tally.count == 1 ? "" : "s")")
                            .font(.caption.bold())
                            .monospacedDigit()
                            .foregroundStyle(isWinner ? roboBlue : .secondary)
                    }

                    // Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.systemGray5))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isWinner ? roboBlue : Color(.systemGray3))
                                .frame(width: geo.size.width * CGFloat(tally.count) / CGFloat(maxVotes), height: 8)
                        }
                    }
                    .frame(height: 8)

                    // Voter names
                    Text(tally.voters.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }

            // Waiting on
            if !participants.isEmpty {
                let responded = Set(responses.map(\.respondentName))
                let waiting = participants.filter { !responded.contains($0) }
                if !waiting.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Waiting: \(waiting.joined(separator: ", "))")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Availability Card

    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Availability")
                    .font(.headline)
                Spacer()
                Text("\(responses.count) response\(responses.count == 1 ? "" : "s")")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            let tallies = computeSlotTallies()
            let maxVotes = tallies.map(\.count).max() ?? 1

            ForEach(tallies, id: \.slot) { tally in
                let isTop = tally.count == maxVotes
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tally.slot)
                            .font(.subheadline.weight(isTop ? .bold : .regular))
                        Text(tally.voters.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(tally.count)")
                        .font(.title3.bold())
                        .foregroundStyle(isTop ? roboBlue : .secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Photos Card

    private func photosCard(_ hit: HitSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Photos")
                    .font(.headline)
                Spacer()
                Text("\(hit.photoCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            ForEach(photos) { photo in
                HStack {
                    Image(systemName: "photo.fill")
                        .foregroundStyle(roboBlue)
                    Text(photo.r2Key.components(separatedBy: "/").last ?? photo.id)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    if let size = photo.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Generic Responses Card

    private var responsesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Responses (\(responses.count))")
                .font(.headline)

            ForEach(responses) { response in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.green)
                    Text(response.respondentName)
                        .font(.subheadline)
                    Spacer()
                    Text(relativeTime(response.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Copied Toast

    private func copiedToast(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied to clipboard")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.top, 8)
    }

    private func showCopied(_ key: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(duration: 0.3)) { copiedText = key }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(duration: 0.3)) { copiedText = nil }
        }
    }

    // MARK: - Helpers

    private func typeIcon(_ type: String?) -> String {
        switch type {
        case "group_poll": return "chart.bar.fill"
        case "availability": return "calendar"
        case "photo": return "camera.fill"
        default: return "link"
        }
    }

    private func typeLabel(_ type: String?) -> String {
        switch type {
        case "group_poll": return "Poll"
        case "availability": return "Availability"
        case "photo": return "Photo"
        default: return "HIT"
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        let display = DateFormatter()
        display.dateStyle = .medium
        return display.string(from: date)
    }

    // MARK: - Poll Tally Computation

    private struct SlotTally {
        let slot: String
        let count: Int
        let voters: [String]
    }

    private func computePollTallies() -> [SlotTally] {
        var slotVoters: [String: [String]] = [:]

        for response in responses {
            if let dates = response.responseData["selected_dates"]?.value as? [String] {
                for date in dates {
                    let formatted = formatDate(date)
                    slotVoters[formatted, default: []].append(response.respondentName)
                }
            }
        }

        return slotVoters
            .map { SlotTally(slot: $0.key, count: $0.value.count, voters: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.slot < $1.slot }
    }

    private func computeSlotTallies() -> [SlotTally] {
        var slotVoters: [String: [String]] = [:]

        for response in responses {
            if let slots = response.responseData["available_slots"]?.value as? [[String: Any]] {
                for slot in slots {
                    if let date = slot["date"] as? String, let time = slot["time"] as? String {
                        let key = "\(formatDate(date)) \(time)"
                        slotVoters[key, default: []].append(response.respondentName)
                    }
                }
            }
        }

        return slotVoters
            .map { SlotTally(slot: $0.key, count: $0.value.count, voters: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.slot < $1.slot }
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = "EEE MMM d, yyyy"
        return display.string(from: date)
    }

    private func buildResultsSummary(_ hit: HitSummary) -> String {
        let config = hit.config != nil ? (try? JSONSerialization.jsonObject(with: Data((hit.config ?? "{}").utf8)) as? [String: Any]) ?? [:] : [:]
        let title = config["title"] as? String ?? config["context"] as? String ?? "Poll"

        let tallies: [SlotTally]
        if hit.hitType == "group_poll" {
            tallies = computePollTallies()
        } else {
            tallies = computeSlotTallies()
        }

        var lines = ["\(title) Results:"]
        for tally in tallies {
            let voteWord = tally.count == 1 ? "vote" : "votes"
            lines.append("\(tally.slot) (\(tally.count) \(voteWord)) — \(tally.voters.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Summarize Card

    @available(iOS 26, *)
    private func summarizeCard(_ hit: HitSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = summaryText {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("AI Summary")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                }
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            } else {
                Button {
                    Task { await summarizeResults(hit) }
                } label: {
                    HStack(spacing: 8) {
                        if isSummarizing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isSummarizing ? "Summarizing..." : "Summarize with Apple Intelligence")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.purple.opacity(0.08))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isSummarizing)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @available(iOS 26, *)
    private func summarizeResults(_ hit: HitSummary) async {
        isSummarizing = true
        defer { isSummarizing = false }

        let resultsText = buildResultsSummary(hit)
        let prompt = "Summarize these poll/survey results concisely in 2-3 sentences. Focus on the key takeaway and any consensus: \(resultsText)"

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            withAnimation { summaryText = response.content }
        } catch {
            summaryText = "Could not generate summary. Apple Intelligence may not be available on this device."
        }
    }

    private func deleteHitAndPop() async {
        do {
            try await apiService.deleteHit(id: hitId)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    // MARK: - Data Loading

    private func loadHit() async {
        isLoading = true
        do {
            hit = try await apiService.fetchHit(id: hitId)
            if let hit {
                if hit.photoCount > 0 {
                    photos = try await apiService.fetchHitPhotos(hitId: hitId)
                }
                // Load responses for all HIT types
                if let groupId = hit.groupId {
                    groupHits = try await apiService.fetchHitsByGroup(groupId: groupId)
                    var allResponses: [HitResponseItem] = []
                    for groupHit in groupHits {
                        let hitResponses = try await apiService.fetchHitResponses(hitId: groupHit.id)
                        allResponses.append(contentsOf: hitResponses)
                    }
                    responses = allResponses
                } else {
                    responses = try await apiService.fetchHitResponses(hitId: hitId)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isInitialLoad = false
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: String

    private var color: Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .orange
        case "expired": return .red
        default: return .gray
        }
    }

    private var label: String {
        switch status {
        case "completed": return "DONE"
        case "in_progress": return "ACTIVE"
        case "expired": return "EXPIRED"
        default: return "PENDING"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.bold())
                .tracking(0.3)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Metadata Item

private struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.body)
                Text(label)
                    .font(.caption2.bold())
                    .tracking(0.3)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
