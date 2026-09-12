import AVFoundation
import SwiftUI
import TinyTalkCore
import UIKit

/// Paginated storybook reader (design 1a's "Reading"). Reached via a
/// Library card tap or Settings' preview buttons.
///
/// The 🔊 replay button uses the system's built-in AVSpeechSynthesizer
/// voice, not the real Kokoro TTS pipeline (server/tinytalk/tts_kokoro.py)
/// -- SynthesizePage's live wire round trip needs the storybook-
/// persistence branch merged first. Using the device's own voice keeps
/// this a real, working feature today rather than a fake button that does
/// nothing, matching this project's "no fabricated toggles" convention --
/// swap the body of replayCurrentPage() for a SynthesizePage round trip
/// once that lands.
struct ReadingView: View {
    @ObservedObject var model: AppModel

    @State private var pageIndex = 0
    private let synthesizer = AVSpeechSynthesizer()

    // Tracks page-image keys ("storyId#pageIndex") already requested from
    // this ReadingView instance. AppModel.requestPageImage()'s own guard
    // only skips a key whose image has already ARRIVED -- it does nothing
    // to stop a second request for a key that's still in flight. TabView's
    // .page style can fire a page's onAppear more than once during a
    // swipe transition (appear/disappear/reappear as the user drags past
    // it), so without this, that could fire duplicate getPageImage() calls
    // for the same still-pending page. This is a purely local, per-view
    // dedupe -- it doesn't touch AppModel/SessionCoordinator's own
    // pending-request bookkeeping (see Task 9's known low-risk edge case
    // there), it just stops ReadingView itself from being the source of
    // duplicate in-flight requests.
    @State private var requestedImageKeys: Set<String> = []

    var body: some View {
        if let detail = model.selectedStory, !detail.pages.isEmpty {
            content(for: detail)
        } else {
            Color(hex: 0x2c2118).ignoresSafeArea()
        }
    }

    private func content(for detail: SavedStoryDetail) -> some View {
        ZStack {
            Color(hex: 0x2c2118).ignoresSafeArea()

            TabView(selection: $pageIndex) {
                ForEach(Array(detail.pages.enumerated()), id: \.offset) { index, page in
                    pageView(page, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                topBar(title: detail.title ?? "Untitled", pages: detail.pages)
                Spacer()
                bottomBar(pageCount: detail.pages.count)
            }
        }
        .onDisappear { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func pageView(_ page: StoryPage, index: Int) -> some View {
        VStack(spacing: 0) {
            pageArt(for: page, storyId: model.selectedStory?.id, index: index)
                .frame(height: 260)

            VStack(alignment: .leading, spacing: 10) {
                Text("PAGE \(index + 1)")
                    .font(TTA.Typography.display(14))
                    .tracking(2)
                    .foregroundColor(TTA.Palette.scarf)
                Text(page.text)
                    .font(TTA.Typography.story(22))
                    .foregroundColor(TTA.Palette.ink)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTA.Palette.paper)
        }
        .background(TTA.Palette.paper)
    }

    @ViewBuilder
    private func pageArt(for page: StoryPage, storyId: String?, index: Int) -> some View {
        if let storyId, page.hasImage,
           let data = model.pageImages["\(storyId)#\(index)"],
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle()
                .fill(TTA.Palette.paper)
                .overlay(
                    Text("page art")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TTA.Palette.inkSoft)
                        .padding(8)
                        .background(TTA.Palette.cream.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                )
                .onAppear {
                    guard let storyId, page.hasImage else { return }
                    let key = "\(storyId)#\(index)"
                    guard !requestedImageKeys.contains(key) else { return }
                    requestedImageKeys.insert(key)
                    model.requestPageImage(storyId: storyId, pageIndex: index)
                }
        }
    }

    private func topBar(title: String, pages: [StoryPage]) -> some View {
        HStack {
            Button {
                model.screen = .library
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(TTA.Palette.paper)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            Spacer()

            Text(title)
                .font(TTA.Typography.display(14))
                .foregroundColor(TTA.Palette.paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer()

            Button {
                guard pages.indices.contains(pageIndex) else { return }
                replayCurrentPage(text: pages[pageIndex].text)
            } label: {
                Text("🔊")
                    .font(.system(size: 15))
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 44)
    }

    private func bottomBar(pageCount: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? TTA.Palette.gold : TTA.Palette.paper.opacity(0.4))
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("swipe to turn the page")
                .font(TTA.Typography.story(12.5, italic: true))
                .foregroundColor(TTA.Palette.paper.opacity(0.7))
        }
        .padding(.bottom, 26)
    }

    private func replayCurrentPage(text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synthesizer.speak(utterance)
    }
}
