import SwiftUI

struct ModelEditorView: View {
    @Environment(\.dismiss) var dismiss
    @State private var activeTool = 0
    @State private var sliderValue: Double = 0.5
    @State private var holeFill = false

    let tools = [("??", "crop"), ("??", "circle.dotted"), ("??", "square.grid.3x3"), ("??", "slider.horizontal.3")]

    var body: some View {
        ZStack {
            Color(hex: "1A1A1A").ignoresSafeArea()
            VStack { Image(systemName: "view.3d").font(.system(size: 80)).foregroundColor(.white.opacity(0.1)) }
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Circle().fill(Color.white.opacity(0.15)).frame(width: 38)
                            .overlay(Image(systemName: "arrow.left").foregroundColor(.white))
                    }
                    Spacer()
                    Text("????").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Spacer().frame(width: 38)
                }.padding(.top, 50)
                Spacer()
                if activeTool > 0 {
                    VStack(spacing: 8) {
                        Text("????").foregroundColor(.white)
                        Slider(value: $sliderValue).tint(Color(hex: "E74C3C"))
                        if activeTool == 3 {
                            Toggle("????", isOn: $holeFill).foregroundColor(.white).tint(Color(hex: "E74C3C"))
                        }
                    }.padding(14).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 12)
                }
                HStack {
                    Button(action: {}) { Image(systemName: "arrow.uturn.backward").foregroundColor(.white) }
                    ScrollView(.horizontal) { HStack(spacing: 8) {
                        ForEach(tools, id: \.0) { title, icon in
                            Button(action: {}) {
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)).frame(width: 38, height: 36)
                                        .overlay(Image(systemName: icon).foregroundColor(.white))
                                    Text(title).font(.system(size: 10)).foregroundColor(.white)
                                }.frame(width: 52)
                            }
                        }
                    }}
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
    }
}
