import SwiftUI
import TinyTalkCore

/// Grown-up settings screen (design 1a). The design's "Story length" /
/// "Elsie's voice speed" / "Real animal facts" / "Camera inspiration" rows
/// are omitted here -- none are backed by any client-controllable setting
/// today (those are server env vars, not wire-protocol-exposed), and this
/// project's own conventions call for no fabricated toggles that don't do
/// anything. "Under the hood" instead surfaces real debug data that already
/// existed in the bare-bones harness (state/turn id/latency/debug log).
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Reached only via a long-press on "UNDER THE HOOD" below, not a
    /// visible button -- this is a developer tool for reproducing bugs
    /// (e.g. the backgrounding/foregrounding ditty-resume issue) by
    /// watching the coordinator's debugLog live, not something a curious
    /// child tapping around Settings should stumble into.
    @State private var showDebugLogSheet = false
    /// Revealed by the same long-press as showDebugLogSheet -- see that
    /// property's doc comment. Not persisted: resets to hidden each time
    /// Settings is reopened, same as the debug sheet requires
    /// re-discovering the gesture.
    @State private var showAwayFromHomeCard = false
    @State private var groqApiKey: String = KeychainStore.get("groqApiKey") ?? ""
    @State private var animalFactsApiKey: String = KeychainStore.get("animalFactsApiKey") ?? ""

    var body: some View {
        ZStack {
            TTA.Palette.outerPaper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        serverCard
                        underTheHoodCard
                        awayFromHomeCard
                        storybookPreviewCard
                        replayButton
                    }
                    .padding(20)
                }
            }
        }
        .sheet(isPresented: $showDebugLogSheet) {
            DebugLogSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.screen = model.isConnected ? .creating : .landing
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.ttaIcon)

            Text("Grown-up settings")
                .font(TTA.Typography.display(22))
                .foregroundColor(TTA.Palette.ink)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(TTA.Palette.paper)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ELSIE'S BRAIN LIVES ON")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            HStack(spacing: 10) {
                TextField("ws://<mac-ip>:8765", text: $model.serverAddress)
                    .font(.system(.body, design: .monospaced))
                    .disabled(model.isConnected)
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(TTA.Palette.wood.opacity(0.25)))

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isConnected ? TTA.Palette.teal : TTA.Palette.inkSoft.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(model.isConnected ? "Connected" : "Not connected")
                        .font(TTA.Typography.body(12, weight: .heavy))
                        .foregroundColor(model.isConnected ? TTA.Palette.teal : TTA.Palette.inkSoft)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(TTA.Palette.tealSurface)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            Text(
                model.awayFromHomeEnabled
                    ? "Away from home: Elsie's brain is in Groq's cloud right now, not your Mac."
                    : "Your Mac on the home WiFi. Speech, story and voice all run there — nothing is sent to the internet."
            )
                .font(TTA.Typography.body(13.5))
                .foregroundColor(TTA.Palette.inkSoft)

            if model.isConnected {
                Button {
                    model.disconnectUserInitiated()
                    model.screen = .landing
                } label: {
                    Text("Disconnect")
                        .font(TTA.Typography.display(14))
                        .foregroundColor(TTA.Palette.alert)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var underTheHoodCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UNDER THE HOOD")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)
                // Secret menu: hold for a second to see the full debugLog,
                // not just its count. No visual affordance on purpose.
                .onLongPressGesture(minimumDuration: 1.0) {
                    showDebugLogSheet = true
                    showAwayFromHomeCard = true
                }

            VStack(alignment: .leading, spacing: 6) {
                infoRow("state", "\(model.state)")
                infoRow("turn id", "\(model.currentTurnId)")
                if let latest = model.latencyHistory.last {
                    infoRow("last VAD→stopped", String(format: "%.1fms", latest.vadFireToPlaybackStoppedMillis))
                }
                infoRow("debug log entries", "\(model.debugLog.count)")
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundColor(TTA.Palette.inkSoft)
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var awayFromHomeCard: some View {
        if showAwayFromHomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AWAY FROM HOME")
                    .font(TTA.Typography.display(12))
                    .tracking(1.5)
                    .foregroundColor(TTA.Palette.inkSoft)

                Text("For demos only, away from the home WiFi: speech and story go through Groq's cloud AI instead of your Mac. Needs a free Groq API key.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)

                SecureField("Groq API key", text: $groqApiKey)
                    .font(.system(.body, design: .monospaced))
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .onChange(of: groqApiKey) { newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete("groqApiKey")
                        } else {
                            KeychainStore.set(newValue, forKey: "groqApiKey")
                        }
                    }

                SecureField("API Ninjas key (optional -- animal facts)", text: $animalFactsApiKey)
                    .font(.system(.body, design: .monospaced))
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .onChange(of: animalFactsApiKey) { newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete("animalFactsApiKey")
                        } else {
                            KeychainStore.set(newValue, forKey: "animalFactsApiKey")
                        }
                    }

                Toggle(
                    "Away-from-home mode",
                    isOn: Binding(
                        get: { model.awayFromHomeEnabled },
                        set: { model.setAwayFromHomeEnabled($0) }
                    )
                )
                .disabled(groqApiKey.isEmpty)
                .tint(TTA.Palette.wood)

                if model.awayFromHomeEnabled {
                    Text("On: Elsie's brain runs in Groq's cloud right now, not your Mac.")
                        .font(TTA.Typography.body(11.5))
                        .foregroundColor(TTA.Palette.alert)
                }
            }
            .padding(16)
            .background(TTA.Palette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// Developer preview of the Library/Reading/The End screens against
    /// mock data -- see MockStories.swift and TheEndView.swift's doc
    /// comments for why these aren't wired into the real Landing/Story
    /// "Read Stories" buttons yet.
    private var storybookPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMING SOON: STORYBOOKS")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            Text("Preview only — these screens use example stories, not real ones yet.")
                .font(TTA.Typography.body(12.5))
                .foregroundColor(TTA.Palette.inkSoft)

            previewButton("Preview: The End") {
                model.selectedStory = MockStories.pip
                model.screen = .theEnd
            }
            previewButton("Preview: Library") {
                model.libraryStories = MockStories.librarySummaries
                model.screen = .library
            }
            previewButton("Preview: Reading") {
                model.selectedStory = MockStories.pip
                model.screen = .reading
            }
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func previewButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TTA.Typography.display(14))
                .foregroundColor(TTA.Palette.wood)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(TTA.Palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }

    private var replayButton: some View {
        Button {
            model.screen = .onboarding
        } label: {
            Text("Replay the welcome")
                .font(TTA.Typography.display(15))
                .foregroundColor(TTA.Palette.wood)
                .frame(maxWidth: .infinity)
                .padding(13)
                .background(TTA.Palette.cream)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(TTA.Palette.wood.opacity(0.3), lineWidth: 1.5))
        }
    }
}

/// Full contents of SessionCoordinator.debugLog, live -- @ObservedObject
/// (not a snapshot array) so this keeps updating while open, which is the
/// whole point: background the app, foreground it, and watch entries
/// appear here in real time without having to reopen the sheet.
struct DebugLogSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if model.debugLog.isEmpty {
                        Text("No debug log entries yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(model.debugLog.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Debug log (\(model.debugLog.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
