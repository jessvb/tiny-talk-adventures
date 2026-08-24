/// The turn-taking state machine. Pure logic, no I/O -- mirrors the
/// server's state.py exactly, including the reasoning for the interrupt
/// transitions: an interrupt is legal from every state and always lands
/// in .listening, because the child has started talking and whatever the
/// client was doing no longer matters.

public enum SessionState: Sendable, Equatable {
    case idle
    case listening
    case waitingForReply
    case speaking
}

public enum SessionEvent: Sendable, Equatable {
    case speechStart
    case speechEnd
    case audioChunkReceived
    case turnEnd
    case interrupt
    case disconnected
}

public enum InvalidTransition: Error, Equatable {
    case notAllowed(from: SessionState, event: SessionEvent)
}

private struct TransitionKey: Hashable {
    let state: SessionState
    let event: SessionEvent
}

private let transitions: [TransitionKey: SessionState] = [
    TransitionKey(state: .idle, event: .speechStart): .listening,
    TransitionKey(state: .listening, event: .speechEnd): .waitingForReply,
    TransitionKey(state: .waitingForReply, event: .audioChunkReceived): .speaking,
    TransitionKey(state: .waitingForReply, event: .turnEnd): .idle,
    TransitionKey(state: .speaking, event: .turnEnd): .idle,
    TransitionKey(state: .idle, event: .interrupt): .listening,
    TransitionKey(state: .listening, event: .interrupt): .listening,
    TransitionKey(state: .waitingForReply, event: .interrupt): .listening,
    TransitionKey(state: .speaking, event: .interrupt): .listening,
    TransitionKey(state: .idle, event: .disconnected): .idle,
    TransitionKey(state: .listening, event: .disconnected): .idle,
    TransitionKey(state: .waitingForReply, event: .disconnected): .idle,
    TransitionKey(state: .speaking, event: .disconnected): .idle,
]

public final class SessionStateMachine {
    public private(set) var state: SessionState = .idle

    public init() {}

    @discardableResult
    public func handle(_ event: SessionEvent) throws -> SessionState {
        guard let next = transitions[TransitionKey(state: state, event: event)] else {
            throw InvalidTransition.notAllowed(from: state, event: event)
        }
        state = next
        return state
    }
}
