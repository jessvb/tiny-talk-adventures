import SwiftUI

/// Home screen (design 1a). "Read Stories" is a real button once
/// model.libraryStories is non-empty (see AppModel.connect()'s
/// listStories() trigger, and peekLibrary() below for the cold-launch
/// case where no connection exists yet) -- otherwise shows the same
/// disabled-look empty state as before.
struct LandingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            ElsieImage(zoom: 1.1, anchorX: 0.46, anchorY: 0.4)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    TTA.Palette.woodDark.opacity(0.1),
                    TTA.Palette.woodDark.opacity(0.32),
                    TTA.Palette.woodDark.opacity(0.88),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        model.screen = .settings
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.ttaIcon)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                signPlaque
                    .padding(.top, 24)

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        Task { await model.startStory(.homeCreateStory) }
                    } label: {
                        Label("Create a Story", systemImage: "pencil")
                    }
                    .buttonStyle(.ttaPrimary)

                    if model.libraryStories.isEmpty {
                        VStack(spacing: 9) {
                            Label("Read Stories", systemImage: "book.closed.fill")
                                .font(TTA.Typography.display(22))
                                .foregroundColor(TTA.Palette.cream.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(TTA.Palette.cream.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                            Text("No stories yet — make one with me first!")
                                .font(TTA.Typography.story(13.5, italic: true))
                                .foregroundColor(TTA.Palette.paper)
                        }
                    } else {
                        Button {
                            model.libraryReturnScreen = .landing
                            model.screen = .library
                        } label: {
                            Label("Read Stories", systemImage: "book.closed.fill")
                                .font(TTA.Typography.display(22))
                                .foregroundColor(TTA.Palette.cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(TTA.Palette.cream.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            model.peekLibrary()
        }
    }

    private var signPlaque: some View {
        VStack(spacing: 2) {
            Text("TINY TALK")
                .font(TTA.Typography.display(14))
                .tracking(3)
                .foregroundColor(TTA.Palette.gold)
            Text("Adventures")
                .font(TTA.Typography.display(32))
                .foregroundColor(TTA.Palette.cream)
            Text("stories you say out loud")
                .font(TTA.Typography.story(12, italic: true))
                .foregroundColor(TTA.Palette.gold)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [TTA.Palette.wood, TTA.Palette.woodDark], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(TTA.Palette.woodDark, lineWidth: 1))
        .rotationEffect(.degrees(-1.4))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}
