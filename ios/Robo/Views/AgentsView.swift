import SwiftUI
import SwiftData
import AudioToolbox

struct AgentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse) private var roomScans: [RoomScanRecord]
    @Query(sort: \ScanRecord.capturedAt, order: .reverse) private var scans: [ScanRecord]
    @Query(sort: \ProductCaptureRecord.capturedAt, order: .reverse) private var productCaptures: [ProductCaptureRecord]
    @Query(sort: \BeaconEventRecord.capturedAt, order: .reverse) private var beaconEvents: [BeaconEventRecord]

    /// Skill types with verified, working capture flows (from registry).
    private let enabledSkillTypes: Set<AgentRequest.SkillType> = FeatureRegistry.activeSkillTypes

    @State private var agents: [AgentConnection] = MockAgentService.loadAgents()
    @State private var showingLiDARScan = false
    @State private var showingBarcode = false
    @State private var showingProductScan = false
    @State private var showingBeaconMonitor = false
    @State private var syncingAgentId: UUID?
    @State private var initialRoomCount = 0
    @State private var activePhotoAgent: AgentConnection?
    @State private var photoCapturedCount = 0
    @State private var initialBarcodeCount = 0
    @State private var initialProductCount = 0
    @State private var initialBeaconCount = 0
    @State private var completedAgentName: String?

    var body: some View {
        NavigationStack {
            Group {
                if agents.isEmpty {
                    emptyState
                } else {
                    agentsList
                }
            }
            .navigationTitle("Agents")
            .overlay(alignment: .top) {
                if let name = completedAgentName {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        Text("Response sent to \(name)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .fullScreenCover(isPresented: $showingLiDARScan, onDismiss: handleLiDARDismiss) {
            LiDARScanView(
                captureContext: activeCaptureContext,
                suggestedRoomName: agents.first(where: { $0.id == syncingAgentId })?.pendingRequest?.roomNameHint
            )
        }
        .fullScreenCover(item: $activePhotoAgent, onDismiss: handlePhotoDismiss) { agent in
            PhotoCaptureView(
                captureContext: activeCaptureContext,
                agentName: agent.name,
                checklist: agent.pendingRequest?.photoChecklist ?? [],
                photoCapturedCount: $photoCapturedCount
            )
        }
        .fullScreenCover(isPresented: $showingBarcode, onDismiss: handleBarcodeDismiss) {
            BarcodeScannerView(captureContext: activeCaptureContext)
        }
        .fullScreenCover(isPresented: $showingProductScan, onDismiss: handleProductScanDismiss) {
            ProductScanFlowView(captureContext: activeCaptureContext)
        }
        .fullScreenCover(isPresented: $showingBeaconMonitor, onDismiss: handleBeaconDismiss) {
            BeaconMonitorView(captureContext: activeCaptureContext)
        }
    }

    // MARK: - Agent List

    private var agentsList: some View {
        List {
            let visibleAgents = agents.filter { agent in
                guard let request = agent.pendingRequest else { return true }
                return enabledSkillTypes.contains(request.skillType)
            }
            let actionNeeded = visibleAgents.filter { $0.pendingRequest != nil && $0.status != .syncing }
            let syncing = visibleAgents.filter { $0.status == .syncing }
            let connected = visibleAgents.filter { $0.pendingRequest == nil && $0.status == .connected }

            if !actionNeeded.isEmpty {
                Section("Action Needed") {
                    ForEach(actionNeeded) { agent in
                        AgentRequestCard(
                            agent: agent,
                            onScanNow: { handleScanNow(agent) }
                        )
                    }
                }
            }

            if !syncing.isEmpty {
                Section {
                    ForEach(syncing) { agent in
                        SyncingAgentRow(agent: agent)
                    }
                }
            }

            if !connected.isEmpty {
                Section("Agents Ready") {
                    ForEach(connected) { agent in
                        NavigationLink {
                            AgentDetailView(agent: agent)
                        } label: {
                            ConnectedAgentRow(agent: agent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Agents Connected", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("When AI agents need sensor data from your phone, their requests appear here.")
        }
    }

    // MARK: - Capture Context

    private var activeCaptureContext: CaptureContext? {
        guard let agentId = syncingAgentId,
              let agent = agents.first(where: { $0.id == agentId }),
              let request = agent.pendingRequest else { return nil }
        return CaptureContext(agentId: agentId.uuidString, agentName: agent.name, requestId: request.id)
    }

    // MARK: - Actions

    private func handleScanNow(_ agent: AgentConnection) {
        guard let request = agent.pendingRequest else { return }

        switch request.skillType {
        case .lidar:
            initialRoomCount = roomScans.count
            syncingAgentId = agent.id
            showingLiDARScan = true
        case .camera:
            syncingAgentId = agent.id
            photoCapturedCount = 0
            activePhotoAgent = agent
        case .barcode:
            initialBarcodeCount = scans.count
            syncingAgentId = agent.id
            showingBarcode = true
        case .productScan:
            initialProductCount = productCaptures.count
            syncingAgentId = agent.id
            showingProductScan = true
        case .beacon:
            initialBeaconCount = beaconEvents.count
            syncingAgentId = agent.id
            showingBeaconMonitor = true
        case .motion:
            break
        case .health:
            break
        }
    }

    private func handleProductScanDismiss() {
        guard let agentId = syncingAgentId else { return }
        if productCaptures.count > initialProductCount {
            triggerSyncAnimation(for: agentId)
        } else {
            syncingAgentId = nil
        }
    }

    private func handleLiDARDismiss() {
        guard let agentId = syncingAgentId else { return }

        // Check if a new room scan was saved
        if roomScans.count > initialRoomCount {
            triggerSyncAnimation(for: agentId)
        } else {
            syncingAgentId = nil
        }
    }

    private func handlePhotoDismiss() {
        guard let agentId = syncingAgentId else { return }
        if photoCapturedCount > 0 {
            triggerSyncAnimation(for: agentId)
        } else {
            syncingAgentId = nil
        }
        activePhotoAgent = nil
        photoCapturedCount = 0
    }

    private func handleBarcodeDismiss() {
        guard let agentId = syncingAgentId else { return }
        if scans.count > initialBarcodeCount {
            triggerSyncAnimation(for: agentId)
        } else {
            syncingAgentId = nil
        }
    }

    private func handleBeaconDismiss() {
        guard let agentId = syncingAgentId else { return }
        if beaconEvents.count > initialBeaconCount {
            triggerSyncAnimation(for: agentId)
        } else {
            syncingAgentId = nil
        }
    }

    private func triggerSyncAnimation(for agentId: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == agentId }) else { return }

        // Show syncing state
        agents[index].status = .syncing

        // After 2 seconds, mark as synced
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let idx = agents.firstIndex(where: { $0.id == agentId }) else { return }
            let agentName = agents[idx].name
            agents[idx].status = .connected
            agents[idx].pendingRequest = nil
            agents[idx].lastSyncDate = Date()
            syncingAgentId = nil

            // Haptic
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            AudioServicesPlaySystemSound(1057)

            // Completion toast
            withAnimation(.spring(duration: 0.4)) {
                completedAgentName = agentName
            }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.spring(duration: 0.3)) {
                completedAgentName = nil
            }
        }
    }
}

// MARK: - Agent Request Card

private struct AgentRequestCard: View {
    let agent: AgentConnection
    let onScanNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: agent.iconSystemName)
                    .font(.title2)
                    .foregroundStyle(agent.accentColor)
                    .frame(width: 40, height: 40)
                    .background(agent.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.headline)
                    if let request = agent.pendingRequest {
                        Text(request.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let request = agent.pendingRequest {
                Text(request.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let checklist = request.photoChecklist, !checklist.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checklist) { task in
                            HStack(spacing: 8) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isCompleted ? .green : .secondary)
                                    .font(.subheadline)
                                Text(task.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }

                Button(action: onScanNow) {
                    Label(buttonLabel(for: request.skillType), systemImage: buttonIcon(for: request.skillType))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(agent.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func buttonLabel(for skill: AgentRequest.SkillType) -> String {
        switch skill {
        case .lidar: return "Scan Room"
        case .camera: return "Take Photos"
        case .barcode: return "Scan Barcode"
        case .productScan: return "Scan Product"
        case .motion: return "Start Capture"
        case .beacon: return "Start Monitoring"
        case .health: return "Capture Health"
        }
    }

    private func buttonIcon(for skill: AgentRequest.SkillType) -> String {
        switch skill {
        case .lidar: return "camera.metering.spot"
        case .camera: return "camera.fill"
        case .barcode: return "barcode.viewfinder"
        case .productScan: return "barcode.viewfinder"
        case .motion: return "figure.walk"
        case .beacon: return "sensor.tag.radiowaves.forward"
        case .health: return "heart.fill"
        }
    }
}

// MARK: - Syncing Row

private struct SyncingAgentRow: View {
    let agent: AgentConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.iconSystemName)
                .font(.title2)
                .foregroundStyle(agent.accentColor)
                .frame(width: 40, height: 40)
                .background(agent.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Syncing...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Connected Agent Row

private struct ConnectedAgentRow: View {
    let agent: AgentConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.iconSystemName)
                .font(.title2)
                .foregroundStyle(agent.accentColor)
                .frame(width: 40, height: 40)
                .background(agent.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                Text(agent.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let lastSync = agent.lastSyncDate {
                    Text(lastSync, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Agent Detail View

private struct AgentDetailView: View {
    let agent: AgentConnection
    @Environment(DeviceService.self) private var deviceService

    private static let claudeCodeAgentId = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: agent.iconSystemName)
                        .font(.system(size: 48))
                        .foregroundStyle(agent.accentColor)
                        .frame(width: 80, height: 80)
                        .background(agent.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    Text(agent.name)
                        .font(.title2.bold())

                    Text(agent.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if agent.id == Self.claudeCodeAgentId, let token = deviceService.config.mcpToken {
                Section {
                    ClaudeCodeConnectionView(mcpToken: token)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                HStack {
                    Label("Status", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("Ready")
                        .foregroundStyle(.secondary)
                }

                if let lastSync = agent.lastSyncDate {
                    HStack {
                        Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("When \(agent.name) needs something, it'll appear in Action Needed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    AgentsView()
        .modelContainer(for: [ScanRecord.self, RoomScanRecord.self, BeaconEventRecord.self], inMemory: true)
}
