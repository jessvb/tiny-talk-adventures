import XCTest
@testable import TinyTalkCore

final class SessionStateTests: XCTestCase {
    func testStartsIdle() {
        XCTAssertEqual(SessionStateMachine().state, .idle)
    }

    func testHappyPathCyclesBackToIdle() throws {
        let machine = SessionStateMachine()
        XCTAssertEqual(try machine.handle(.speechStart), .listening)
        XCTAssertEqual(try machine.handle(.speechEnd), .waitingForReply)
        XCTAssertEqual(try machine.handle(.audioChunkReceived), .speaking)
        XCTAssertEqual(try machine.handle(.turnEnd), .idle)
    }

    func testEmptyReplyGoesStraightFromWaitingForReplyToIdle() throws {
        // Mirrors the server's empty-transcript case: no audio chunk ever
        // arrives, turn_end comes directly.
        let machine = SessionStateMachine()
        _ = try machine.handle(.speechStart)
        _ = try machine.handle(.speechEnd)
        XCTAssertEqual(try machine.handle(.turnEnd), .idle)
    }

    func testInterruptFromEveryStateLandsInListening() throws {
        let setups: [(String, [SessionEvent])] = [
            ("idle", []),
            ("listening", [.speechStart]),
            ("waitingForReply", [.speechStart, .speechEnd]),
            ("speaking", [.speechStart, .speechEnd, .audioChunkReceived]),
        ]
        for (name, setup) in setups {
            let machine = SessionStateMachine()
            for event in setup {
                _ = try machine.handle(event)
            }
            XCTAssertEqual(try machine.handle(.interrupt), .listening, "from \(name)")
        }
    }

    /// Mirrors the server's Event.CONCLUDE ("Finish this story" menu
    /// action, see server/tinytalk/state.py): legal from every state --
    /// the child/parent can ask to finish the story regardless of what's
    /// currently happening -- and always lands in .waitingForReply, since
    /// sending conclude_story itself triggers the server's forced final
    /// reply, same as a normal speechEnd.
    func testConcludeFromEveryStateLandsInWaitingForReply() throws {
        let setups: [(String, [SessionEvent])] = [
            ("idle", []),
            ("listening", [.speechStart]),
            ("waitingForReply", [.speechStart, .speechEnd]),
            ("speaking", [.speechStart, .speechEnd, .audioChunkReceived]),
        ]
        for (name, setup) in setups {
            let machine = SessionStateMachine()
            for event in setup {
                _ = try machine.handle(event)
            }
            XCTAssertEqual(try machine.handle(.conclude), .waitingForReply, "from \(name)")
        }
    }

    func testBargeInThenCompletesANewTurn() throws {
        let machine = SessionStateMachine()
        _ = try machine.handle(.speechStart)
        _ = try machine.handle(.speechEnd)
        _ = try machine.handle(.audioChunkReceived)
        _ = try machine.handle(.interrupt)
        XCTAssertEqual(try machine.handle(.speechEnd), .waitingForReply)
        XCTAssertEqual(try machine.handle(.audioChunkReceived), .speaking)
        XCTAssertEqual(try machine.handle(.turnEnd), .idle)
    }

    func testRejectsNonsenseTransition() {
        let machine = SessionStateMachine()
        XCTAssertThrowsError(try machine.handle(.turnEnd)) { error in
            guard case InvalidTransition.notAllowed(let from, let event) = error else {
                return XCTFail("expected InvalidTransition, got \(error)")
            }
            XCTAssertEqual(from, .idle)
            XCTAssertEqual(event, .turnEnd)
        }
    }

    func testRejectedTransitionLeavesStateUnchanged() {
        let machine = SessionStateMachine()
        _ = try? machine.handle(.turnEnd)
        XCTAssertEqual(machine.state, .idle)
    }

    func testResumedFromIdleLandsInWaitingForReply() throws {
        let machine = SessionStateMachine()
        XCTAssertEqual(try machine.handle(.resumed), .waitingForReply)
    }

    func testResumedIsOnlyLegalFromIdle() {
        let setups: [(String, [SessionEvent])] = [
            ("listening", [.speechStart]),
            ("waitingForReply", [.speechStart, .speechEnd]),
            ("speaking", [.speechStart, .speechEnd, .audioChunkReceived]),
        ]
        for (name, setup) in setups {
            let machine = SessionStateMachine()
            for event in setup {
                _ = try? machine.handle(event)
            }
            XCTAssertThrowsError(try machine.handle(.resumed), "from \(name)")
        }
    }

    func testDisconnectedFromEveryStateLandsInIdle() throws {
        let setups: [(String, [SessionEvent])] = [
            ("idle", []),
            ("listening", [.speechStart]),
            ("waitingForReply", [.speechStart, .speechEnd]),
            ("speaking", [.speechStart, .speechEnd, .audioChunkReceived]),
        ]
        for (name, setup) in setups {
            let machine = SessionStateMachine()
            for event in setup {
                _ = try machine.handle(event)
            }
            XCTAssertEqual(try machine.handle(.disconnected), .idle, "from \(name)")
        }
    }
}
