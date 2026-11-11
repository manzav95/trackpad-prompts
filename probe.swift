import Foundation
import Darwin

// Reads trackpad contacts for 40 seconds and prints where they land.
//
//   swiftc probe.swift -o trackpad-probe && ./trackpad-probe
//
// MultitouchSupport is a private framework. It is loaded with dlopen, and only
// the symbols below are called. The contact callback has no context pointer, so
// the recorder is a static and the callback is a C function that reaches it.
//
// The callback runs on a framework thread. Recording happens there, under a
// lock. Hopping synchronously to the main thread can deadlock: MTDeviceStop on
// the main thread waits for this callback to return.

let fingerStride = 96
let listenSeconds: TimeInterval = 40
let edgeLow: Float = 0.06
let edgeHigh: Float = 0.94
let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

// device, finger blocks, count, timestamp, frame.
// Int is size_t on macOS. Integer and float arguments use separate registers,
// so this also matches a framework that passes the count as a 32-bit int.
typealias ContactCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int,
    Double,
    Int
) -> Void

typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias CreateDefaultFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

struct SlotStats {
    var samples = 0
    var finite = 0
    var nearUnit = 0
    var sawLow = false
    var sawHigh = false
    var minFloat = Float.greatestFiniteMagnitude
    var maxFloat = -Float.greatestFiniteMagnitude
    var minInt: Int32 = .max
    var maxInt: Int32 = .min
}

struct LiveFinger {
    var x: Float
    var y: Float
    var strips: Set<String>
    var lastPrintedX: Float
    var lastPrintedY: Float
}

struct EdgeCounts {
    var left = 0
    var right = 0
    var lowY = 0
    var highY = 0
    var middle = 0

    mutating func add(_ strips: Set<String>) {
        if strips.isEmpty {
            middle += 1
            return
        }
        if strips.contains("left") { left += 1 }
        if strips.contains("right") { right += 1 }
        if strips.contains("low-y") { lowY += 1 }
        if strips.contains("high-y") { highY += 1 }
    }
}

final class Recorder: @unchecked Sendable {
    static let shared = Recorder()

    let lock = NSLock()
    var stopping = false
    var warnedBadCount = false

    var frames = 0
    var fingerSamples = 0
    var contacts = 0
    var dumpedFrames = 0
    var badCounts = 0
    var frameFieldMatches = 0
    var frameFieldMismatches = 0
    var timestampMatches = 0
    var timestampMismatches = 0
    var framesByFingerCount: [Int: Int] = [:]
    var framesByDevice: [String: Int] = [:]

    var minX = Float.greatestFiniteMagnitude
    var maxX = -Float.greatestFiniteMagnitude
    var minY = Float.greatestFiniteMagnitude
    var maxY = -Float.greatestFiniteMagnitude

    var landings = EdgeCounts()
    var samplesInStrip = EdgeCounts()
    var live: [Int32: LiveFinger] = [:]
    var slots = [SlotStats](repeating: SlotStats(), count: fingerStride / 4)

