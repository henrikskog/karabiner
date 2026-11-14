import Cocoa
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)

func setting(_ name: String, _ fallback: Double) -> Double {
    ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
}

let trackpadSpeed = setting("CMDZOOM_TRACKPAD_SPEED", 0.005)
let wheelSpeed = setting("CMDZOOM_WHEEL_SPEED", 0.08)
let wheelSmoothing = 0.25
let idleEnd = 0.15
let maxZoomSteps = 24
let maxZoomStep = 0.3
let topButtonCID = 0x00FD
let forwardButton: Int64 = 4
let syntheticTag: Int64 = 0x636D647A

let fieldType = CGEventField(rawValue: 55)!
let fieldGestureHIDType = CGEventField(rawValue: 110)!
let fieldZoomValue = CGEventField(rawValue: 113)!
let fieldGesturePhase = CGEventField(rawValue: 132)!

enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

var active = false
var pending = 0.0
var endWork: DispatchWorkItem?
var tap: CFMachPort?
var zoomedIn = false
var forwardHeld = false
var forwardUsed = false

func magnifyEvent(_ phase: Phase, _ magnification: Double) -> CGEvent {
    let e = CGEvent(source: nil)!
    e.setIntegerValueField(fieldType, value: 29)
    e.setIntegerValueField(fieldGestureHIDType, value: 8)
    e.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    e.setDoubleValueField(fieldZoomValue, value: magnification)
    return e
}

func postMagnify(_ phase: Phase, _ magnification: Double) {
    magnifyEvent(phase, magnification).post(tap: .cghidEventTap)
}

func zoom(_ amount: Double) {
    if !active {
        postMagnify(.began, 0)
        active = true
    }
    postMagnify(.changed, amount)
}

func finish() {
    endWork?.cancel()
    pending = 0
    if active {
        postMagnify(.ended, 0)
        active = false
    }
}

func scheduleEnd() {
    endWork?.cancel()
    let work = DispatchWorkItem { if pending == 0 { finish() } }
    endWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + idleEnd, execute: work)
}

func maxZoom() {
    finish()
    let step = zoomedIn ? -maxZoomStep : maxZoomStep
    zoomedIn.toggle()
    var n = 0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
        zoom(step)
        n += 1
        if n == maxZoomSteps {
            t.invalidate()
            finish()
        }
    }
}

let smoother = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
    guard pending != 0 else { return }
    var step = pending * wheelSmoothing
    if abs(pending) < 0.002 { step = pending }
    pending -= step
    zoom(step)
    if pending == 0 { scheduleEnd() }
}
RunLoop.main.add(smoother, forMode: .common)

func onScroll(_ e: CGEvent) -> Bool {
    let f = e.flags
    guard f.contains(.maskCommand),
          !f.contains(.maskAlternate), !f.contains(.maskControl), !f.contains(.maskShift)
    else { return false }

    if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return true }

    if e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
        let delta = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if delta != 0 { zoom(delta * trackpadSpeed) }
        if e.getIntegerValueField(.scrollWheelEventScrollPhase) == 4 { finish() } else { scheduleEnd() }
    } else {
        pending += Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * wheelSpeed
    }
    return true
}

func postForwardClick(at p: CGPoint) {
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: forwardButton)
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }
}

func onForward(_ type: CGEventType, _ e: CGEvent) {
    if type == .otherMouseDown {
        forwardHeld = true
        forwardUsed = false
    } else {
        forwardHeld = false
        if !forwardUsed { postForwardClick(at: e.location) }
        if pending == 0 { finish() }
    }
}

