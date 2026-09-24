import AVFoundation
import SwiftUI
import TinyTalkCore
import TinyTalkPlatform

/// Grown-up settings screen (design 1a). The design's "Elsie's voice speed" /
/// "Real animal facts" / "Camera inspiration" rows are omitted here -- none
/// are backed by any client-controllable setting today (those are server env
/// vars, not wire-protocol-exposed), and this project's own conventions call
/// for no fabricated toggles that don't do anything. "Under the hood" instead
/// surfaces real debug data that already existed in the bare-bones harness
/// (state/turn id/latency/debug log).
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
    @State private var cloudflareAccountId: String = KeychainStore.get("cloudflareAccountId") ?? ""
    @State private var cloudflareApiToken: String = KeychainStore.get("cloudflareApiToken") ?? ""
    /// Voice picker opens as its own sheet (same pattern as
    /// showDebugLogSheet below), not an inline Picker(.pickerStyle(.menu))
    /// -- confirmed on-device (2026-09-14) that .menu's UIMenu rendering
    /// glitches and stops scrolling past roughly its first ~13 items.
    /// AVSpeechTts.availableEnglishVoices() commonly returns 30-50+
    /// entries (every English region x quality tier is a separate
    /// speechVoices() entry) -- well past what UIMenu handles reliably;
    /// a List-based sheet has no such limit.
    @State private var showVoicePickerSheet = false
    /// Issue #56 item 2: the Cloudflare account id is a 32-character
    /// string with no natural error-checking of its own (unlike an API key,
    /// nothing rejects a mistyped one until the first illustration call
    /// fails) -- masked entry alone gives no way to proofread it before
    /// that first failure. Off by default, matching every other field in
    /// this card staying masked; a household that wants to check what they
    /// typed reveals it deliberately via the eye button next to the field.
    @State private var showCloudflareAccountId = false

    var body: some View {
        ZStack {
            TTA.Palette.outerPaper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        serverCard
                        storyLengthCard
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
        .sheet(isPresented: $showVoicePickerSheet) {
            VoicePickerSheet(model: model)
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
                    : model.llmBackend == "groq"
                        // Issue #25: the parent picked Groq for home stories,
                        // so "nothing is sent to the internet" would be false.
                        ? "Your Mac on the home WiFi. Listening and voices run there; new stories use Groq's cloud for the story text."
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

    private var storyLengthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STORY LENGTH")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            storyLengthStepperRow(
                label: "Turns per story",
                value: model.storyTurnCount,
                range: 4...12
            ) { newValue in
                model.updateStorySettings(turnCount: newValue, pageCount: model.storybookPageCount)
            }

            storyLengthStepperRow(
                label: "Pages in the storybook",
                value: model.storybookPageCount,
                range: 3...10
            ) { newValue in
                model.updateStorySettings(turnCount: model.storyTurnCount, pageCount: newValue)
            }

            Text("Changes apply to your next story, not the one you're in now.")
                .font(TTA.Typography.body(12.5))
                .foregroundColor(TTA.Palette.inkSoft)
        }
        .padding(16)
        .background(TTA.Palette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A "− N +" row: two round tap-target buttons flanking the current
    /// value, matching this app's chunky, large-tap-target design
    /// language (see ChunkyButtonStyle/IconButtonStyle in DesignSystem.swift)
    /// rather than a bare SwiftUI Stepper's small default +/− controls.
    private func storyLengthStepperRow(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .font(TTA.Typography.body(14, weight: .semibold))
                .foregroundColor(TTA.Palette.ink)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    onChange(max(range.lowerBound, value - 1))
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.ttaIcon)
                .disabled(value <= range.lowerBound)
                .opacity(value <= range.lowerBound ? 0.4 : 1)

                Text("\(value)")
                    .font(TTA.Typography.display(17))
                    .foregroundColor(TTA.Palette.ink)
                    .frame(minWidth: 24)

                Button {
                    onChange(min(range.upperBound, value + 1))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.ttaIcon)
                .disabled(value >= range.upperBound)
                .opacity(value >= range.upperBound ? 0.4 : 1)
            }
        }
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
                Text("ELSIE'S BRAIN")
                    .font(TTA.Typography.display(12))
                    .tracking(1.5)
                    .foregroundColor(TTA.Palette.inkSoft)

                Text("Starting with the next story, Elsie thinks with:")
                    .font(TTA.Typography.body(12.5, weight: .medium))
                    .foregroundColor(TTA.Palette.inkSoft)

                Picker(
                    "Starting with the next story, Elsie thinks with",
                    selection: Binding(
                        get: { model.llmBackend },
                        set: { model.setLlmBackend($0) }
                    )
                ) {
                    Text("Mac (local)").tag("ollama")
                    Text("Groq cloud").tag("groq")
                }
                .pickerStyle(.segmented)

                Text("A story that's already going keeps the brain it started with -- a change here kicks in when the next story begins. With Groq, story text goes to Groq's cloud; listening and voices stay on your Mac. Needs GROQ_API_KEY set on the Mac.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)

                if model.isConnected, !model.awayFromHomeEnabled, let status = model.serverLlmStatus {
                    Text(llmStatusText(status))
                        .font(TTA.Typography.body(11.5))
                        .foregroundColor(
                            status.requested != status.active ? TTA.Palette.alert : TTA.Palette.inkSoft
                        )
                }

                Divider().padding(.vertical, 4)

                Text("Away from home")
                    .font(TTA.Typography.body(12.5, weight: .medium))
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

                Text("Optional -- pictures for away-from-home storybooks. Needs a free Cloudflare account: its account id and an API token (Workers AI). Without both, storybooks are text-only.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)

                HStack(spacing: 8) {
                    Group {
                        if showCloudflareAccountId {
                            TextField("Cloudflare account id (optional -- pictures)", text: $cloudflareAccountId)
                        } else {
                            SecureField("Cloudflare account id (optional -- pictures)", text: $cloudflareAccountId)
                        }
                    }
                    .font(.system(.body, design: .monospaced))

                    Button {
                        showCloudflareAccountId.toggle()
                    } label: {
                        Image(systemName: showCloudflareAccountId ? "eye.slash" : "eye")
                            .foregroundColor(TTA.Palette.inkSoft)
                    }
                }
                .padding(11)
                .background(TTA.Palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onChange(of: cloudflareAccountId) { newValue in
                    if newValue.isEmpty {
                        KeychainStore.delete("cloudflareAccountId")
                    } else {
                        KeychainStore.set(newValue, forKey: "cloudflareAccountId")
                    }
                }

                SecureField("Cloudflare API token (optional -- pictures)", text: $cloudflareApiToken)
                    .font(.system(.body, design: .monospaced))
                    .padding(11)
                    .background(TTA.Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .onChange(of: cloudflareApiToken) { newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete("cloudflareApiToken")
                        } else {
                            KeychainStore.set(newValue, forKey: "cloudflareApiToken")
                        }
                    }

                Toggle(
                    "Away-from-home mode",
                    isOn: Binding(
                        get: { model.awayFromHomeEnabled },
                        set: { model.setAwayFromHomeEnabled($0) }
                    )
                )
                .foregroundColor(TTA.Palette.inkSoft)
                // Issue #56 item 5: a whitespace-only key (e.g. a stray
                // space pasted in and never cleared) used to leave the
                // toggle enabled -- tapping it now shows a clear "no Groq
                // API key saved" message instead of a silent per-turn 401
                // (fixed during Phase 2), but the toggle's own visual state
                // still claimed a key was there. Trimmed the same way
                // connectAwayFromHome() trims before checking .isEmpty.
                .disabled(groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .tint(TTA.Palette.wood)

                if model.awayFromHomeEnabled {
                    Text("On: Elsie's brain runs in Groq's cloud right now, not your Mac.")
                        .font(TTA.Typography.body(11.5))
                        .foregroundColor(TTA.Palette.alert)
                }

                voicePickerRow

                Text("Changes apply to your next story, not the one you're in now.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)
            }
            .padding(16)
            .background(TTA.Palette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func llmStatusText(_ status: LlmBackendStatus) -> String {
        let active = status.active == "groq" ? "Groq cloud" : "Mac (local)"
        if status.requested == "groq" && !status.groqAvailable {
            return "Next story will use: \(active) -- no Groq key set on the Mac"
        }
        return "Next story will use: \(active)"
    }

    /// AVSpeechTts.resolveVoice() already picks Matilda by default (see
    /// that method's doc comment) -- this just lets a household try
    /// alternatives. Opens VoicePickerSheet rather than an inline Picker
    /// -- see showVoicePickerSheet's own doc comment for why.
    private var voicePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STORYTELLER VOICE")
                .font(TTA.Typography.display(12))
                .tracking(1.5)
                .foregroundColor(TTA.Palette.inkSoft)

            Button {
                showVoicePickerSheet = true
            } label: {
                HStack {
                    Text(VoicePickerSheet.label(forIdentifier: model.selectedVoiceIdentifier))
                        .foregroundColor(TTA.Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(TTA.Palette.inkSoft)
                }
                .padding(11)
                .background(TTA.Palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }

    /// Developer preview of the Reading/The End screens against mock data
    /// -- see MockStories.swift. Library is no longer previewed here: it
    /// shows real data via Landing's "Read Stories" button (LandingView.swift)
    /// once at least one story exists.
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

/// A tappable List, not Picker(.pickerStyle(.menu)) -- see
/// SettingsView.showVoicePickerSheet's doc comment for why: UIMenu
/// (what .menu renders as) glitches and stops scrolling past roughly its
/// first ~13 items, confirmed on-device against
/// AVSpeechTts.availableEnglishVoices()'s typical 30-50+ entries. A List
/// has no such limit -- same reasoning DebugLogSheet already established
/// for this screen's other sheet.
struct VoicePickerSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Shared with voicePickerRow's button label so the row and the
    /// sheet's own checkmark always describe the same voice the same
    /// way. Voice's own quality tier is already baked into
    /// AVSpeechSynthesisVoice.name for Enhanced/Premium voices on this
    /// OS (confirmed on-device 2026-09-14 -- see AVSpeechTts.swift's
    /// resolveVoice() doc comment), so this shows voice.name as-is
    /// rather than appending its own quality suffix and risking a
    /// duplicate like "Matilda (Premium) (Premium)".
    static func label(forIdentifier identifier: String?) -> String {
        guard let identifier,
              let voice = AVSpeechTts.availableEnglishVoices().first(where: { $0.identifier == identifier }) else {
            return "Default (Matilda, if downloaded)"
        }
        return "\(voice.name) (\(voice.language))"
    }

    var body: some View {
        NavigationView {
            List {
                voiceRow(label: "Default (Matilda, if downloaded)", isSelected: model.selectedVoiceIdentifier == nil) {
                    model.setSelectedVoiceIdentifier(nil)
                }
                ForEach(AVSpeechTts.availableEnglishVoices(), id: \.identifier) { voice in
                    voiceRow(
                        label: "\(voice.name) (\(voice.language))",
                        isSelected: model.selectedVoiceIdentifier == voice.identifier
                    ) {
                        model.setSelectedVoiceIdentifier(voice.identifier)
                    }
                }
            }
            // Root cause of the barely-visible-text report: TTA.Palette.ink
            // is a fixed dark warm color, designed for this app's own fixed
            // light "paper" backgrounds (used explicitly everywhere else in
            // Settings) -- NOT for List's default background, which follows
            // the system's light/dark appearance. In dark mode that's dark
            // ink text on a dark system background. Rather than just
            // picking a lighter fixed text color (which would then be
            // low-contrast in LIGHT system mode instead), this gives the
            // List the same explicit paper background the rest of the app
            // already uses regardless of system appearance.
            .scrollContentBackground(.hidden)
            .background(TTA.Palette.outerPaper)
            .navigationTitle("Storyteller voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func voiceRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(TTA.Palette.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(TTA.Palette.wood)
                }
            }
        }
        .listRowBackground(TTA.Palette.paper)
    }
}
