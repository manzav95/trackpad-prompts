import Darwin
import Foundation
import EdgeGesture

/// Reads the trackpad through MultitouchSupport, loaded at runtime.
/// The callback has no context pointer, so the reader lives in `TouchReader.shared`
/// and the callback hops to the main queue. A synchronous hop can deadlock inside
/// MTDeviceStop, so the hop is asynchronous.
final class TouchReader {
    static let shared = TouchReader()

    var onFrame: ([Finger]) -> Void = { _ in }
    private(set) var loadError: String?

    private var devices: [UnsafeMutableRawPointer] = []
    private var stopDevice: StopFn?
    private var retainedList: CFArray?
    private var running = false

    func start() -> String? {
        if running { return loadError }
        loadError = nil

        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            loadError = "MultitouchSupport did not load. The trackpad cannot be read."
            return loadError
        }
        guard let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSymbol = dlsym(handle, "MTDeviceStart"),
              let stopSymbol = dlsym(handle, "MTDeviceStop"),
              let listSymbol = dlsym(handle, "MTDeviceCreateList") else {
            loadError = "MultitouchSupport is missing the touch symbols. The trackpad cannot be read."
            return loadError
        }

        let createList = unsafeBitCast(listSymbol, to: CreateListFn.self)
        guard let rawList = createList() else {
            loadError = "MultitouchSupport reported no trackpad."
            return loadError
        }
        let list = Unmanaged<CFArray>.fromOpaque(rawList).takeRetainedValue()
        retainedList = list
        let count = CFArrayGetCount(list)
        guard count > 0 else {
            loadError = "MultitouchSupport reported no trackpad."
            return loadError
        }

        let register = unsafeBitCast(registerSymbol, to: RegisterFn.self)
        let start = unsafeBitCast(startSymbol, to: StartFn.self)
        stopDevice = unsafeBitCast(stopSymbol, to: StopFn.self)

        var opened: [UnsafeMutableRawPointer] = []
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: pointer)
            register(device, touchCallback)
            _ = start(device, 0)
            opened.append(device)
        }
        guard !opened.isEmpty else {
            loadError = "MultitouchSupport reported no trackpad."
            return loadError
        }
        devices = opened
        running = true
        return nil
    }

    func stop() {
        running = false
        for device in devices {
            _ = stopDevice?(device)
        }
        devices = []
        stopDevice = nil
        retainedList = nil
    }

    fileprivate func deliver(count: Int, data: Data) {
        guard running else { return }
        if count == 0 {
            onFrame([])
            return
        }
        var fingers: [Finger] = []
        for index in 0..<count {
            let start = index * 96
            let end = start + 96
            guard end <= data.count, let finger = Finger(block: data.subdata(in: start..<end)) else { continue }
            fingers.append(finger)
        }
        onFrame(fingers)
    }
}

private let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

private typealias ContactCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int,
    Double,
    Int
) -> Void
private typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

private let touchCallback: ContactCallback = { _, touches, count, _, _ in
    guard count >= 0, count <= 16 else { return }
    let copied: Data
    if count > 0, let touches {
        copied = Data(UnsafeRawBufferPointer(start: touches, count: count * 96))
    } else {
        copied = Data()
    }
    let fingerCount = count
    DispatchQueue.main.async {
        TouchReader.shared.deliver(count: fingerCount, data: copied)
    }
}
