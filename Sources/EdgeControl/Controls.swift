import AppKit
import CoreAudio
import Darwin
import Foundation

final class VolumeControl {
    func current() -> Float {
        guard let device = defaultOutput() else { return 0.5 }
        return read(device) ?? 0.5
    }

    func set(_ level: Float) {
        guard let device = defaultOutput() else { return }
        var value = min(1, max(0, level))
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress()
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if value > 0 {
            var mute: UInt32 = 0
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &mute)
        }
    }

    private func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    private func read(_ device: AudioDeviceID) -> Float? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress()
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// 'vmvc'. The SDK name for this selector is not visible to this Swift.
private let virtualMainVolume = AudioObjectPropertySelector(0x766D7663)

final class BrightnessControl {
    private(set) var loadError: String?
    private let getBrightness: GetFn?
    private let setBrightness: SetFn?
    private let display: UInt32

    init() {
        display = CGMainDisplayID()
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ),
            let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
            let setSymbol = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            getBrightness = nil
            setBrightness = nil
            loadError = "DisplayServices did not load. Brightness is unavailable. Volume still works."
            return
        }
        getBrightness = unsafeBitCast(getSymbol, to: GetFn.self)
        setBrightness = unsafeBitCast(setSymbol, to: SetFn.self)
    }

    func current() -> Float {
        guard let getBrightness else { return 0.5 }
        var value: Float = 0
        let status = getBrightness(display, &value)
        if status != 0 {
            let fallback = getBrightness(0, &value)
            if fallback != 0 { return 0.5 }
        }
        return value
    }

    func set(_ level: Float) {
        guard let setBrightness else { return }
        let value = min(1, max(0, level))
        if setBrightness(display, value) != 0 {
            _ = setBrightness(0, value)
        }
    }
}

private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

enum TrackSkip {
    static func send(next: Bool) {
        guard let name = playerName() else { return }
        let command = next ? "next track" : "previous track"
        let source = "tell application \"\(name)\" to \(command)"
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    /// Spotify or Music, whichever is open. If both are open, the one in front.
    private static func playerName() -> String? {
        let spotify = running("com.spotify.client")
        let music = running("com.apple.Music")
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == "com.spotify.client", spotify { return "Spotify" }
        if front == "com.apple.Music", music { return "Music" }
        if spotify { return "Spotify" }
        if music { return "Music" }
        return nil
    }

    private static func running(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