    func ingest(
        device: UnsafeMutableRawPointer?,
        touches: UnsafeMutableRawPointer?,
        count: Int,
        timestamp: Double,
        frame: Int
    ) {
        // A wild count means the callback's integer arguments are not what we
        // assumed. Do not follow the pointer in that case.
        if count < 0 || count > 16 || (count > 0 && touches == nil) {
            lock.lock()
            badCounts += 1
            if !warnedBadCount {
                warnedBadCount = true
                writeUnlocked("ignored a frame with finger count \(count). A count outside 0...16, or a missing touch buffer, means the callback signature does not match this macOS.")
            }
            lock.unlock()
            return
        }

        let copied: Data
        if count > 0, let touches {
            copied = Data(UnsafeRawBufferPointer(start: touches, count: count * fingerStride))
        } else {
            copied = Data()
        }

        lock.lock()
        defer { lock.unlock() }
        if stopping { return }

        frames += 1
        let deviceKey = address(device)
        framesByDevice[deviceKey, default: 0] += 1
        let bucket = count >= 3 ? 3 : count
        framesByFingerCount[bucket, default: 0] += 1

        if count == 0 {
            noteLifts(seen: [])
            return
        }

        if dumpedFrames < 3 {
            dumpedFrames += 1
            writeUnlocked(dump(copied, fingers: count, timestamp: timestamp, frame: frame, device: deviceKey))
        }

        var seen = Set<Int32>()
        for index in 0..<count {
            let start = index * fingerStride
            let block = copied.subdata(in: start..<(start + fingerStride))
            observeBlock(block, callbackFrame: frame, callbackTimestamp: timestamp)

            let id = readInt32(block, 16)
            let phase = readInt32(block, 20)
            let x = readFloat(block, 32)
            let y = readFloat(block, 36)
            seen.insert(id)

            if x.isFinite {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            if y.isFinite {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }

            let here = stripNames(x: x, y: y)
            samplesInStrip.add(here)

            if var previous = live[id] {
                let moved = abs(x - previous.lastPrintedX) >= 0.05 || abs(y - previous.lastPrintedY) >= 0.05
                if moved || here != previous.strips {
                    writeUnlocked(sampleLine(
                        timestamp: timestamp,
                        frame: frame,
                        fingers: count,
                        id: id,
                        phase: phase,
                        x: x,
                        y: y,
                        strips: here,
                        event: "move"
                    ))
                    previous.lastPrintedX = x
                    previous.lastPrintedY = y
                }
                previous.x = x
                previous.y = y
                previous.strips = here
                live[id] = previous
            } else {
                contacts += 1
                landings.add(here)
                writeUnlocked(sampleLine(
                    timestamp: timestamp,
                    frame: frame,
                    fingers: count,
                    id: id,
                    phase: phase,
                    x: x,
                    y: y,
                    strips: here,
                    event: "down"
                ))
                live[id] = LiveFinger(
                    x: x,
                    y: y,
                    strips: here,
                    lastPrintedX: x,
                    lastPrintedY: y
                )
            }
        }
        noteLifts(seen: seen)
    }

    func heartbeat(elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(String(
            format: "[%4.0fs] frames=%d new-contacts=%d left=%d right=%d low-y=%d high-y=%d middle=%d",
            elapsed,
            frames,
            contacts,
            landings.left,
            landings.right,
            landings.lowY,
            landings.highY,
            landings.middle
        ))
    }

    func beginStopping() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    func frameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        lines.append("")
        lines.append("—— summary ——")
        lines.append("frames: \(frames)")
        lines.append("finger samples: \(fingerSamples)")
        lines.append("frames with 0 fingers: \(framesByFingerCount[0, default: 0])")
        lines.append("frames with 1 finger: \(framesByFingerCount[1, default: 0])")
        lines.append("frames with 2 fingers: \(framesByFingerCount[2, default: 0])")
        lines.append("frames with 3 or more: \(framesByFingerCount[3, default: 0])")
        lines.append("frames ignored (bad finger count or missing buffer): \(badCounts)")
        if framesByDevice.isEmpty {
            lines.append("devices that sent frames: none")
        } else {
            for key in framesByDevice.keys.sorted() {
                lines.append("device \(key): \(framesByDevice[key, default: 0]) frames")
            }
        }

        lines.append("int32 at offset 0 matched the callback frame: \(frameFieldMatches) yes, \(frameFieldMismatches) no")
        lines.append("double at offset 8 matched the callback time: \(timestampMatches) yes, \(timestampMismatches) no")
        lines.append(strideLine())
        lines.append(layoutLine())

        lines.append("new contacts: \(contacts)")
        lines.append("  started in the left strip (x < \(edgeLow)): \(landings.left)")
        lines.append("  started in the right strip (x > \(edgeHigh)): \(landings.right)")
        lines.append("  started in the low-y strip (y < \(edgeLow)): \(landings.lowY)")
        lines.append("  started in the high-y strip (y > \(edgeHigh)): \(landings.highY)")
        lines.append("  started in the middle: \(landings.middle)")
        lines.append("  a corner counts on both axes and is not counted as middle")
        lines.append("finger samples in the left strip: \(samplesInStrip.left)")
        lines.append("finger samples in the right strip: \(samplesInStrip.right)")
        lines.append("finger samples in the low-y strip: \(samplesInStrip.lowY)")
        lines.append("finger samples in the high-y strip: \(samplesInStrip.highY)")
        lines.append("finger samples in the middle: \(samplesInStrip.middle)")
        if minX <= maxX && minY <= maxY {
            lines.append(String(format: "x at offset 32 ranged %.4f .. %.4f", Double(minX), Double(maxX)))
            lines.append(String(format: "y at offset 36 ranged %.4f .. %.4f", Double(minY), Double(maxY)))
        } else {
            lines.append("no finite value was read at offsets 32 and 36")
        }
        lines.append("assumption while counting: x = 0 is the left edge and y = 0 is the bottom edge")
        lines.append("if a slide along the physical bottom edge was counted as high-y, y = 0 is the top on this Mac")

        lines.append("")
        lines.append("float slots, one per finger per frame")
        lines.append("off  float min    float max    in 0...1  both sides  int32 min         int32 max")
        for index in slots.indices {
            let slot = slots[index]
            guard slot.samples > 0 else { continue }
            let offset = index * 4
            let mark = (offset == 32 || offset == 36) ? "*" : " "
            let minText = slot.finite > 0 ? String(format: "%9.4f", Double(slot.minFloat)) : "          "
            let maxText = slot.finite > 0 ? String(format: "%9.4f", Double(slot.maxFloat)) : "          "
            let unit = slot.finite > 0
                ? String(format: "%5.0f%%", 100 * Double(slot.nearUnit) / Double(slot.finite))
                : "    -"
            let both = (slot.sawLow && slot.sawHigh) ? "yes" : "no "
            lines.append("\(mark)\(String(format: "%3d", offset))  \(minText)  \(maxText)  \(unit)     \(both)       \(slot.minInt)  \(slot.maxInt)")
        }
        lines.append("* marks offsets 32 and 36, the expected normalized x and y")
        return lines.joined(separator: "\n")
    }