func addCmdIfForwardHeld(_ e: CGEvent) {
    guard forwardHeld else { return }
    forwardUsed = true
    e.flags = e.flags.union(.maskCommand)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .otherMouseDown, .otherMouseUp:
        if event.getIntegerValueField(.mouseEventButtonNumber) == forwardButton,
           event.getIntegerValueField(.eventSourceUserData) != syntheticTag {
            onForward(type, event)
            return nil
        }
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged:
        addCmdIfForwardHeld(event)
    case .scrollWheel:
        addCmdIfForwardHeld(event)
        if onScroll(event) { return nil }
    case .flagsChanged:
        if !event.flags.contains(.maskCommand) && pending == 0 { finish() }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

var hidReplies: [[UInt8]] = []
var reprogIndex: UInt8 = 0
var topDown = false
let hidBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

func onReport(_ report: [UInt8]) {
    let b = report.first == 0x11 ? Array(report.dropFirst()) : report
    guard b.count >= 19 else { return }
    if reprogIndex != 0 && b[1] == reprogIndex && b[2] == 0x00 {
        let cids = stride(from: 3, to: 11, by: 2).map { Int(b[$0]) << 8 | Int(b[$0 + 1]) }
        let down = cids.contains(topButtonCID)
        if down && !topDown { DispatchQueue.main.async { maxZoom() } }
        topDown = down
    } else {
        hidReplies.append(b)
    }
}

func hidCall(_ dev: IOHIDDevice, _ feature: UInt8, _ fn: UInt8, _ params: [UInt8]) -> [UInt8]? {
    var msg: [UInt8] = [0x11, 0xFF, feature, fn << 4 | 0x0A] + params
    msg += Array(repeating: 0, count: 20 - msg.count)
    hidReplies.removeAll()
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
    guard r == kIOReturnSuccess else {
        print("cmdzoom: hid++ send failed \(r)")
        return nil
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.02, true)
        if let reply = hidReplies.first(where: { $0[1] == feature && $0[2] == msg[3] }) { return Array(reply[3...]) }
        if let err = hidReplies.first(where: { $0[1] == 0xFF }) {
            print("cmdzoom: hid++ error \(hex(err))")
            return nil
        }
    }
    print("cmdzoom: hid++ timeout feature=\(feature) fn=\(fn)")
    return nil
}

func setupMouse(_ dev: IOHIDDevice) {
    topDown = false
    IOHIDDeviceRegisterInputReportCallback(dev, hidBuffer, 64, { _, _, _, _, _, report, len in
        onReport(Array(UnsafeBufferPointer(start: report, count: len)))
    }, nil)
    guard let f = hidCall(dev, 0x00, 0, [0x1B, 0x04]), f[0] != 0 else {
        print("cmdzoom: mouse has no reprogrammable controls")
        return
    }
    reprogIndex = f[0]
    guard let count = hidCall(dev, reprogIndex, 0, [])?[0] else { return }
    var found = false
    for i in 0..<count {
        guard let r = hidCall(dev, reprogIndex, 1, [i]) else { continue }
        let cid = Int(r[0]) << 8 | Int(r[1])
        print(String(format: "cmdzoom: control cid=0x%04x flags=0x%02x", cid, r[4]))
        if cid == topButtonCID { found = true }
    }
    let cid = [UInt8(topButtonCID >> 8), UInt8(topButtonCID & 0xFF)]
    guard found, hidCall(dev, reprogIndex, 3, cid + [0x03, 0, 0]) != nil else {
        print("cmdzoom: top button not diverted")
        return
    }
    print("cmdzoom: top button diverted")
}

let hidThread = Thread {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x46D, kIOHIDProductIDKey: 0xB020] as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in setupMouse(dev) }, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    print("cmdzoom: hid open \(IOHIDManagerOpen(mgr, 0))")
    CFRunLoopRun()
}

if CommandLine.arguments.contains("--selftest") {
    for (phase, mag) in [(Phase.began, 0.0), (.changed, 0.05), (.ended, 0.0)] {
        let ns = NSEvent(cgEvent: magnifyEvent(phase, mag))!
        print(ns.type == .magnify, ns.magnification, ns.phase.rawValue)
    }
    exit(0)
}

let axOK = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
let hidOK = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
print("cmdzoom: starting accessibility=\(axOK) inputMonitoring=\(hidOK) trackpadSpeed=\(trackpadSpeed) wheelSpeed=\(wheelSpeed)")

if !axOK || !hidOK {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        if AXIsProcessTrusted() && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { exit(0) }
    }
}

if axOK {
    let types: [CGEventType] = [.scrollWheel, .flagsChanged, .otherMouseDown, .otherMouseUp,
                                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                .rightMouseDown, .rightMouseUp, .rightMouseDragged]
    let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
    if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) {
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        print("cmdzoom: scroll tap running")
    } else {
        print("cmdzoom: could not create event tap")
    }
}

if hidOK { hidThread.start() }

CFRunLoopRun()
