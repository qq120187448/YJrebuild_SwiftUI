import SwiftUI

struct HitListView: View {
    @Environment(APIService.self) private var apiService

    @Binding var deepLinkHitId: String?

    @State private var hits: [HitSummary] = []
    @State private var isLoading = false
    @State private var navigationPath = NavigationPath()
    @State private var showClearOldConfirm = false

    /// Groups HITs by group_id; ungrouped HITs get their own "group" of 1
    private var groupedHits: [HitGroup] {
        var groups: [String: [HitSummary]] = [:]
        var ungrouped: [HitSummary] = []
        for hit in hits {
            if let gid = hit.groupId, !gid.isEmpty {
                groups[gid, default: []].append(hit)
            } else {
                ungrouped.append(hit)
            }
        }
        var result: [HitGroup] = groups.map { gid, members in
            HitGroup(groupId: gid, hits: members)
        }
        for hit in ungrouped {
            result.append(HitGroup(groupId: nil, hits: [hit]))
        }
        // Sort all by newest first
        result.sort { ($0.hits.first?.createdAt ?? "") > ($1.hits.first?.createdAt ?? "") }
        return result
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isLoading && hits.isEmpty {
                    ProgressView("Loading HITs...")
                } else if hits.isEmpty {
                    ContentUnavailableView {
                        Label("No HITs Yet", systemImage: "link.badge.plus")
                    } description: {
                        Text("Use the Chat tab to create HITs.\nTry: \"Plan a dinner with Sarah and Mike\"")
                    } actions: {
                        Button("Open Chat") {
                            NotificationCenter.default.post(name: .switchToChat, object: nil)
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.15, green: 0.39, blue: 0.92))
                    }
                } else {
                    List {
                        ForEach(groupedHits) { group in
                            if group.hits.count > 1 {
                                NavigationLink(value: group.hits.first!.id) {
                                    CompactGroupRow(group: group)
                                }
                                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteGroup(group) }
                                    } label: {
                                        Label("Delete Group", systemImage: "trash")
                                    }
                                }
                            } else if let hit = group.hits.first {
                                NavigationLink(value: hit.id) {
                                    CompactHitRow(hit: hit)
                                }
                                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteHit(hit) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await loadHits() }
                }
            }
            .navigationTitle("HITs")
            .navigationDestination(for: String.self) { hitId in
                HitDetailView(hitId: hitId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !hits.isEmpty {
                        Button("Clear Old") {
                            showClearOldConfirm = true
                        }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .switchToChat, object: nil)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color(red: 0.15, green: 0.39, blue: 0.92))
                    }
                }
            }
            .confirmationDialog("Clear Old HITs", isPresented: $showClearOldConfirm) {
                Button("Delete pending HITs older than 7 days", role: .destructive) {
                    Task { await clearOldHits() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task { await loadHits() }
            .onChange(of: deepLinkHitId) { _, hitId in
                if let hitId {
                    navigationPath.append(hitId)
                    deepLinkHitId = nil
                }
            }
        }
    }

    private func deleteHit(_ hit: HitSummary) async {
        do {
            try await apiService.deleteHit(id: hit.id)
            withAnimation { hits.removeAll { $0.id == hit.id } }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            // Silently fail — user can retry
        }
    }

    private func deleteGroup(_ group: HitGroup) async {
        let ids = group.hits.map(\.id)
        do {
            _ = try await apiService.bulkDeleteHits(ids: ids)
            withAnimation { hits.removeAll { ids.contains($0.id) } }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            // Silently fail — user can retry
        }
    }

    private func clearOldHits() async {
        do {
            let result = try await apiService.deleteOldHits(olderThanDays: 7, status: "pending")
            if result.deleted > 0 {
                withAnimation { hits.removeAll { result.ids.contains($0.id) } }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } catch {
            // Silently fail
        }
    }

    private func loadHits() async {
        isLoading = true
        do {
            hits = try await apiService.fetchHits()
        } catch {
            // Silently fail — user can pull to refresh
        }
        isLoading = false
    }
}

// MARK: - Group Model

private struct HitGroup: Identifiable {
    let groupId: String?
    let hits: [HitSummary]

    var id: String { groupId ?? hits.first?.id ?? UUID().uuidString }
}

// MARK: - Compact Hit Row (~44pt)

private struct CompactHitRow: View {
    let hit: HitSummary

    private var statusColor: Color {
        switch hit.status {
        case "completed": return .green
        case "in_progress": return .orange
        case "expired": return .red
        default: return .gray
        }
    }

    private var typeIcon: String {
        switch hit.hitType {
        case "group_poll": return "chart.bar.fill"
        case "availability": return "calendar"
        case "photo": return "camera.fill"
        default: return "link"
        }
    }

    private var relativeTime: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: hit.createdAt) else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Image(systemName: typeIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(hit.recipientName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(hit.taskDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Compact Group Row

private struct CompactGroupRow: View {
    let group: HitGroup

    private var firstHit: HitSummary { group.hits.first! }
    private var count: Int { group.hits.count }

    private var overallStatus: String {
        let statuses = group.hits.map(\.status)
        if statuses.allSatisfy({ $0 == "completed" }) { return "completed" }
        if statuses.contains("in_progress") { return "in_progress" }
        return "pending"
    }

    private var statusColor: Color {
        switch overallStatus {
        case "completed": return .green
        case "in_progress": return .orange
        default: return .gray
        }
    }

    private var respondedCount: Int {
        group.hits.filter { ($0.responseCount ?? 0) > 0 || $0.status == "completed" }.count
    }

    private var typeIcon: String {
        switch firstHit.hitType {
        case "group_poll": return "chart.bar.fill"
        case "availability": return "calendar"
        case "photo": return "camera.fill"
        default: return "link"
        }
    }

    private var relativeTime: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: firstHit.createdAt) else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Image(systemName: typeIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(firstHit.taskDescription)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(count) people \u{2022} \(respondedCount)/\(count) responded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}
