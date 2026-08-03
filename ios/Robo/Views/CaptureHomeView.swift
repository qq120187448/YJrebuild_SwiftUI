import SwiftUI
import SwiftData

struct CaptureHomeView: View {
    @Binding var selectedTab: Int

    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @State private var showingLiDARScan = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 72))
                    .foregroundStyle(.purple)

                Text("LiDAR 房间扫描")
                    .font(.title.bold())

                Text("扫描后自动生成工程量清单，可导出 JSON 和 CSV。\n所有数据只保存在本机。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !rooms.isEmpty {
                    Button {
                        selectedTab = 1
                    } label: {
                        VStack(spacing: 6) {
                            Text("已有 \(rooms.count) 条扫描记录")
                                .font(.headline)
                            Text("最近一次：\(rooms.first?.roomName ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    showingLiDARScan = true
                } label: {
                    Label(AppStrings.Scan.start, systemImage: "camera.metering.spot")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
            .navigationTitle(AppStrings.Tabs.capture)
        }
        .fullScreenCover(isPresented: $showingLiDARScan) {
            LiDARScanView()
        }
    }
}
