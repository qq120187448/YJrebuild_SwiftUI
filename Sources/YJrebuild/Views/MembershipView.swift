import SwiftUI
struct MembershipView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ScrollView {
            Color(hex: "1C1C1E").ignoresSafeArea()
            VStack(spacing: 24) {
                Button(action: { dismiss() }) { Circle().fill(Color.white.opacity(0.1)).frame(width: 36).overlay(Image(systemName: "xmark").foregroundColor(.white)) }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 50)
                Text("youjiscan").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                Text("unlock pro features").foregroundColor(.white70)
                VStack(spacing: 8) { ForEach(["watermark_free","high_res","unlimited_ocr","batch_export","lidar_boost","no_ads"], id:\.self) { f in HStack { Text(f).foregroundColor(.white); Spacer(); Text("free").foregroundColor(.white54); Spacer(); Text("pro").foregroundColor(Color(hex: "E74C3C")) }.font(.system(size: 13)).padding(.vertical, 8) } }.padding(18).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20)
                HStack { VStack(alignment: .leading) { Text("yearly").foregroundColor(.white); Text("save_60%").foregroundColor(Color(hex: "E74C3C")).font(.system(size: 12)) }; Spacer(); Text("198/year").foregroundColor(.white).fontWeight(.bold) }.padding(18).background(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "E74C3C"), lineWidth: 2)).padding(.horizontal, 20)
                HStack { Text("monthly").foregroundColor(.white70); Spacer(); Text("25/month").foregroundColor(.white70).fontWeight(.bold) }.padding(18).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20)
                Button("subscribe") {}.frame(maxWidth: .infinity, minHeight: 50).background(Color(hex: "E74C3C")).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 20)
                Spacer().frame(height: 30)
            }
        }.background(Color(hex: "1C1C1E"))
    }
}