    private func strideLine() -> String {
        let total = frameFieldMatches + frameFieldMismatches
        guard total > 0 else { return "stride: no finger samples" }
        let frameRatio = Double(frameFieldMatches) / Double(total)
        let timeTotal = timestampMatches + timestampMismatches
        let timeRatio = timeTotal > 0 ? Double(timestampMatches) / Double(timeTotal) : 0
        if frameRatio >= 0.9 && timeRatio >= 0.9 {
            return "stride: 96 bytes lines up. Offset 0 is the frame and offset 8 is the time."
        }
        return "stride: 96 bytes does not line up with the callback frame and time. Treat the position columns as unverified."
    }

    private func layoutLine() -> String {
        func kind(_ offset: Int) -> String {
            let slot = slots[offset / 4]
            if slot.finite < 10 { return "too-few-samples" }
            let mostlyUnit = Double(slot.nearUnit) / Double(slot.finite) >= 0.85
            if !mostlyUnit { return "not-unit" }
            if slot.sawLow && slot.sawHigh { return "axis" }
            return "unit-but-did-not-travel"
        }

        let xKind = kind(32)
        let yKind = kind(36)
        var others: [Int] = []
        for index in slots.indices {
            let offset = index * 4
            if offset == 32 || offset == 36 { continue }
            if kind(offset) == "axis" { others.append(offset) }
        }
        let extra = others.isEmpty
            ? "No other slot travelled across 0...1."
            : "Other slots that also travelled across 0...1: \(others.map(String.init).joined(separator: ", "))."

        if xKind == "axis" && yKind == "axis" {
            return "layout: floats at offsets 32 and 36 both behaved like a normalized axis. \(extra)"
        }
        if xKind == "too-few-samples" || yKind == "too-few-samples" {
            return "layout: not enough samples at offsets 32 and 36 to judge. \(extra)"
        }
        if xKind == "unit-but-did-not-travel" || yKind == "unit-but-did-not-travel" {
            return "layout: inconclusive. Offsets 32 and 36 stay near 0...1 but did not travel from one side of the pad to the other. \(extra)"
        }
        return "layout: offsets 32 and 36 did not both behave like a 0...1 position (x=\(xKind), y=\(yKind)). \(extra)"
    }

