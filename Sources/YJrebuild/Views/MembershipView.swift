import SwiftUI

struct MembershipView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ZStack {
            Color(hex: "1C1C1E").ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Button(action: { dismiss() }) {
                        Circle().fill(Color.white.opacity(0.1)).frame(width: 36).overlay(Image(systemName: "xmark").foregroundColor(.white))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 50)
                    Text("UJISCAN").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    Text("Unlock Pro Features").foregroundColor(.secondary).font(.system(size: 15))
                    VStack(spacing: 0) {
                        ForEach(["Watermark Free", "High Res Mesh", "Unlimited OCR", "Batch Export", "LiDAR Boost", "No Ads"], id: \.self) { f in
                            HStack { Text(f).foregroundColor(.white).font(.system(size: 13)); Spacer(); Text("OK").foregroundColor(Color(hex: "E74C3C")).fontWeight(.bold) }.padding(.vertical, 8)
                        }
                    }.padding(18).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20)
                    Button("SUBSCRIBE") {}.font(.system(size: 16, weight: .semibold)).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 50).background(Color(hex: "E74C3C")).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 20)
                    Spacer().frame(height: 40)
                }
            }
        }
    }
}
