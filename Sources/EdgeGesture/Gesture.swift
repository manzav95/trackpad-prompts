import Foundation

// One finger on the trackpad, already decoded.
// x = 0 is the left edge, y = 0 is the bottom edge. Confirmed on this Mac.
public struct Finger: Equatable {
    public var id: Int32
    public var x: Float
    public var y: Float
    public var phase: Int32

    public init(id: Int32, x: Float, y: Float, phase: Int32) {
        self.id = id
        self.x = x
        self.y = y
        self.phase = phase
    }

    // 1 start-in-range, 3 make-touch, 4 touching, 5 break-touch.
    // Hover (2) is not a contact.
    public var isContact: Bool {
        phase == 1 || phase == 3 || phase == 4 || phase == 5
    }
}

public enum EdgeAction: String, Equatable {
    case volume
    case brightness
    case tracks
    case nothing
}

public struct EdgeAssignment: Equatable {
    public var left: EdgeAction
    public var right: EdgeAction
    public var bottom: EdgeAction

    public init(left: EdgeAction = .brightness, right: EdgeAction = .volume, bottom: EdgeAction = .tracks) {
        self.left = left
        self.right = right
        self.bottom = bottom
    }

    func action(for edge: Edge) -> EdgeAction {
        switch edge {
        case .left: return left
        case .right: return right
        case .bottom: return bottom
        }
    }
}

public struct GestureConfig: Equatable {
    public var edgeStrip: Float
    public var armDistance: Float
    public var sensitivity: Float
    public var assignment: EdgeAssignment

    public init(
        edgeStrip: Float = 0.06,
        armDistance: Float = 0.03,
        sensitivity: Float = 0.60,
        assignment: EdgeAssignment = EdgeAssignment()
    ) {
        self.edgeStrip = edgeStrip
        self.armDistance = armDistance
        self.sensitivity = sensitivity
        self.assignment = assignment
    }
}

public enum GestureEvent: Equatable {
    /// Change from the level where the finger landed, as a fraction of the full range.
    case volume(Float)
    case brightness(Float)
    case nextTrack
    case previousTrack
    /// The volume or brightness slide is over. Hide the pill.
    case ended
}

enum Edge: Equatable {
    case left
    case right
    case bottom
}

public struct GestureState {
    var blocked = false
    var fingerID: Int32?
    var originX: Float = 0
    var originY: Float = 0
    var candidates: [Edge] = []
    var edge: Edge?
    var armed = false
    var rejected = false
    var skipSent = false
    var showing = false

    public init() {}
}

/// Fingers in, events out. `state` is the value returned last time.
///
/// A gesture needs one finger that starts inside an edge strip and then slides
/// along that edge. Two or more fingers cancel it, and nothing starts again
/// until every finger has lifted. A finger that moves toward the centre first
/// is the pointer.
public func evaluateGesture(
    fingers: [Finger],
    state: GestureState = GestureState(),
    config: GestureConfig = GestureConfig()
) -> (events: [GestureEvent], state: GestureState) {
    let contacts = fingers.filter(\.isContact)
    var state = state
    var events: [GestureEvent] = []

    if contacts.isEmpty {
        if state.showing { events.append(.ended) }
        return (events, GestureState())
    }

    if contacts.count >= 2 {
        if state.showing { events.append(.ended) }
        var blocked = GestureState()
        blocked.blocked = true
        return (events, blocked)
    }

    if state.blocked {
        return ([], state)
    }

    let finger = contacts[0]
    if state.fingerID != finger.id {
        if state.showing { events.append(.ended) }
        state = GestureState()
        state.fingerID = finger.id
        state.originX = finger.x
        state.originY = finger.y
        state.candidates = strips(x: finger.x, y: finger.y, strip: config.edgeStrip).filter {
            config.assignment.action(for: $0) != .nothing
        }
        if state.candidates.isEmpty {
            state.rejected = true
        }
    }

    if state.rejected {
        return (events, state)
    }

    if !state.armed {
        switch arm(finger: finger, state: state, config: config) {
        case .wait:
            return (events, state)
        case .reject:
            state.rejected = true
            return (events, state)
        case .arm(let edge):
            state.edge = edge
            state.armed = true
        }
    }

    guard let edge = state.edge else { return (events, state) }
    let signed: Float
    switch edge {
    case .left, .right:
        signed = finger.y - state.originY
    case .bottom:
        signed = finger.x - state.originX
    }

    switch config.assignment.action(for: edge) {
    case .nothing:
        state.rejected = true
    case .volume:
        events.append(.volume(signed * config.sensitivity))
        state.showing = true
    case .brightness:
        events.append(.brightness(signed * config.sensitivity))
        state.showing = true
    case .tracks:
        if !state.skipSent {
            if signed > 0 {
                events.append(.nextTrack)
            } else if signed < 0 {
                events.append(.previousTrack)
            }
            state.skipSent = true
        }
        state.showing = true
    }
    return (events, state)
}

