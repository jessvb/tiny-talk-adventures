import SwiftUI
import TinyTalkCore

/// Shown right after a story naturally concludes (design 1a's "The End"),
/// auto-navigated to by AppModel once a concluding turn's audio finishes
/// playing and the server's rewriting_started/story_detail signals arrive
/// (see AppModel's readyToShowTheEnd handling). Also still reachable via
/// Settings' preview buttons against mock data.
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
                        // AppModel already keeps model.selectedStory live for
                        // this exact story for as long as The End screen is
                        // showing (see AppModel's getStory()/story_detail
                        // handling, which re-fetches once the rewrite
                        // finishes) -- ReadingView reads that same property
                        // directly, so no separate fetch or mock data is
                        // needed here.
                        model.screen = .reading
                    } label: {
                        HStack(spacing: 10) {
                            if detail.rewriteStatus == .pending {
                                ProgressView()
                                    .tint(TTA.Palette.cream)
                            }
                            Text("Read it now")
                        }
                    }
                    // ChunkyButtonStyle never reads isEnabled -- it only
                    // reacts to isPressed -- so .disabled() alone would
                    // make this untappable without looking any different.
                    // A parent found the previous plain .opacity() dim on
                    // the vivid scarf-red fill too subtle to read as
                    // "disabled" at a glance -- swapping to an actual
                    // muted fill/edge pair (still from the warm palette,
                    // not an off-brand cold grey) plus the spinner above
                    // reads unambiguously as "in progress" instead.
                    .buttonStyle(
                        detail.rewriteStatus == .done
                            ? ChunkyButtonStyle(fill: TTA.Palette.scarf, edge: TTA.Palette.scarfShadow)
                            : ChunkyButtonStyle(fill: TTA.Palette.inkSoft, edge: TTA.Palette.ink)
                    )
                    .disabled(detail.rewriteStatus != .done)
                    .padding(.top, 24)

                    // Same copy as LibraryView's statusCaption -- one
                    // story's status should read identically wherever it
                    // shows up.
                    rewriteStatusCaption(for: detail)

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
                // Centered, not top-anchored -- matches the design canvas's
                // own `justify-content:center` for this screen. Confirmed
                // on-device: without an explicit height here, the VStack
                // sizes to its own content and sits at the top of the
                // GeometryReader's frame, leaving a large dead gap below
                // "Back home" instead of balancing the empty space above
                // and below the card the way the design intends.
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear { sparkle = true }
    }

    private func bookCover(for detail: SavedStoryDetail) -> some View {
        // A nil title means the rewrite hasn't produced one yet (.pending)
        // or never will (.failed) -- see SavedStoryDetail. The stand-in is
        // set smaller and softer than a real title so it reads as "not
        // yet", not as the book's actual name.
        let title = detail.title

        return VStack(alignment: .leading, spacing: 0) {
            Text(title ?? placeholderTitle(for: detail.rewriteStatus))
                .font(TTA.Typography.display(title == nil ? 22 : 26))
                .foregroundColor(TTA.Palette.cream.opacity(title == nil ? 0.75 : 1))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            coverArtPlaceholder(for: detail.rewriteStatus)

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

    /// Cover-title stand-in while detail.title is nil. .pending promises a
    /// title because one really is on its way; .failed must not, so it (and
    /// the never-in-practice .done-with-no-title case -- storybook.py's
    /// _parse_rewrite() rejects an empty title) falls back to a plain,
    /// warm "Your Story" instead.
    private func placeholderTitle(for status: RewriteStatus) -> String {
        switch status {
        case .pending: return "Title Coming Soon"
        case .failed, .done: return "Your Story"
        }
    }

    /// Stand-in for cover art. There is no cover-art pipeline (only per-page
    /// illustrations, see ReadingView), so this is a soft, blurred wash of
    /// palette colors rather than a labeled debug box. Only .pending claims
    /// anything is being painted: the rewrite window (and so this screen's
    /// .pending state) also covers the page-illustration pass, see
    /// illustrations.py. .failed dims the wash; .done leaves it wordless
    /// rather than promising a cover that isn't coming.
    private func coverArtPlaceholder(for status: RewriteStatus) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(TTA.Palette.cream.opacity(0.16))
            .frame(height: 86)
            .overlay(
                ZStack {
                    Circle().fill(TTA.Palette.gold).frame(width: 64, height: 64).offset(x: -48, y: -12)
                    Circle().fill(TTA.Palette.teal).frame(width: 58, height: 58).offset(x: 44, y: 14)
                    Circle().fill(TTA.Palette.cream).frame(width: 46, height: 46).offset(x: 0, y: 26)
                }
                .blur(radius: 12)
                .opacity(status == .failed ? 0.2 : 0.55)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if status == .pending {
                    VStack(spacing: 5) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 20))
                        Text("Elsie's painting the pictures…")
                            .font(TTA.Typography.story(12.5, italic: true))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(Color(hex: 0xffeacf))
                    // Keeps the cream text legible where it crosses the wash's
                    // lightest blob.
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(.horizontal, 10)
                }
            }
    }

    /// Same copy LibraryView's statusCaption already uses for
    /// .pending/.failed -- deliberately identical wording wherever a
    /// story's rewrite status shows up. .done renders nothing here (the
    /// epilogue above already covers that case).
    @ViewBuilder
    private func rewriteStatusCaption(for detail: SavedStoryDetail) -> some View {
        switch detail.rewriteStatus {
        case .done:
            EmptyView()
        case .pending:
            Text("Elsie is still writing this one…")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(Color(hex: 0xe6dcf5))
                .padding(.top, 6)
        case .failed:
            Text("Couldn't finish this storybook")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(TTA.Palette.alert)
                .padding(.top, 6)
        }
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
