import SwiftUI

struct ExportModal: View {
    @Environment(\.dismiss) var dismiss
    let scan: ScanModel
    var meshData: Data?

    @State private var selectedFormat: ExportService.Format = .obj
    @State private var includeTextures = true
    @State private var compress = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section("导出格式") {
                        ForEach(ExportService.Format.allCases, id: \.self) { format in
                            HStack {
                                Text(format.rawValue)
                                Spacer()
                                if selectedFormat == format {
                                    Image(systemName: "checkmark").foregroundColor(Color(hex: "E74C3C"))
                                }
                            }.contentShape(Rectangle()).onTapGesture { selectedFormat = format }
                        }
                    }
                    Section("选项") {
                        Toggle("包含纹理贴图", isOn: $includeTextures)
                        Toggle("压缩文件大小", isOn: $compress)
                    }
                }.listStyle(.insetGrouped)

                VStack(spacing: 12) {
                    Button(action: performExport) {
                        HStack {
                            if exporting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text(exporting ? "导出中..." : "导出到本地")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(hex: "E74C3C"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(exporting)
                    .padding(.horizontal, 20)

                    Button("取消") { dismiss() }
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle("导出模型")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    func performExport() {
        guard let data = meshData else {
            ToastHelper.show("No mesh data available")
            return
        }
        exporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let url = ExportService.export(meshData: data, format: selectedFormat, includeTextures: includeTextures)
            DispatchQueue.main.async {
                exporting = false
                if let url = url {
                    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        root.present(av, animated: true)
                    }
                    ToastHelper.show("导出成功: " + selectedFormat.rawValue)
                } else {
                    ToastHelper.show("导出失败", isError: true)
                }
                dismiss()
            }
        }
    }
}
