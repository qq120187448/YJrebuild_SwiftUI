import SwiftUI

struct WallDefectSettingsView: View {
    var body: some View {
        Form {
            Section("缺陷识别") {
                NavigationLink {
                    CrackRecognitionSettingsView()
                } label: {
                    Label("识别参数设置", systemImage: "slider.horizontal.3")
                }
            }

            Section("工具") {
                NavigationLink {
                    CrackPhotoLabView()
                } label: {
                    Label("裂缝照片检测", systemImage: "photo.on.rectangle")
                }
                NavigationLink {
                    CrackModelValidationView()
                } label: {
                    Label("模型分辨率验证", systemImage: "checkmark.seal")
                }
            }
        }
        .navigationTitle("墙地面缺陷扫描设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
