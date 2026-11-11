import CoreGraphics
import Darwin

/// Keeps the pointer where it was when an edge slide starts, and puts that
/// connection back when the finger lifts. No event tap, so a four-finger swipe
/// still changes desktops.
enum CursorHold {
    private static var saved: CGPoint?
    private static var disconnected = false

    static var isHeld: Bool { saved != nil }

    static func begin() {
        if saved == nil {
            saved = CGEvent(source: nil)?.location
        }
        guard let saved else { return }
        if !disconnected {
            disconnected = CGAssociateMouseAndMouseCursorPosition(boolean_t(0)) == .success
        }
        CGWarpMouseCursorPosition(saved)
    }

    static func tick() {
        guard let saved else { return }
        CGWarpMouseCursorPosition(saved)
    }

    static func end() {
        let restore = saved
        if disconnected {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }
        saved = nil
        disconnected = false
        if let restore {
            CGWarpMouseCursorPosition(restore)
        }
    }
}
