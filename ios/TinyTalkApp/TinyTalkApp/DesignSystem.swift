import SwiftUI

/// Visual language for the kid-facing UI (design 1a, "Storybook-literal" --
/// see docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md), imported
/// from the Tiny Talk Adventures Claude Design project. Values below are
/// lifted directly from that project's own "Design system, direction A"
/// notes, not invented here.
///
/// Font substitution, deliberate: the design specifies Baloo 2 (chunky
/// rounded, for anything tappable) and Lora (serif, for anything read).
/// Neither is bundled yet -- sourcing and licensing real font files is
/// left for a follow-up pass, not done here to avoid guessing at font-host
/// URLs. San Francisco's built-in `.rounded`/`.serif` designs stand in for
/// now: both are free, already in the app, and land close to the same
/// intent (rounded/chunky for UI, serif for reading).
enum TTA {
    enum Palette {
        static let outerPaper = Color(hex: 0xefe7dc)
        static let paper = Color(hex: 0xf6ecd8)
        static let cream = Color(hex: 0xfff8ec)
        static let ink = Color(hex: 0x3a2a1c)
        static let inkSoft = Color(hex: 0x6b5442)
        static let wood = Color(hex: 0x8b5e34)
        static let woodDark = Color(hex: 0x6b4526)
        static let scarf = Color(hex: 0xc9612e)
        static let scarfShadow = Color(hex: 0x8f3f18)
        static let teal = Color(hex: 0x2f7f78)
        static let tealShadow = Color(hex: 0x1d5f59)
        static let tealSurface = Color(hex: 0xe7f2f0)
        static let gold = Color(hex: 0xd9a327)
        static let alert = Color(hex: 0x96382c)
        static let alertShadow = Color(hex: 0x7d2c22)
    }

    enum Typography {
        /// Anything a child taps: chunky, rounded, high x-height.
        static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        /// Anything a child reads: story text, page copy.
        static func story(_ size: CGFloat, italic: Bool = false) -> Font {
            let base = Font.system(size: size, weight: .regular, design: .serif)
            return italic ? base.italic() : base
        }

        /// Everything else -- captions, settings rows, debug info.
        static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A big, physical-feeling button: solid fill, a bottom "edge" that reads
/// as a real thing to press, and a press-down animation. Matches the
/// design's own note: "every chunky button carries a 5-6px bottom edge so
/// it reads as a physical thing to press." Never below 56pt tall in
/// practice (see callers) -- the design's own minimum tap-target rule for
/// a young child.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color
    var edge: Color
    var foreground: Color = TTA.Palette.cream
    var fontSize: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        let edgeHeight: CGFloat = 5
        return configuration.label
            .font(TTA.Typography.display(fontSize))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(edge)
                        .offset(y: edgeHeight)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(fill)
                }
            )
            .offset(y: configuration.isPressed ? edgeHeight : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ChunkyButtonStyle {
    static var ttaPrimary: ChunkyButtonStyle {
        ChunkyButtonStyle(fill: TTA.Palette.scarf, edge: TTA.Palette.scarfShadow)
    }

    static var ttaSecondary: ChunkyButtonStyle {
        ChunkyButtonStyle(fill: TTA.Palette.teal, edge: TTA.Palette.tealShadow)
    }
}

/// A small square icon button -- the back chevron, hamburger menu, settings
/// gear. Semi-opaque cream on paper, with a soft wood-toned border.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var background: Color = TTA.Palette.cream
    var foreground: Color = TTA.Palette.wood

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(foreground)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .strokeBorder(TTA.Palette.wood.opacity(0.32), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var ttaIcon: IconButtonStyle { IconButtonStyle() }
}
