import SwiftUI
import TinyTalkCore

/// Elsie's on-screen presence: a circular avatar with a listening-ring
/// animation reflecting the REAL session state (idle/listening/
/// waitingForReply/speaking) and mute flag -- not the design mock's own
/// fake demo state.
///
/// Placeholder art, deliberately: the real illustrated character photo
/// (assets/elsie-library.jpeg in the Claude Design project) is larger than
/// the design-sync API's 256KiB read cap and came back truncated when
/// fetched during this pass. Swap the book icon below for an Image once
/// the real asset is sourced at full resolution (e.g. exported by hand from
/// the design project and dragged into an Assets.xcassets catalog).
struct ElsieAvatar: View {
    var state: SessionState
    var isMuted: Bool
    var diameter: CGFloat = 74

    @State private var shimmer = false

    private var ringColor: Color {
        if isMuted { return TTA.Palette.alert.opacity(0.35) }
        switch state {
        case .listening: return TTA.Palette.teal.opacity(0.55)
        case .speaking: return TTA.Palette.scarf.opacity(0.5)
        case .waitingForReply: return TTA.Palette.gold.opacity(0.4)
        case .idle: return TTA.Palette.wood.opacity(0.18)
        }
    }

    private var isAnimating: Bool { !isMuted && state != .idle }

    var body: some View {
        ZStack {
            Circle()
                .fill(ringColor)
                .frame(width: diameter, height: diameter)
                .scaleEffect(shimmer ? 1.16 : 1)
                .opacity(shimmer ? 0 : 0.55)
                .animation(
                    isAnimating ? .easeOut(duration: 2.1).repeatForever(autoreverses: false) : .easeOut(duration: 0.2),
                    value: shimmer
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [TTA.Palette.gold.opacity(0.9), TTA.Palette.scarf],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: diameter * 0.8
                    )
                )
                .frame(width: diameter - 12, height: diameter - 12)
                .overlay(
                    Image(systemName: "book.fill")
                        .font(.system(size: (diameter - 12) * 0.38, weight: .semibold))
                        .foregroundColor(TTA.Palette.cream)
                )
                .overlay(Circle().strokeBorder(TTA.Palette.cream, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .saturation(isMuted ? 0 : 1)
                .brightness(isMuted ? -0.08 : 0)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { shimmer = isAnimating }
        .onChange(of: isAnimating) { animating in shimmer = animating }
    }
}
