import SwiftUI

/// A cropped/zoomed view into the real "Elsie" photo asset
/// (Assets.xcassets/Elsie.imageset, sourced from the Claude Design project
/// -- see docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md's
/// "Asset gap" note), approximating CSS's
/// `background-size:<zoom>% background-position:<anchorX> <anchorY>`: the
/// source image is scaled to cover the container at `zoom`x, then panned so
/// the point at (anchorX, anchorY) fraction of the SOURCE lands at the
/// container's center. `zoom: 1` behaves like plain `cover`.
struct ElsieImage: View {
    var zoom: CGFloat
    var anchorX: CGFloat = 0.5
    var anchorY: CGFloat = 0.5

    /// The source photo's native width/height (1408x768).
    private static let sourceAspect: CGFloat = 1408.0 / 768.0

    /// Plain (non-ViewBuilder) helper -- a bare `if/else` inside a
    /// `GeometryReader` closure gets parsed as View-producing control flow
    /// by the ViewBuilder, so this branch (assigning to plain CGFloats, not
    /// building a View) has to live outside that closure.
    private static func renderedSize(fitting containerSize: CGSize, zoom: CGFloat) -> CGSize {
        let containerAspect = containerSize.width / containerSize.height
        if containerAspect > sourceAspect {
            let width = containerSize.width * zoom
            return CGSize(width: width, height: width / sourceAspect)
        } else {
            let height = containerSize.height * zoom
            return CGSize(width: height * sourceAspect, height: height)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = Self.renderedSize(fitting: proxy.size, zoom: zoom)
            Image("Elsie")
                .resizable()
                .frame(width: size.width, height: size.height)
                .position(
                    x: proxy.size.width / 2 - size.width * (anchorX - 0.5),
                    y: proxy.size.height / 2 - size.height * (anchorY - 0.5)
                )
        }
        .clipped()
    }
}
