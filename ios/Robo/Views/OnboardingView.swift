import SwiftUI

struct OnboardingView: View {
    @AppStorage("firstName") private var firstName = ""
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    /// Migrate old "userName" key to "firstName" (one-time)
    private func migrateUserNameIfNeeded() {
        if firstName.isEmpty, let old = UserDefaults.standard.string(forKey: "userName"), !old.isEmpty {
            firstName = old
            UserDefaults.standard.removeObject(forKey: "userName")
        }
    }
    @State private var nameInput = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.02, blue: 0.04), Color(red: 0.05, green: 0.05, blue: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 20)

                    // App icon
                    Image("AppIconImage")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .blue.opacity(0.3), radius: 20, y: 8)
                        .padding(.bottom, 24)

                    // Wordmark
                    HStack(spacing: 0) {
                        Text("ROBO")
                            .font(.system(size: 32, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(".")
                            .font(.system(size: 32, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.blue)
                        Text("APP")
                            .font(.system(size: 32, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.bottom, 12)

                    // Tagline
                    Text(AppCopy.App.tagline)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                        .textCase(.uppercase)
                        .tracking(2)
                        .padding(.bottom, 24)

                    // Description
                    Text("Your phone has incredible sensors. Robo connects them to your favorite AI agent.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 40)

                    // Feature pills — driven by FeatureRegistry
                    VStack(spacing: 12) {
                        ForEach(FeatureRegistry.featuredSkills) { skill in
                            featureRow(
                                icon: Self.iconForSkill(skill.id),
                                text: "\(skill.name) — \(skill.tagline)",
                                color: Self.colorForSkill(skill.id)
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)

                    // Name input section
                    VStack(spacing: 16) {
                        Text("What's your first name?")
                            .font(.headline)
                            .foregroundStyle(.white)

                        TextField("", text: $nameInput, prompt: Text("First name").foregroundStyle(.white.opacity(0.4)))
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding(16)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .foregroundStyle(.white)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .onSubmit { completeOnboarding() }
                            .padding(.horizontal, 40)
                    }
                    .id("nameInput")
                    .padding(.bottom, 24)
                    .onChange(of: isNameFocused) { _, focused in
                        if focused {
                            withAnimation {
                                proxy.scrollTo("nameInput", anchor: .center)
                            }
                        }
                    }

                    // CTA button
                    Button(action: completeOnboarding) {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.blue.opacity(0.3)
                                    : Color.blue
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            } // ScrollViewReader
        }
        .onAppear { migrateUserNameIfNeeded() }
        .onTapGesture {
            isNameFocused = false
        }
    }

    private func featureRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private static func iconForSkill(_ id: String) -> String {
        switch id {
        case "lidar": return "cube.transparent"
        case "barcode": return "barcode.viewfinder"
        case "camera": return "camera.fill"
        case "product_scan": return "cart"
        case "hit_links": return "person.3.fill"
        case "mcp_bridge": return "terminal"
        case "screenshot_share": return "square.and.arrow.up"
        default: return "star"
        }
    }

    private static func colorForSkill(_ id: String) -> Color {
        switch id {
        case "lidar": return .purple
        case "barcode": return .orange
        case "camera": return .blue
        case "product_scan": return .green
        case "hit_links": return .mint
        case "mcp_bridge": return .orange
        case "screenshot_share": return .cyan
        default: return .gray
        }
    }

    private func completeOnboarding() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        firstName = trimmed
        withAnimation(.easeInOut(duration: 0.3)) {
            hasOnboarded = true
        }
    }
}

#Preview {
    OnboardingView()
}
