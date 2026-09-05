import SwiftUI

/// First-launch welcome screen (design 1a). The design's own background is
/// a blurred photo of Elsie in her library -- substituted here with a warm
/// gradient plus the same placeholder ElsieAvatar used throughout, since the
/// real photo asset couldn't be fetched at full resolution this pass (see
/// ElsieAvatar's doc comment).
struct OnboardingView: View {
    @ObservedObject var model: AppModel

    @State private var bob = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TTA.Palette.woodDark, TTA.Palette.wood, TTA.Palette.paper],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ElsieAvatar(state: .idle, isMuted: false, diameter: 132)
                    .offset(y: bob ? -6 : 0)
                    .animation(.easeInOut(duration: 2.25).repeatForever(autoreverses: true), value: bob)
                    .onAppear { bob = true }

                Text("Hello, I'm Elsie!")
                    .font(TTA.Typography.display(34))
                    .foregroundColor(TTA.Palette.cream)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .padding(.top, 20)

                Text("I love facts and I love stories. If you talk, I'll listen — and we'll write a story together, out loud.")
                    .font(TTA.Typography.body(17))
                    .foregroundColor(TTA.Palette.paper)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TTA.Palette.teal)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "mic.fill")
                                .foregroundColor(TTA.Palette.cream)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Can I hear you?")
                            .font(TTA.Typography.display(16))
                            .foregroundColor(TTA.Palette.ink)
                        Text("Tiny Talk needs the microphone. Nothing ever leaves your house.")
                            .font(TTA.Typography.body(13.5))
                            .foregroundColor(TTA.Palette.inkSoft)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(TTA.Palette.paper.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 22)

                Button {
                    Task { await model.finishOnboarding() }
                } label: {
                    Text("Yes, let's talk!")
                }
                .buttonStyle(.ttaPrimary)
                .padding(.top, 16)

                Button {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    model.screen = .settings
                } label: {
                    Text("Grown-up setup instead")
                        .font(TTA.Typography.display(14, weight: .semibold))
                        .foregroundColor(TTA.Palette.paper)
                        .underline()
                }
                .padding(.top, 10)

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 34)
        }
    }
}
