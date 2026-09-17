import SwiftUI
import TinyTalkCore

/// Grid of saved stories (design 1a's "Library"). Populated from the real
/// server via AppModel.refreshLibrary()/openStory() -- see AppModel.swift.
struct LibraryView: View {
    @ObservedObject var model: AppModel

    private let cardGradients: [[Color]] = [
        [TTA.Palette.scarf, TTA.Palette.scarfShadow],
        [TTA.Palette.teal, TTA.Palette.tealShadow],
        [Color(hex: 0x8a7bb8), Color(hex: 0x4a3f75)],
    ]

    var body: some View {
        ZStack {
            TTA.Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if !model.isConnected {
                    Spacer()
                    connectingState
                    Spacer()
                } else if model.libraryStories.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("No stories yet — make one with me first!")
                            .font(TTA.Typography.story(15, italic: true))
                            .foregroundColor(TTA.Palette.inkSoft)
                        newStoryTile
                            .frame(width: 160)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 22) {
                            ForEach(Array(model.libraryStories.enumerated()), id: \.element.id) { index, summary in
                                card(for: summary, colorIndex: index)
                            }
                            newStoryTile
                        }
                        .padding(20)
                    }
                }
            }
        }
        .onAppear {
            model.refreshLibrary()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.screen = .landing
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.ttaIcon)

            Text("Your Stories")
                .font(TTA.Typography.display(24))
                .foregroundColor(TTA.Palette.ink)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(TTA.Palette.paper)
    }

    private func card(for summary: SavedStorySummary, colorIndex: Int) -> some View {
        let colors = cardGradients[colorIndex % cardGradients.count]
        let isTappable = summary.rewriteStatus == .done

        return Button {
            guard isTappable else { return }
            model.openStory(summary)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 190)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(colors[1]).frame(width: 8)
                        }
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5, bottomTrailingRadius: 13, topTrailingRadius: 13))

                    if summary.rewriteStatus == .done {
                        Text(summary.title ?? "Untitled")
                            .font(TTA.Typography.display(19))
                            .foregroundColor(TTA.Palette.cream)
                            .padding(14)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)

                statusCaption(for: summary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }

    @ViewBuilder
    private func statusCaption(for summary: SavedStorySummary) -> some View {
        switch summary.rewriteStatus {
        case .done:
            Text("\(relativeDateLabel(from: summary.createdAt)) · \(summary.pageCount) pages")
                .font(TTA.Typography.story(13))
                .foregroundColor(TTA.Palette.inkSoft)
        case .pending:
            Text("Elsie is still writing this one…")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(TTA.Palette.inkSoft)
        case .failed:
            Text("Couldn't finish this storybook")
                .font(TTA.Typography.story(13, italic: true))
                .foregroundColor(TTA.Palette.alert)
        }
    }

    /// Shown while Library is reconnecting -- reachable whenever "Home"
    /// (AppModel.goHome()) disconnected the live session before landing
    /// here (see AppModel.refreshLibrary()'s doc comment). Without this,
    /// the grid below would either sit empty or -- worse -- show a stale
    /// list from before the disconnect whose cards silently did nothing
    /// when tapped, since openStory() requires a live coordinator.
    private var connectingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening your library…")
                .font(TTA.Typography.story(15, italic: true))
                .foregroundColor(TTA.Palette.inkSoft)
            if let error = model.lastErrorMessage {
                // Same styling as StoryView's errorBanner -- one error
                // should look the same wherever it surfaces.
                Text(error)
                    .font(TTA.Typography.body(13, weight: .semibold))
                    .foregroundColor(TTA.Palette.cream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(TTA.Palette.alert)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { model.lastErrorMessage = nil }
                    .padding(.horizontal, 24)
            }
        }
    }

    private var newStoryTile: some View {
        Button {
            Task { await model.startStory() }
        } label: {
            VStack(spacing: 8) {
                Text("+")
                    .font(TTA.Typography.display(26))
                    .foregroundColor(TTA.Palette.cream)
                    .frame(width: 52, height: 52)
                    .background(TTA.Palette.scarf)
                    .clipShape(Circle())
                Text("New story")
                    .font(TTA.Typography.display(14))
                    .foregroundColor(TTA.Palette.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(TTA.Palette.wood.opacity(0.42), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            )
        }
        .buttonStyle(.plain)
    }
}