    private func observeBlock(_ block: Data, callbackFrame: Int, callbackTimestamp: Double) {
        fingerSamples += 1
        if Int(readInt32(block, 0)) == callbackFrame {
            frameFieldMatches += 1
        } else {
            frameFieldMismatches += 1
        }
        let headerTime = readDouble(block, 8)
        if headerTime.isFinite && abs(headerTime - callbackTimestamp) < 0.001 {
            timestampMatches += 1
        } else {
            timestampMismatches += 1
        }

        for index in slots.indices {
            let offset = index * 4
            let value = readFloat(block, offset)
            var slot = slots[index]
            slot.samples += 1
            if value.isFinite {
                slot.finite += 1
                slot.minFloat = min(slot.minFloat, value)
                slot.maxFloat = max(slot.maxFloat, value)
                if value >= -0.05 && value <= 1.05 { slot.nearUnit += 1 }
                if value < 0.15 { slot.sawLow = true }
                if value > 0.85 { slot.sawHigh = true }
            }
            let bits = readInt32(block, offset)
            slot.minInt = min(slot.minInt, bits)
            slot.maxInt = max(slot.maxInt, bits)
            slots[index] = slot
        }
    }

    private func noteLifts(seen: Set<Int32>) {
        let gone = live.keys.filter { !seen.contains($0) }
        for id in gone {
            let finger = live[id]!
            writeUnlocked(String(format: "up id=%d last x=%.4f y=%.4f", id, Double(finger.x), Double(finger.y)))
            live.removeValue(forKey: id)
        }
    }

    private func dump(_ data: Data, fingers: Int, timestamp: Double, frame: Int, device: String) -> String {
        var lines: [String] = []
        lines.append(String(format: "raw frame=%d t=%.4f device=%@ fingers=%d stride=%d", frame, timestamp, device, fingers, fingerStride))
        let shown = min(fingers, 4)
        for index in 0..<shown {
            let start = index * fingerStride
            let block = data.subdata(in: start..<(start + fingerStride))
            lines.append("  finger \(index)")
            var offset = 0
            while offset < fingerStride {
                let end = min(offset + 16, fingerStride)
                let hex = block[offset..<end].map { String(format: "%02x", UInt32($0)) }.joined(separator: " ")
                lines.append(String(format: "    %04d  %@", offset, hex))
                offset = end
            }
            for field in stride(from: 0, to: fingerStride, by: 4) {
                let asInt = readInt32(block, field)
                let asFloat = readFloat(block, field)
                let note: String
                if field == 32 {
                    note = "  expected normalized x"
                } else if field == 36 {
                    note = "  expected normalized y"
                } else {
                    note = ""
                }
                lines.append(String(format: "    +%-3d int=%-12d float=%-14.6f%@", field, asInt, Double(asFloat), note))
            }
        }
        if fingers > shown {
            lines.append("  \(fingers - shown) more fingers in this frame were counted but not dumped")
        }
        return lines.joined(separator: "\n")
    }

    private func sampleLine(
        timestamp: Double,
        frame: Int,
        fingers: Int,
        id: Int32,
        phase: Int32,
        x: Float,
        y: Float,
        strips: Set<String>,
        event: String
    ) -> String {
        let whereText = strips.isEmpty ? "middle" : strips.sorted().joined(separator: "+")
        return String(
            format: "t=%.3f frame=%d fingers=%d %@ id=%d phase=%d(%@) x=%.4f y=%.4f %@",
            timestamp,
            frame,
            fingers,
            event,
            id,
            phase,
            phaseName(phase),
            Double(x),
            Double(y),
            whereText
        )
    }

    private func writeUnlocked(_ line: String) {
        fputs(line + "\n", stdout)
        fflush(stdout)
    }
}

// Kept alive for the whole process. Device pointers from MTDeviceCreateList
// are owned by this array.
var retainedDeviceList: CFArray?

let contactFrameCallback: ContactCallback = { device, touches, count, timestamp, frame in
    Recorder.shared.ingest(
        device: device,
        touches: touches,
        count: count,
        timestamp: timestamp,
        frame: frame
    )
}

func stripNames(x: Float, y: Float) -> Set<String> {
    var names = Set<String>()
    if x < edgeLow { names.insert("left") }
    if x > edgeHigh { names.insert("right") }
    if y < edgeLow { names.insert("low-y") }
    if y > edgeHigh { names.insert("high-y") }
    return names
}

