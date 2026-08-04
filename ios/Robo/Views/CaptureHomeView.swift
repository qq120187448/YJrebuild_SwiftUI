import SwiftUI
import SwiftData

struct CaptureHomeView: View {
    @Binding var selectedTab: Int
    @Binding var historyFilter: ScanHistoryFilter

    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @Query(sort: \ObjectScanRecord.capturedAt, order: .reverse)
    private var objectScans: [ObjectScanRecord]

    @State private var showingLiDARScan = false
    @State private var showingObjectScan = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    featureCard(
                        title: "房间工程扫描",
                        subtitle: "扫描房间，识别墙、门窗、家具，生成工程量清单",
                        icon: "house",
                        startTitle: "开始房间扫描",
                        historyCount: rooms.count,
                        startAction: {
                            showingLiDARScan = true
                        },
                        historyAction: {
                            historyFilter = .room
                            selectedTab = 1
                        }
                    )

                    featureCard(
                        title: "物体工程扫描",
                        subtitle: "扫描堆体、土方、设备，计算体积、表面积和外包围尺寸",
                        icon: "cube.transparent",
                        startTitle: "开始物体扫描",
                        historyCount: objectScans.count,
                        startAction: {
                            showingObjectScan = true
                        },
                        historyAction: {
                            historyFilter = .object
                            selectedTab = 1
                        }
                    )
                }
                .padding(16)
            }
            .navigationTitle(AppStrings.Tabs.capture)
        }
        .fullScreenCover(isPresented: $showingLiDARScan) {
            LiDARScanView()
        }
        .fullScreenCover(isPresented: $showingObjectScan) {
            ObjectScanView()
        }
    }

    private func featureCard(
        title: String,
        subtitle: String,
        icon: String,
        startTitle: String,
        historyCount: Int,
        startAction: @escaping () -> Void,
        historyAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: startAction) {
                Label(startTitle, systemImage: icon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button(action: historyAction) {
                Label(
                    historyCount > 0 ? "历史记录（\(historyCount)）" : "历史记录（0）",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.secondary.opacity(0.12))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
