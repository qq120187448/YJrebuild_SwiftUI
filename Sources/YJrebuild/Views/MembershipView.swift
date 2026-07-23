import SwiftUI

struct MembershipView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color(hex: "1C1C1E").ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Circle().fill(Color.white.opacity(0.1)).frame(width: 36)
                                .overlay(Image(systemName: "xmark").foregroundColor(.white))
                        }
                        Spacer()
                    }.padding(.top, 50)

                    Text("????").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    Text("???????").foregroundColor(.secondary).font(.system(size: 15))

                    // ????
                    VStack(spacing: 0) {
                        HStack {
                            Text("??").foregroundColor(.white54).font(.system(size: 12, weight: .semibold))
                            Spacer(); Text("???").foregroundColor(.white54).font(.system(size: 12))
                            Spacer(); Text("???").foregroundColor(.white54).font(.system(size: 12))
                        }.padding(.bottom, 8)

                        ForEach(["?????", "?????", "?? OCR", "????", "LiDAR????", "????"], id: \.self) { feature in
                            HStack {
                                Text(feature).foregroundColor(.white).font(.system(size: 13))
                                Spacer(); Text("?").foregroundColor(.secondary)
                                Spacer(); Text("?").foregroundColor(Color(hex: "E74C3C")).fontWeight(.bold)
                            }.padding(.vertical, 8)
                        }
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                    // ??
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("????").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                                Text("??? ? ??60%").font(.system(size: 12)).foregroundColor(Color(hex: "E74C3C"))
                            }
                            Spacer()
                            Text("?198/?").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                        }.padding(18)
                        .background(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "E74C3C"), lineWidth: 2))
                        .padding(.horizontal, 20)

                        HStack {
                            Text("????").font(.system(size: 17)).foregroundColor(.secondary)
                            Spacer()
                            Text("?25/?").font(.system(size: 18, weight: .bold)).foregroundColor(.secondary)
                        }.padding(18)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 20)
                    }

                    Button("????") {}
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(hex: "E74C3C"))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)

                    HStack(spacing: 24) {
                        Button("????", action: {}).foregroundColor(.secondary).font(.system(size: 13))
                        Button("????", action: {}).foregroundColor(.secondary).font(.system(size: 13))
                    }
                    Spacer().frame(height: 40)
                }
            }
        }
    }
}
