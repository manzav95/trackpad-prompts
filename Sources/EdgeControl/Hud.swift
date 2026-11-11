import AppKit
import CoreGraphics

/// Black pill under the notch: a white symbol and a thin blue level bar.
/// It hangs from the notch at the notch width. If another window already
/// occupies that slot, the pill sits just under it, still the same width.
final class Hud {
    private let window: NSWindow
    private let pill: PillView
    private var screen: NSScreen?

    init() {
        pill = PillView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        window = NSWindow(
            contentRect: pill.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = pill
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
    }

    func show(symbol: String, level: CGFloat) {
        present(symbol: symbol, level: level, showsBar: true)
    }

    /// A skip: one symbol in the centre of a short capsule. No level bar.
    func showAction(symbol: String) {
        present(symbol: symbol, level: 0, showsBar: false)
    }

    private func present(symbol: String, level: CGFloat, showsBar: Bool) {
        let place = placement(compact: !showsBar)
        pill.symbolName = symbol
        pill.level = min(1, max(0, level))
        pill.showsBar = showsBar
        pill.needsDisplay = true
        window.setFrame(place.frame, display: true)
        window.hasShadow = true
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func placement(compact: Bool) -> (frame: CGRect, hangs: Bool) {
        let screen = notchedScreen() ?? NSScreen.main
        self.screen = screen
        guard let screen else {
            let width: CGFloat = compact ? 88 : 220
            return (CGRect(x: 80, y: 80, width: width, height: 36), false)
        }
        let height: CGFloat = 36
        let wide: CGRect
        if let notch = notchRect(on: screen) {
            let width = max(notch.width, 220)
            var frame = CGRect(x: notch.midX - width / 2, y: notch.minY - 8 - height, width: width, height: height)
            if let bottom = occupantBottom(in: notch, on: screen) {
                frame.origin.y = bottom - 6 - height
            }
            wide = frame
        } else {
            let width: CGFloat = 280
            let x = screen.frame.midX - width / 2
            let y = screen.visibleFrame.maxY - height - 8
            wide = CGRect(x: x, y: y, width: width, height: height)
        }
        guard compact else { return (wide, false) }
        let width: CGFloat = 88
        return (CGRect(x: wide.midX - width / 2, y: wide.minY, width: width, height: height), false)
    }

    private func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func notchRect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard left.width > 0, right.width > 0, width > 40 else { return nil }
        return CGRect(x: left.maxX, y: left.minY, width: width, height: max(left.height, screen.safeAreaInsets.top))
    }

    /// Bottom edge, in AppKit points, of another window sitting in the notch.
    private func occupantBottom(in notch: CGRect, on screen: NSScreen) -> CGFloat? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            return nil
        }
        let own = ProcessInfo.processInfo.processIdentifier
        var lowest: CGFloat?
        for index in 0..<CFArrayGetCount(info) {
            guard let pointer = CFArrayGetValueAtIndex(info, index) else { continue }
            let window = Unmanaged<NSDictionary>.fromOpaque(pointer).takeUnretainedValue()
            if (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == own { continue }
            guard let bounds = cgRect(window[kCGWindowBounds]) else { continue }
            let frame = appKitFrame(fromWindowBounds: bounds, on: screen)
            let wideMenuBar = frame.width > screen.frame.width * 0.5
            let pillSized = frame.width <= notch.width + 80 && frame.height >= 8 && frame.height <= 80
            guard pillSized, !wideMenuBar, frame.intersects(notch) else { continue }
            lowest = min(lowest ?? frame.minY, frame.minY)
        }
        return lowest
    }

    private func cgRect(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }

    private func appKitFrame(fromWindowBounds bounds: CGRect, on screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? screen
        let y = primary.frame.maxY - bounds.origin.y - bounds.height
        return CGRect(x: bounds.origin.x, y: y, width: bounds.width, height: bounds.height)
    }
}

final class PillView: NSView {
    var symbolName = "speaker.wave.2.fill"
    var level: CGFloat = 0
    var showsBar = true

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.94).setFill()
        capsule.fill()

        if !showsBar {
            let icon: CGFloat = 22
            drawSymbol(
                symbolName,
                in: NSRect(x: (bounds.width - icon) / 2, y: (bounds.height - icon) / 2, width: icon, height: icon),
                pointSize: 18
            )
            return
        }

        let icon: CGFloat = 16
        let pad: CGFloat = 14
        drawSymbol(symbolName, in: NSRect(x: pad, y: (bounds.height - icon) / 2, width: icon, height: icon), pointSize: 14)
        drawSymbol("sparkle", in: NSRect(x: bounds.width - pad - 12, y: (bounds.height - 12) / 2, width: 12, height: 12), pointSize: 11)

        let barHeight: CGFloat = 8
        let barX = pad + icon + 12
        let barWidth = bounds.width - barX - pad - 12 - 10
        let bar = NSRect(x: barX, y: (bounds.height - barHeight) / 2, width: barWidth, height: barHeight)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let filledWidth = max(barHeight, bar.width * level)
        let filled = NSRect(x: bar.minX, y: bar.minY, width: min(bar.width, filledWidth), height: bar.height)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).addClip()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.82, green: 0.91, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.22, green: 0.52, blue: 1, alpha: 1),
        ])
        gradient?.draw(in: bar, angle: 0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        image.draw(in: rect)
    }
}
