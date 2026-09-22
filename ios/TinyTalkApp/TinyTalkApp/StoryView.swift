import SwiftUI
import TinyTalkCore

/// The live conversation screen (design 1a's "Story Creation"). The design
/// also shows a 5-stage arc progress indicator ("the big moment") in the
/// header -- omitted here, deliberately: server/tinytalk/protocol.py has no
/// wire message carrying story_arc.py's current Stage, so there is no real
/// data to drive it. Revisit once that protocol gap is closed.
struct StoryView: View {
    @ObservedObject var model: AppModel

    @State private var menuOpen = false
    @State private var showingCamera = false
    @State private var bounce = false

    var body: some View {
        ZStack {
            // Explicit full-bleed background behind everything -- without
            // this, an empty ScrollView (model.turns == [], no error/hint/
            // thinking row) was observed on real hardware to collapse to a
            // thin centered column instead of claiming the full screen
            // width, leaving the raw black window background showing on
            // both sides until the first message arrived.
            TTA.Palette.outerPaper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                conversation
                // Always visible regardless of scroll position or whether
                // the conversation has any content yet -- previously lived
                // inside the scrollable content, where it was easy to miss
                // (or, before the empty-ScrollView fix above, could be
                // hidden behind the collapsed/black conversation area
                // entirely). This is the only feedback the child/parent
                // gets when the camera button's permission check fails.
                if let hint = model.objectRecognitionHint {
                    Text(hint)
                        .font(TTA.Typography.body(13))
                        .foregroundColor(TTA.Palette.inkSoft)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .background(TTA.Palette.paper)
                }
                bottomBar
            }

            if menuOpen {
                menuOverlay
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker(
                onImagePicked: { image in
                    showingCamera = false
                    Task { await model.handlePhotoTaken(image) }
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
        .animation(.easeOut(duration: 0.22), value: menuOpen)
    }

    // MARK: - Header

    // While the storybook rewrite (text + page art) is in progress, the
    // server ignores all speech/finish-story input until it's done -- see
    // session.py's REWRITING gate. Previously this was a few seconds of
    // text-only rewrite and went unnoticed; page art extended it to
    // multiple minutes (measured on-device: ~3.5min), during which
    // model.state settles back to .idle with nothing to show for it,
    // leaving this screen looking frozen. Reusing "waitingForReply"'s
    // existing shimmer/label here needs no new visual language -- it
    // already means "something is happening, please wait."
    private var effectiveAvatarState: SessionState {
        model.isRewriting ? .waitingForReply : model.state
    }

    private var stateLabel: String {
        if model.isRewriting { return "Elsie is finishing your storybook…" }
        if model.isMicMuted { return "Mic is off" }
        switch model.state {
        case .idle: return "Ready when you are"
        case .listening: return "Elsie is listening"
        case .waitingForReply: return "Elsie is thinking…"
        case .speaking: return "Elsie is talking"
        }
    }

    private var header: some View {
        HStack {
            Button { menuOpen = true } label: {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(.ttaIcon)

            Spacer()

            VStack(spacing: 2) {
                Text("Tiny Talk Adventures")
                    .font(TTA.Typography.display(15))
                    .foregroundColor(TTA.Palette.ink)
                Text(stateLabel)
                    .font(TTA.Typography.body(11.5, weight: .semibold))
                    .foregroundColor(TTA.Palette.inkSoft)
            }

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(TTA.Palette.paper)
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            // Pinned above the scrolling history rather than first inside it:
            // the history now survives a disconnect (issue #23), so a banner
            // at the top of the scroll content would sit far above the
            // bottom-anchored bubbles -- out of view exactly when the
            // "disconnected from server" cue matters most.
            if let error = model.lastErrorMessage {
                errorBanner(error)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            } else if model.isRewriting {
                // issue #32 follow-up: the header's stateLabel already said
                // this, but on-device testing found it too easy to miss (a
                // one-line label in an 11.5pt subtitle) -- a child landing
                // here via "New Story" needs it to be obvious at a glance
                // that talking won't do anything right now, not just
                // technically true somewhere on screen.
                rewritingBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.turns) { turn in
                            bubble(for: turn).id(turn.id)
                        }
                        if model.state == .waitingForReply {
                            thinkingRow.id("thinking")
                        }
                    }
                    .padding(16)
                    // Without an explicit width, an otherwise-empty VStack (no
                    // turns yet, not thinking) has near-zero natural
                    // size -- confirmed on real hardware to leave the ScrollView
                    // collapsed to a thin centered column with the raw window
                    // background showing on both sides, instead of claiming the
                    // full width offered by its parent.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TTA.Palette.outerPaper)
                .onChange(of: model.turns.count) { _ in
                    withAnimation { proxy.scrollTo(model.turns.last?.id, anchor: .bottom) }
                }
                .onChange(of: model.state) { newState in
                    if newState == .waitingForReply {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(TTA.Typography.body(13, weight: .semibold))
            .foregroundColor(TTA.Palette.cream)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(TTA.Palette.alert)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { model.lastErrorMessage = nil }
    }

    /// Friendly (not alarming) sibling of errorBanner() -- tealSurface/teal
    /// is the same "informational" pairing SettingsView already uses,
    /// rather than introducing a new color for this one case.
    private var rewritingBanner: some View {
        Text("✨ Elsie is putting the finishing touches on your last story! She'll be ready to start a new one again soon.")
            .font(TTA.Typography.body(13, weight: .semibold))
            .foregroundColor(TTA.Palette.teal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(TTA.Palette.tealSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bubble(for turn: StoryTurn) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            if turn.speaker == .elsie {
                ElsieAvatar(state: .idle, isMuted: false, diameter: 38)
            } else {
                Spacer(minLength: 38)
            }

            Text(turn.text)
                .font(TTA.Typography.story(16.5))
                .foregroundColor(turn.speaker == .elsie ? TTA.Palette.ink : TTA.Palette.cream)
                .padding(12)
                .background(turn.speaker == .elsie ? TTA.Palette.cream : TTA.Palette.teal)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: turn.speaker == .elsie ? 6 : 20,
                        bottomTrailingRadius: turn.speaker == .elsie ? 20 : 6,
                        topTrailingRadius: 20
                    )
                )

            if turn.speaker == .elsie {
                Spacer(minLength: 38)
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.speaker == .elsie ? .leading : .trailing)
    }

    private var thinkingRow: some View {
        HStack(alignment: .bottom, spacing: 9) {
            ElsieAvatar(state: .waitingForReply, isMuted: false, diameter: 38)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(TTA.Palette.scarf)
                        .frame(width: 8, height: 8)
                        .offset(y: bounce ? -5 : 0)
                        .animation(
                            .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                            value: bounce
                        )
                }
                Text("Elsie is thinking…")
                    .font(TTA.Typography.story(13.5, italic: true))
                    .foregroundColor(TTA.Palette.inkSoft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(TTA.Palette.cream)
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20)
            )
            Spacer(minLength: 38)
        }
        .onAppear { bounce = true }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                Task {
                    guard await model.requestCameraAccess() else { return }
                    showingCamera = true
                }
            } label: {
                Image(systemName: "camera.fill")
            }
            .buttonStyle(BottomIconButtonStyle(fill: TTA.Palette.teal, edge: TTA.Palette.tealShadow))

            VStack(spacing: 5) {
                ElsieAvatar(state: effectiveAvatarState, isMuted: model.isMicMuted, diameter: 68)
                Text(stateLabel)
                    .font(TTA.Typography.display(12))
                    .foregroundColor(model.isMicMuted ? TTA.Palette.alert : TTA.Palette.teal)
            }
            .frame(maxWidth: .infinity)

            Button {
                model.toggleMute()
            } label: {
                Image(systemName: model.isMicMuted ? "mic.slash.fill" : "mic.fill")
            }
            .buttonStyle(
                BottomIconButtonStyle(
                    fill: model.isMicMuted ? TTA.Palette.alert : TTA.Palette.paper,
                    edge: model.isMicMuted ? TTA.Palette.alertShadow : TTA.Palette.wood.opacity(0.35),
                    foreground: model.isMicMuted ? TTA.Palette.cream : TTA.Palette.wood
                )
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(TTA.Palette.paper)
    }

    // MARK: - Menu

    private var menuOverlay: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { menuOpen = false }

            VStack(alignment: .leading, spacing: 10) {
                Text("ELSIE'S DESK")
                    .font(TTA.Typography.display(12))
                    .tracking(2)
                    .foregroundColor(TTA.Palette.inkSoft)
                    .padding(.top, 54)

                // Both gated on isRewriting for the same reason: the server
                // silently ignores new_story/conclude_story while its own
                // REWRITING gate is up (session.py), and issue #32 found
                // that letting the tap through anyway -- rather than
                // showing why it can't work -- reproduces the silent hang
                // one step later.
                menuRow(
                    "New Story", systemImage: "pencil",
                    disabled: model.isRewriting, disabledSubtitle: "Elsie's still busy!"
                ) {
                    menuOpen = false
                    Task { await model.startNewStory() }
                }
                menuRow(
                    "Finish this story", systemImage: "book.closed.fill",
                    disabled: model.isRewriting, disabledSubtitle: "Elsie's still busy!"
                ) {
                    menuOpen = false
                    Task { await model.finishStory() }
                }
                menuRow("Home", systemImage: "house.fill") {
                    menuOpen = false
                    model.goHome()
                }
                // Unlike "Home", deliberately does NOT disconnect -- mirrors
                // "Settings" below, which already leaves the live session
                // running in the background (see SettingsView's own back
                // button, which returns to .creating when isConnected).
                // libraryReturnScreen must be set here, not left at its
                // .landing default, or Library's back button would strand
                // the child on Landing instead of resuming their story.
                menuRow("Library", systemImage: "books.vertical.fill") {
                    menuOpen = false
                    model.libraryReturnScreen = .creating
                    model.screen = .library
                }
                menuRow("Settings", systemImage: "gearshape.fill") {
                    menuOpen = false
                    model.screen = .settings
                }

                Spacer()

                Text(
                    !model.isConnected
                        ? "not connected"
                        : model.awayFromHomeEnabled
                            ? "connected · Groq cloud (away from home)"
                            : "connected · \(model.serverAddress)"
                )
                    .font(TTA.Typography.body(10, weight: .medium))
                    .foregroundColor(TTA.Palette.inkSoft.opacity(0.7))
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(TTA.Palette.paper)
            .transition(.move(edge: .leading))
        }
    }

    private func menuRow(
        _ title: String, systemImage: String,
        disabled: Bool = false, disabledSubtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(TTA.Typography.display(17))
                if disabled, let disabledSubtitle {
                    Text(disabledSubtitle)
                        .font(TTA.Typography.body(12))
                        .padding(.leading, 30) // roughly under the label's text, past its icon
                }
            }
            .foregroundColor(TTA.Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(TTA.Palette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(TTA.Palette.wood.opacity(0.25)))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1.0)
    }
}

/// A 56pt square chunky icon button -- the bottom bar's camera/mute
/// buttons, distinct from the header's smaller IconButtonStyle.
private struct BottomIconButtonStyle: ButtonStyle {
    var fill: Color
    var edge: Color
    var foreground: Color = TTA.Palette.cream

    func makeBody(configuration: Configuration) -> some View {
        let edgeHeight: CGFloat = 4
        configuration.label
            .font(.system(size: 22))
            .foregroundColor(foreground)
            .frame(width: 56, height: 56)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(edge).offset(y: edgeHeight)
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill)
                }
            )
            .offset(y: configuration.isPressed ? edgeHeight : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
