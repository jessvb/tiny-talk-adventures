import SwiftUI
import TinyTalkCore

/// Shown right after a story naturally concludes (design 1a's "The End").
/// For now, reached only via Settings' preview buttons -- wiring this into
/// the real conclude flow needs the storybook-persistence branch's
/// ConcludeStory/story_detail wire messages, not yet merged (see
/// docs/superpowers/plans/2026-09-08-storybook-persistence.md).
struct TheEndView: View {
    @ObservedObject var model: AppModel
    var childName: String = "you"

    @State private var sparkle = false

    var body: some View {
        if let detail = model.selectedStory {
            content(for: detail)
        } else {
            TTA.Palette.ink.ignoresSafeArea()
        }
    }

    private func content(for detail: SavedStoryDetail) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RadialGradient(
                    colors: [Color(hex: 0x5a4a7a), Color(hex: 0x2c2340)],
                    center: UnitPoint(x: 0.5, y: 0.2),
                    startRadius: 10,
                    endRadius: 420
                )
                .ignoresSafeArea()

                sparkleDot().offset(x: 44, y: 90)
                sparkleDot(delay: 0.6).offset(x: geo.size.width - 58, y: 150)
                sparkleDot(delay: 1.1).offset(x: 66, y: max(0, geo.size.height - 210))

                VStack(spacing: 0) {
                    Text("You wrote a whole story!")
                        .font(TTA.Typography.story(17, italic: true))
                        .foregroundColor(Color(hex: 0xd9c9f0))

                    bookCover(for: detail)
                        .padding(.top, 20)

                    Text("The End.")
                        .font(TTA.Typography.display(38))
                        .foregroundColor(Color(hex: 0xffe9b8))
                        .padding(.top, 26)

                    if let epilogue = detail.epilogue {
                        Text(epilogue)
                            .font(TTA.Typography.body(16))
                            .foregroundColor(Color(hex: 0xe6dcf5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }

                    Button {
                        model.libraryStories = MockStories.librarySummaries
                        model.screen = .library
                    } label: {
                        Text("Read it now")
                    }
                    .buttonStyle(.ttaPrimary)
                    .padding(.top, 24)

                    Button {
                        model.goHome()
                    } label: {
                        Text("Back home")
                            .font(TTA.Typography.display(15))
                            .foregroundColor(Color(hex: 0xc9b8e4))
                            .underline()
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 32)
                .frame(width: geo.size.width, alignment: .top)
            }
        }
        .onAppear { sparkle = true }
    }

    private func bookCover(for detail: SavedStoryDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detail.title ?? "Untitled")
                .font(TTA.Typography.display(26))
                .foregroundColor(TTA.Palette.cream)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TTA.Palette.cream.opacity(0.16))
                .frame(height: 86)
                .overlay(
                    Text("cover art")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(hex: 0xffeacf))
                )

            Spacer(minLength: 12)

            Text("by \(childName) & Elsie · \(detail.pages.count) pages")
                .font(TTA.Typography.story(12.5))
                .foregroundColor(Color(hex: 0xffe9b8))
        }
        .padding(18)
        .frame(width: 206, height: 272)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 16, topTrailingRadius: 16)
                .fill(LinearGradient(colors: [TTA.Palette.scarf, TTA.Palette.scarfShadow], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(TTA.Palette.scarfShadow)
                .frame(width: 9)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private func sparkleDot(delay: Double = 0) -> some View {
        Circle()
            .fill(Color(hex: 0xffe9b8))
            .frame(width: 7, height: 7)
            .opacity(sparkle ? 0.9 : 0.3)
            .scaleEffect(sparkle ? 1.3 : 0.8)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(delay), value: sparkle)
    }
}