public extension Finger {
    /// One 96-byte MultitouchSupport contact. x is the float at byte 32, y at 36.
    init?(block: Data) {
        guard block.count >= 96 else { return nil }
        let x = readFloat(block, 32)
        let y = readFloat(block, 36)
        guard x.isFinite, y.isFinite else { return nil }
        self.init(id: readInt32(block, 16), x: x, y: y, phase: readInt32(block, 20))
    }
}

private func strips(x: Float, y: Float, strip: Float) -> [Edge] {
    var found: [Edge] = []
    if x < strip { found.append(.left) }
    if x > 1 - strip { found.append(.right) }
    if y < strip { found.append(.bottom) }
    return found
}

private enum Arm {
    case wait
    case reject
    case arm(Edge)
}

private struct Motion {
    var edge: Edge
    var along: Float
    var inward: Float
}

private func arm(finger: Finger, state: GestureState, config: GestureConfig) -> Arm {
    let motions = state.candidates.map { edge -> Motion in
        switch edge {
        case .left:
            return Motion(
                edge: .left,
                along: abs(finger.y - state.originY),
                inward: max(0, finger.x - state.originX)
            )
        case .right:
            return Motion(
                edge: .right,
                along: abs(finger.y - state.originY),
                inward: max(0, state.originX - finger.x)
            )
        case .bottom:
            return Motion(
                edge: .bottom,
                along: abs(finger.x - state.originX),
                inward: max(0, finger.y - state.originY)
            )
        }
    }

    let ready = motions.filter { $0.along >= config.armDistance && $0.along >= $0.inward }
    if let best = ready.max(by: { lhs, rhs in
        if lhs.along != rhs.along { return lhs.along < rhs.along }
        return rank(lhs.edge) < rank(rhs.edge)
    }) {
        return .arm(best.edge)
    }

    let stillOpen = motions.contains { motion in
        let ruledOut = motion.inward >= config.armDistance && motion.inward > motion.along
        return !ruledOut
    }
    return stillOpen ? .wait : .reject
}

private func rank(_ edge: Edge) -> Int {
    switch edge {
    case .bottom: return 0
    case .left: return 1
    case .right: return 2
    }
}

private func readFloat(_ data: Data, _ offset: Int) -> Float {
    readNumber(data, offset)
}

private func readInt32(_ data: Data, _ offset: Int) -> Int32 {
    readNumber(data, offset)
}

private func readNumber<T>(_ data: Data, _ offset: Int) -> T {
    let size = MemoryLayout<T>.size
    precondition(size <= 8 && offset >= 0 && offset + size <= data.count)
    var storage: UInt64 = 0
    data.withUnsafeBytes { source in
        let slice = UnsafeRawBufferPointer(rebasing: source[offset..<(offset + size)])
        withUnsafeMutableBytes(of: &storage) { dest in
            dest.copyMemory(from: slice)
        }
    }
    return withUnsafeBytes(of: &storage) { $0.load(as: T.self) }
}
