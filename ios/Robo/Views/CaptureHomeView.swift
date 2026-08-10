import SwiftData
import SwiftUI

struct CaptureHomeView: View {
    @Binding var selectedTab: Int
    @Binding var historyFilter: ScanHistoryFilter

    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @Query(sort: \ObjectScanRecord.capturedAt, order: .reverse)
    private var objectScans: [ObjectScanRecord]

    @State private var showingLiDARScan = false
    @State private var showingObjectScan = false
    @State private var showingWallDefectScan = false
    @State private var showingToyBox = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.06, blue: 0.11),
                        Color(red: 0.08, green: 0.12, blue: 0.2)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        header

                        LazyVGrid(columns: columns, spacing: 12) {
                            compactCard(
                                title: "房间工程扫描",
                                subtitle: "房间建模与工程量",
                                icon: "house",
                                color: .cyan,
                                startTitle: "开始",
                                historyCount: rooms.count,
                                startAction: {
                                    showingLiDARScan = true
                                },
                                historyAction: {
                                    historyFilter = .room
                                    selectedTab = 1
                                }
                            )

                            compactCard(
                                title: "物体工程扫描",
                                subtitle: "堆体、土方、设备",
                                icon: "cube.transparent",
                                color: .teal,
                                startTitle: "开始",
                                historyCount: objectScans.count,
                                startAction: {
                                    showingObjectScan = true
                                },
                                historyAction: {
                                    historyFilter = .object
                                    selectedTab = 1
                                }
                            )

                            compactCard(
                                title: "墙地面缺陷扫描",
                                subtitle: "ARKit + 缺陷识别",
                                icon: "paintbrush.pointed",
                                color: .orange,
                                startTitle: "开始",
                                historyCount: nil,
                                startAction: {
                                    showingWallDefectScan = true
                                },
                                historyAction: nil
                            )

                            compactCard(
                                title: "玩具箱",
                                subtitle: "物体建模 + 区域建模",
                                icon: "puzzlepiece",
                                color: .purple,
                                startTitle: "打开",
                                historyCount: nil,
                                startAction: {
                                    showingToyBox = true
                                },
                                historyAction: nil
                            )
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showingLiDARScan) {
            LiDARScanView()
        }
        .fullScreenCover(isPresented: $showingObjectScan) {
            ObjectScanView()
        }
        .fullScreenCover(isPresented: $showingWallDefectScan) {
            WallDefectScanView()
        }
        .fullScreenCover(isPresented: $showingToyBox) {
            ToyBoxView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("Robo 工程扫描")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("LiDAR 建模 · 工程量 · 缺陷识别")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    private func compactCard(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        startTitle: String,
        historyCount: Int?,
        startAction: @escaping () -> Void,
        historyAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .frame(height: 26, alignment: .topLeading)

            Button(action: startAction) {
                Label(startTitle, systemImage: icon)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(color)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let historyCount, let historyAction {
                Button(action: historyAction) {
                    Label(
                        historyCount > 0
                            ? "历史 \(historyCount)"
                            : "历史 0",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.11, blue: 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
