import SwiftUI

/// Grown-up settings screen (design 1a). The design's "Story length" /
/// "Elsie's voice speed" / "Real animal facts" / "Camera inspiration" rows
/// are omitted here -- none are backed by any client-controllable setting
/// today (those are server env vars, not wire-protocol-exposed), and this
/// project's own conventions call for no fabricated toggles that don't do
/// anything. "Under the hood" instead surfaces real debug data that already
/// existed in the bare-bones harness (state/turn id/latency/debug log).
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            TTA.Palette.outerPaper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        serverCard
                        underTheHoodCard
                        replayButton
                    }
                    .padding(20)
                }
            }
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

            Text("Your Mac on the home WiFi. Speech, story and voice all run there — nothing is sent to the internet.")
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
