import SwiftUI

/// App root: dispatches to the current AppScreen. AppModel (session state,
/// connection, navigation) and CameraPicker live in AppModel.swift; the
/// screens themselves live in OnboardingView/LandingView/StoryView/
/// SettingsView.swift -- see docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md
/// for how this replaces the previous bare-bones debug UI.
struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.screen {
            case .onboarding:
                OnboardingView(model: model)
            case .landing:
                LandingView(model: model)
            case .creating:
                StoryView(model: model)
            case .settings:
                SettingsView(model: model)
            case .library:
                LibraryView(model: model)
            case .reading:
                ReadingView(model: model)
            case .theEnd:
                TheEndView(model: model)
            }
        }
        // Single-value closure (not the two-value oldValue/newValue form,
        // which needs iOS 17+ -- this project's deployment target is 16,
        // see project.yml) -- no need to compare against a previous
        // phase anyway, since handleAppForegrounded() already guards
        // internally on whether IT was the one that disconnected. Only
        // .background (not the momentary .inactive that happens e.g.
        // pulling down Control Center) triggers a disconnect -- reacting
        // to .inactive too would disconnect/reconnect on every brief
        // interruption, far more disruptive than the problem this fixes.
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                Task { await model.handleAppBackgrounded() }
            case .active:
                Task { await model.handleAppForegrounded() }
            default:
                break
            }
        }
    }
}