func phaseName(_ value: Int32) -> String {
    switch value {
    case 0: return "not-tracking"
    case 1: return "start-in-range"
    case 2: return "hover"
    case 3: return "make-touch"
    case 4: return "touching"
    case 5: return "break-touch"
    case 6: return "linger"
    case 7: return "out-of-range"
    default: return "unlisted"
    }
}

func address(_ pointer: UnsafeMutableRawPointer?) -> String {
    guard let pointer else { return "nil" }
    return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
}

// Copy into an aligned 8-byte slot. `load(as:)` on the Data bytes would trap
// when those bytes are only 1-byte aligned.
func readNumber<T>(_ data: Data, _ offset: Int) -> T {
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

func readFloat(_ data: Data, _ offset: Int) -> Float {
    readNumber(data, offset)
}

func readInt32(_ data: Data, _ offset: Int) -> Int32 {
    readNumber(data, offset)
}

func readDouble(_ data: Data, _ offset: Int) -> Double {
    readNumber(data, offset)
}

func emit(_ line: String) {
    fputs(line + "\n", stdout)
    fflush(stdout)
}

func copyCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "unknown error" }
    return String(cString: pointer)
}

func poke<T>(_ value: T, into data: inout Data, at offset: Int) {
    var stored = value
    let size = MemoryLayout<T>.size
    withUnsafeBytes(of: &stored) { source in
        data.replaceSubrange(offset..<(offset + size), with: Array(source))
    }
}

func selfCheck() {
    var data = Data(count: fingerStride)
    poke(Int32(42), into: &data, at: 0)
    poke(Double(1.5), into: &data, at: 8)
    poke(Float(0.25), into: &data, at: 32)
    poke(Float(0.75), into: &data, at: 36)
    let header = readInt32(data, 0)
    let time = readDouble(data, 8)
    let x = readFloat(data, 32)
    let y = readFloat(data, 36)
    if header != 42 || time != 1.5 || x != 0.25 || y != 0.75 {
        emit("self-check failed: reader returned frame=\(header) time=\(time) x=\(x) y=\(y)")
        exit(1)
    }

    let cases: [(Float, Float, Set<String>)] = [
        (0.01, 0.50, ["left"]),
        (0.99, 0.50, ["right"]),
        (0.50, 0.01, ["low-y"]),
        (0.50, 0.99, ["high-y"]),
        (0.50, 0.50, []),
        (0.01, 0.01, ["left", "low-y"]),
    ]
    for item in cases where stripNames(x: item.0, y: item.1) != item.2 {
        emit("self-check failed: strips for x=\(item.0) y=\(item.1)")
        exit(1)
    }
    emit("self-check: the byte reader and the 6% strips passed. This does not check the trackpad.")
}

func permissionReport() -> String {
    var lines: [String] = []
    lines.append("Permission requests made by this probe: none.")
    lines.append("It does not call IOHIDRequestAccess, AXIsProcessTrustedWithOptions, or CGEventTapCreate.")
    lines.append("If a dialog appears on screen, macOS raised it. This program cannot see dialogs.")

    if let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
       let symbol = dlsym(iokit, "IOHIDCheckAccess") {
        typealias CheckFn = @convention(c) (UInt32) -> UInt32
        let check = unsafeBitCast(symbol, to: CheckFn.self)
        let status = check(1) // kIOHIDRequestTypeListenEvent
        let name: String
        switch status {
        case 0: name = "granted"
        case 1: name = "denied"
        case 2: name = "unknown (not yet decided)"
        default: name = "code \(status)"
        }
        lines.append("IOHIDCheckAccess(ListenEvent) = \(name). This check does not prompt.")
    } else {
        lines.append("IOHIDCheckAccess is not available. No access was requested.")
    }

    if let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
       let symbol = dlsym(services, "AXIsProcessTrusted") {
        typealias TrustFn = @convention(c) () -> UInt8
        let trusted = unsafeBitCast(symbol, to: TrustFn.self)()
        lines.append("AXIsProcessTrusted = \(trusted != 0). This check does not prompt.")
    } else {
        lines.append("AXIsProcessTrusted is not available. No access was requested.")
    }
    return lines.joined(separator: "\n")
}

