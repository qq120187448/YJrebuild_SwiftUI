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
    @State private var showingWallDefectScan = false
    @State private var showingToyBox = false

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
                    VStack(spacing: 22) {
                        VStack(spacing: 6) {
                            Image(systemName: "scope")
                                .font(.system(size: 34))
                                .foregroundStyle(.cyan)
                            Text("Robo 工程扫描")
                                .font(.largeTitle.bold())
                                .foregroundStyle(.white)
                            Text("LiDAR 扫描 · 3D 建模 · 工程量计算")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(.top, 24)

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
                            subtitle: "扫描堆体、土方、设备，计算体积、表面积和 OBB 外包围尺寸",
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

                        textureFeatureCard(
                            title: "墙地面缺陷扫描",
                            subtitle: "RoomPlan 全屋建模 + 手动定点拍照 + 本地缺陷识别",
                            icon: "paintbrush.pointed",
                            startTitle: "开始墙地面扫描",
                            startAction: {
                                showingWallDefectScan = true
                            }
                        )

                        textureFeatureCard(
                            title: "玩具箱",
                            subtitle: "趣味物体建模 + 区域实景建模",
                            icon: "puzzlepiece",
                            startTitle: "打开玩具箱",
                            startAction: {
                                showingToyBox = true
                            }
                        )
                    }
                    .padding(16)
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

    private func textureFeatureCard(
        title: String,
        subtitle: String,
        icon: String,
        startTitle: String,
        startAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.85), Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button(action: startAction) {
                Label(startTitle, systemImage: icon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [Color.teal, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(Color(red: 0.08, green: 0.11, blue: 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.teal.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.8), Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button(action: startAction) {
                Label(startTitle, systemImage: icon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
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
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(Color(red: 0.08, green: 0.11, blue: 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
