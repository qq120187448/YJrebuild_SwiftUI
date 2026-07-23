import SwiftUI
struct ModelEditorView: View {
    @Environment(\.dismiss) var dismiss; @State private var activeTool = 0; @State private var sVal: Double = 0.5
    var body: some View {
        ZStack {
            Color(hex: "1A1A1A").ignoresSafeArea()
            VStack { Image(systemName: "view.3d").font(.system(size: 80)).foregroundColor(.white.opacity(0.1)) }
            VStack {
                HStack { Button(action: { dismiss() }) { Circle().fill(Color.white.opacity(0.15)).frame(width: 38).overlay(Image(systemName: "arrow.left").foregroundColor(.white)) }; Spacer(); Text("editor").font(.system(size: 16, weight: .semibold)).foregroundColor(.white); Spacer().frame(width: 38) }.padding(.top, 50)
                Spacer()
                if activeTool > 0 { VStack(spacing: 8) { Text("tool_\(activeTool)").foregroundColor(.white); Slider(value: $sVal).tint(Color(hex: "E74C3C")) }.padding(14).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 12) }
                HStack { Button(action: {}) { Image(systemName: "arrow.uturn.backward").foregroundColor(.white) }; ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(["crop","smooth","holes","simplify"], id:\.self) { t in Button(action: {}) { VStack(spacing: 2) { RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)).frame(width: 38, height: 36).overlay(Image(systemName: ["crop","circle.dotted","square.grid.3x3","slider.horizontal.3"][["crop","smooth","holes","simplify"].firstIndex(of: t)!]).foregroundColor(.white)); Text(t).font(.system(size: 10)).foregroundColor(.white) }.frame(width: 52) } } } }; Spacer() }.padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
    }
}