func openDevices(handle: UnsafeMutableRawPointer) -> [UnsafeMutableRawPointer]? {
    var found: [UnsafeMutableRawPointer] = []

    if let symbol = dlsym(handle, "MTDeviceCreateList") {
        let createList = unsafeBitCast(symbol, to: CreateListFn.self)
        if let rawList = createList() {
            let list = Unmanaged<CFArray>.fromOpaque(rawList).takeRetainedValue()
            retainedDeviceList = list
            let count = CFArrayGetCount(list)
            emit("MTDeviceCreateList returned \(count) device(s)")
            for index in 0..<count {
                guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
                found.append(UnsafeMutableRawPointer(mutating: pointer))
            }
        } else {
            emit("MTDeviceCreateList returned NULL")
        }
    } else {
        emit("MTDeviceCreateList is missing")
    }

    if found.isEmpty, let symbol = dlsym(handle, "MTDeviceCreateDefault") {
        let createDefault = unsafeBitCast(symbol, to: CreateDefaultFn.self)
        if let device = createDefault() {
            emit("MTDeviceCreateDefault returned a device")
            found.append(device)
        } else {
            emit("MTDeviceCreateDefault returned NULL")
        }
    }

    return found.isEmpty ? nil : found
}

private let finishLock = NSLock()
private var didFinish = false

func shutdown(devices: [UnsafeMutableRawPointer], stop: StopFn) -> Never {
    finishLock.lock()
    if didFinish {
        finishLock.unlock()
        exit(1)
    }
    didFinish = true
    finishLock.unlock()

    Recorder.shared.beginStopping()
    for device in devices {
        _ = stop(device)
    }
    emit(Recorder.shared.summary())
    emit("")
    emit("After listening:")
    emit(permissionReport())
    if Recorder.shared.frameCount() == 0 {
        emit("The framework loaded, but no touch frames arrived.")
        exit(2)
    }
    exit(0)
}

setvbuf(stdout, nil, _IONBF, 0)
emit("Trackpad edge probe")
selfCheck()
emit("Loading \(frameworkPath)")
emit(permissionReport())
emit("")

guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
    emit("MultitouchSupport failed to load: \(copyCString(dlerror()))")
    emit("No touches were read.")
    exit(1)
}

guard let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
      let startSymbol = dlsym(handle, "MTDeviceStart"),
      let stopSymbol = dlsym(handle, "MTDeviceStop") else {
    emit("Required symbol missing: MTRegisterContactFrameCallback, MTDeviceStart, or MTDeviceStop.")
    emit("No touches were read.")
    exit(1)
}

guard let devices = openDevices(handle: handle) else {
    emit("No multitouch device was opened. No touches were read.")
    exit(1)
}

let register = unsafeBitCast(registerSymbol, to: RegisterFn.self)
let start = unsafeBitCast(startSymbol, to: StartFn.self)
let stop = unsafeBitCast(stopSymbol, to: StopFn.self)

for device in devices {
    register(device, contactFrameCallback)
    let status = start(device, 0)
    emit("started device \(address(device)), MTDeviceStart status \(status)")
}

emit("")
emit("Listening for \(Int(listenSeconds)) seconds. The pointer will keep moving.")
emit("Rest one finger in the centre, then slide along the left edge, the right edge, and the bottom edge.")
emit("Then put two fingers down and lift them both.")
emit("A line is printed when a finger goes down, comes up, changes strip, or moves about 5% of the pad.")
emit("Ctrl-C prints the summary early.")
emit("")

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    emit("")
    emit("Interrupted.")
    shutdown(devices: devices, stop: stop)
}
sigint.resume()

let startedAt = Date()
var nextBeat = startedAt.addingTimeInterval(5)
let deadline = startedAt.addingTimeInterval(listenSeconds)
while Date() < deadline {
    let limit = min(nextBeat, deadline)
    RunLoop.current.run(mode: .default, before: limit)
    if Date() >= nextBeat && Date() < deadline {
        Recorder.shared.heartbeat(elapsed: Date().timeIntervalSince(startedAt))
        nextBeat = Date().addingTimeInterval(5)
    }
}

shutdown(devices: devices, stop: stop)
