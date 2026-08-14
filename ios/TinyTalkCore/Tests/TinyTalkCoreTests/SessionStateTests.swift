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
