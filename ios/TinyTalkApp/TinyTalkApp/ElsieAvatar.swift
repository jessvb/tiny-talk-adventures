import SwiftUI
import TinyTalkCore

/// Elsie's on-screen presence: a circular avatar with a listening-ring
/// animation reflecting the REAL session state (idle/listening/
/// waitingForReply/speaking) and mute flag -- not the design mock's own
/// fake demo state.
///
/// Uses the real character photo (Assets.xcassets/Elsie.imageset, provided
/// directly by the user after the design-sync API's 256KiB cap truncated
/// the same asset -- see ElsieImage.swift), tightly cropped to her face via
/// ElsieImage, approximating the design's own 340%-zoom avatar crop.
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

            ElsieImage(zoom: 2.1, anchorY: 0.44)
                .frame(width: diameter - 12, height: diameter - 12)
                .clipShape(Circle())
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
