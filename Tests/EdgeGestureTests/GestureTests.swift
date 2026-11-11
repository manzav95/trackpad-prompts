import XCTest
@testable import EdgeGesture

final class GestureTests: XCTestCase {
    func testOneFingerAlongTheRightEdgeSetsVolume() {
        let events = play([
            [f(1, 0.98, 0.10)],
            [f(1, 0.98, 1.00)],
        ])
        expect(events, [.volume(0.90 * 0.60)])
    }

    func testOneFingerAlongTheLeftEdgeSetsBrightness() {
        let events = play([
            [f(1, 0.02, 0.20)],
            [f(1, 0.02, 0.70)],
        ])
        expect(events, [.brightness(0.50 * 0.60)])
    }

    func testTwoFingersAreNeverAGestureUntilEveryFingerLifts() {
        let events = play([
            [f(1, 0.98, 0.20), f(2, 0.40, 0.40)],
            [f(1, 0.98, 0.80)],
            [],
            [f(1, 0.98, 0.10)],
            [f(1, 0.98, 0.60)],
        ])
        expect(events, [.volume(0.50 * 0.60)])
    }

    func testASecondFingerCancelsASlideAndBlocksUntilAllLift() {
        let events = play([
            [f(1, 0.98, 0.20)],
            [f(1, 0.98, 0.50)],
            [f(1, 0.98, 0.50), f(2, 0.30, 0.30)],
            [f(1, 0.98, 0.90)],
            [],
        ])
        expect(events, [.volume(0.30 * 0.60), .ended])
    }

    func testAFingerThatStartsOutsideTheStripDoesNothing() {
        let events = play([
            [f(1, 0.50, 0.50)],
            [f(1, 0.98, 0.20)],
            [f(1, 0.98, 0.90)],
        ])
        XCTAssertEqual(events, [])
    }

    func testMovingTowardTheCentreFirstIsThePointer() {
        let events = play([
            [f(1, 0.98, 0.40)],
            [f(1, 0.90, 0.41)],
            [f(1, 0.90, 0.90)],
        ])
        XCTAssertEqual(events, [])
    }

    func testASmallDriftTowardTheCentreStillArmsAlongTheEdge() {
        let events = play([
            [f(1, 0.98, 0.40)],
            [f(1, 0.97, 0.41)],
            [f(1, 0.97, 0.45)],
        ])
        expect(events, [.volume(0.05 * 0.60)])
    }

    func testTheWholeEdgeIsTheSensitivityFraction() {
        let gentle = GestureConfig(sensitivity: 0.25)
        let events = play([
            [f(1, 0.99, 0)],
            [f(1, 0.99, 1)],
        ], config: gentle)
        expect(events, [.volume(0.25)])
    }

    func testBottomSwipeFiresOneSkip() {
        let right = play([
            [f(1, 0.20, 0.02)],
            [f(1, 0.24, 0.02)],
            [f(1, 0.70, 0.02)],
            [f(1, 0.20, 0.02)],
        ])
        XCTAssertEqual(right, [.nextTrack])

        let left = play([
            [f(1, 0.80, 0.01)],
            [f(1, 0.76, 0.01)],
            [f(1, 0.10, 0.01)],
            [],
            [f(2, 0.80, 0.01)],
            [f(2, 0.70, 0.01)],
        ])
        XCTAssertEqual(left, [.previousTrack, .ended, .previousTrack])
    }

    func testABottomSwipeThatMovesInwardFirstDoesNotSkip() {
        let events = play([
            [f(1, 0.40, 0.02)],
            [f(1, 0.40, 0.10)],
            [f(1, 0.90, 0.10)],
        ])
        XCTAssertEqual(events, [])
    }

    func testAnEdgeSetToNothingIsIgnored() {
        let config = GestureConfig(assignment: EdgeAssignment(left: .brightness, right: .nothing, bottom: .tracks))
        let events = play([
            [f(1, 0.98, 0.20)],
            [f(1, 0.98, 0.80)],
        ], config: config)
        XCTAssertEqual(events, [])
    }

    func testBottomEdgeCanSetVolume() {
        let config = GestureConfig(assignment: EdgeAssignment(left: .nothing, right: .nothing, bottom: .volume))
        let events = play([
            [f(1, 0.10, 0.02)],
            [f(1, 0.90, 0.02)],
        ], config: config)
        expect(events, [.volume(0.80 * 0.60)])
    }

    func testLeftEdgeCanSkipTracks() {
        let config = GestureConfig(assignment: EdgeAssignment(left: .tracks, right: .nothing, bottom: .nothing))
        let up = play([
            [f(1, 0.02, 0.20)],
            [f(1, 0.02, 0.40)],
            [f(1, 0.02, 0.80)],
        ], config: config)
        XCTAssertEqual(up, [.nextTrack])

        let down = play([
            [f(1, 0.02, 0.80)],
            [f(1, 0.02, 0.50)],
        ], config: config)
        XCTAssertEqual(down, [.previousTrack])
    }

    func testACornerSlideUpIsBrightness() {
        let events = play([
            [f(1, 0.02, 0.02)],
            [f(1, 0.02, 0.20)],
        ])
        expect(events, [.brightness(0.18 * 0.60)])
    }

    func testLayoutBytesMatchThisMac() {
        let parsed = Finger(block: block(id: 8, phase: 4, x: 0.477207, y: 0.589751))
        XCTAssertEqual(parsed?.id, 8)
        XCTAssertEqual(parsed?.phase, 4)
        XCTAssertEqual(parsed?.x ?? -1, 0.477207, accuracy: 0.00001)
        XCTAssertEqual(parsed?.y ?? -1, 0.589751, accuracy: 0.00001)
    }

    private func expect(
        _ events: [GestureEvent],
        _ expected: [GestureEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(events.count, expected.count, "\(events)", file: file, line: line)
        for pair in zip(events, expected) {
            switch pair {
            case (.volume(let got), .volume(let want)), (.brightness(let got), .brightness(let want)):
                XCTAssertEqual(got, want, accuracy: 0.0001, file: file, line: line)
            default:
                XCTAssertEqual(pair.0, pair.1, file: file, line: line)
            }
        }
    }

    private func f(_ id: Int32, _ x: Float, _ y: Float, phase: Int32 = 4) -> Finger {
        Finger(id: id, x: x, y: y, phase: phase)
    }

    private func play(_ frames: [[Finger]], config: GestureConfig = GestureConfig()) -> [GestureEvent] {
        var state = GestureState()
        var events: [GestureEvent] = []
        for frame in frames {
            let step = evaluateGesture(fingers: frame, state: state, config: config)
            events.append(contentsOf: step.events)
            state = step.state
        }
        return events
    }

    private func block(id: Int32, phase: Int32, x: Float, y: Float) -> Data {
        var data = Data(count: 96)
        write(id, into: &data, at: 16)
        write(phase, into: &data, at: 20)
        write(x, into: &data, at: 32)
        write(y, into: &data, at: 36)
        return data
    }

    private func write<T>(_ value: T, into data: inout Data, at offset: Int) {
        var stored = value
        let size = MemoryLayout<T>.size
        withUnsafeBytes(of: &stored) { raw in
            data.replaceSubrange(offset..<(offset + size), with: Array(raw))
        }
    }
}
