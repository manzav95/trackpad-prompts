import AppKit
import EdgeGesture
import ServiceManagement

final class AppController: NSObject {
    private let reader = TouchReader.shared
    private let volume = VolumeControl()
    private let brightness = BrightnessControl()
    private let hud = Hud()
    private let settings = SettingsWindow()

    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var gestureState = GestureState()
    private var volumeBase: Float?
    private var brightnessBase: Float?

    private let enabledKey = "edgeEnabled"
    private let sensitivityKey = "edgeSensitivity"
    private let leftKey = "edgeLeft"
    private let rightKey = "edgeRight"
    private let bottomKey = "edgeBottom"
    private let showHudKey = "showHud"
    private let hideDelayKey = "hudDelayMs"
    private var hideWork: DispatchWorkItem?

    private var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private var sensitivity: Float {
        get {
            if UserDefaults.standard.object(forKey: sensitivityKey) == nil { return 0.60 }
            return UserDefaults.standard.float(forKey: sensitivityKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: sensitivityKey) }
    }

    private var showHud: Bool {
        get {
            if UserDefaults.standard.object(forKey: showHudKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showHudKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showHudKey) }
    }

    private var hideDelay: Int {
        get {
            if UserDefaults.standard.object(forKey: hideDelayKey) == nil { return 400 }
            return min(5000, max(0, UserDefaults.standard.integer(forKey: hideDelayKey)))
        }
        set { UserDefaults.standard.set(min(5000, max(0, newValue)), forKey: hideDelayKey) }
    }

    private var assignment: EdgeAssignment {
        get {
            EdgeAssignment(
                left: storedAction(leftKey, .brightness),
                right: storedAction(rightKey, .volume),
                bottom: storedAction(bottomKey, .tracks)
            )
        }
        set {
            UserDefaults.standard.set(newValue.left.rawValue, forKey: leftKey)
            UserDefaults.standard.set(newValue.right.rawValue, forKey: rightKey)
            UserDefaults.standard.set(newValue.bottom.rawValue, forKey: bottomKey)
            gestureState = GestureState()
        }
    }

    private func storedAction(_ key: String, _ fallback: EdgeAction) -> EdgeAction {
        guard let raw = UserDefaults.standard.string(forKey: key), let action = EdgeAction(rawValue: raw) else {
            return fallback
        }
        return action
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "capsule", accessibilityDescription: "Edge Controls") {
            image.isTemplate = true
            item.button?.image = image
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Edge Controls", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(toggle)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        toggleItem = toggle
        loginItem = login

        settings.onToggle = { [weak self] on in self?.setEnabled(on) }
        settings.onSensitivity = { [weak self] value in self?.sensitivity = value }
        settings.onAssignment = { [weak self] value in self?.assignment = value }
        settings.onShowHud = { [weak self] value in
            self?.showHud = value
            if !value { self?.hideNow() }
        }
        settings.onHideDelay = { [weak self] value in self?.hideDelay = value }
        reader.onFrame = { [weak self] fingers in self?.handle(fingers) }

        if enabled {
            if let error = reader.start() {
                enabled = false
                presentSettings(status: error, isError: true)
            }
        }
        syncMenu()
    }

    private func handle(_ fingers: [Finger]) {
        guard enabled else { return }
        let step = evaluateGesture(
            fingers: fingers,
            state: gestureState,
            config: GestureConfig(sensitivity: sensitivity, assignment: assignment)
        )
        gestureState = step.state
        for event in step.events {
            apply(event)
        }
        if CursorHold.isHeld {
            CursorHold.tick()
        }
    }

    private func apply(_ event: GestureEvent) {
        switch event {
        case .volume(let delta):
            CursorHold.begin()
            if volumeBase == nil { volumeBase = volume.current() }
            let level = min(1, max(0, (volumeBase ?? 0.5) + delta))
            volume.set(level)
            showLevel(symbol: "speaker.wave.2.fill", level: level)
        case .brightness(let delta):
            CursorHold.begin()
            if brightnessBase == nil { brightnessBase = brightness.current() }
            let level = min(1, max(0, (brightnessBase ?? 0.5) + delta))
            brightness.set(level)
            showLevel(symbol: "sun.max.fill", level: level)
        case .nextTrack:
            CursorHold.begin()
            TrackSkip.send(next: true)
            showAction(symbol: "forward.fill")
        case .previousTrack:
            CursorHold.begin()
            TrackSkip.send(next: false)
            showAction(symbol: "backward.fill")
        case .ended:
            CursorHold.end()
            volumeBase = nil
            brightnessBase = nil
            scheduleHide()
        }
    }

    private func showLevel(symbol: String, level: Float) {
        guard showHud else { return }
        hideWork?.cancel()
        hud.show(symbol: symbol, level: CGFloat(level))
    }

    private func showAction(symbol: String) {
        guard showHud else { return }
        hideWork?.cancel()
        hud.showAction(symbol: symbol)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard showHud else {
            hud.hide()
            return
        }
        let ms = hideDelay
        guard ms > 0 else {
            hud.hide()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hud.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        hud.hide()
    }

    @objc private func toggleEnabled() {
        setEnabled(!enabled)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        gestureState = GestureState()
        volumeBase = nil
        brightnessBase = nil
        hideNow()
        CursorHold.end()
        if on {
            if let error = reader.start() {
                enabled = false
                presentSettings(status: error, isError: true)
            }
        } else {
            reader.stop()
        }
        syncMenu()
        refreshSettings()
    }

    @objc private func openSettings() {
        presentSettings(status: statusText().text, isError: statusText().isError)
    }

    private func presentSettings(status: String, isError: Bool) {
        settings.show(
            enabled: enabled,
            sensitivity: sensitivity,
            assignment: assignment,
            showHud: showHud,
            hideDelay: hideDelay,
            status: status,
            statusIsError: isError
        )
    }

    private func refreshSettings() {
        let status = statusText()
        settings.apply(
            enabled: enabled,
            sensitivity: sensitivity,
            assignment: assignment,
            showHud: showHud,
            hideDelay: hideDelay,
            status: status.text,
            statusIsError: status.isError
        )
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            presentSettings(status: error.localizedDescription, isError: true)
        }
        syncMenu()
    }

    private func syncMenu() {
        toggleItem?.state = enabled ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func statusText() -> (text: String, isError: Bool) {
        var lines: [String] = []
        var isError = false
        if let error = reader.loadError {
            lines.append(error)
            isError = true
        } else if enabled {
            lines.append("Trackpad reader is on.")
        } else {
            lines.append("Turn Edge Controls on to use the edges. It stays off until you do.")
        }
        if let error = brightness.loadError {
            lines.append(error)
            isError = true
        }
        return (lines.joined(separator: " "), isError)
    }

    @objc private func quit() {
        reader.stop()
        hideNow()
        CursorHold.end()
        NSApp.terminate(nil)
    }
}
