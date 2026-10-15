import AppKit
import ApplicationServices

/// Observe mouse events before AppKit dispatch: an empty system menu bar need
/// not send an NSEvent to any application. This tap never consumes an event.
@MainActor
final class MenuBarClickMonitor {
    struct Click {
        let point: CGPoint // Quartz coordinates, origin at the primary top-left.
        let type: CGEventType
        let time: TimeInterval
        let hasModifiers: Bool
    }
    private(set) static var isListening = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var onClick: ((Click) -> Void)?

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
        stopFallback()
    }

    private func stopTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        Self.isListening = globalMonitor != nil
    }

    private func refresh() {
        guard MenuBarHitTest.isAuthorized else { stopTap(); stopFallback(); return }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            if CGEvent.tapIsEnabled(tap: tap) {
                stopFallback()
                Self.isListening = true
                return
            }
            stopTap()
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<MenuBarClickMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.refresh()
                } else {
                    monitor.onClick?(MenuBarClickMonitor.click(from: event, type: type))
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            startFallback()
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.isListening = CGEvent.tapIsEnabled(tap: tap)
        if Self.isListening { stopFallback(); Self.isListening = true }
        else { stopTap(); startFallback() }
    }

    /// AppKit can observe mouse clicks if the session event tap is unavailable.
    /// The same AX hit-test still rejects actual menu and status items.
    private func startFallback() {
        guard globalMonitor == nil else { Self.isListening = true; return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.forwardFallback(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.forwardFallback(event) }
            return event
        }
        Self.isListening = globalMonitor != nil
    }

    private func stopFallback() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        Self.isListening = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    private func forwardFallback(_ event: NSEvent) {
        guard tap == nil, let cgEvent = event.cgEvent else { return }
        onClick?(Self.click(from: cgEvent, type: cgEvent.type))
    }

    static func click(from event: CGEvent, type: CGEventType) -> Click {
        Click(point: event.location, type: type, time: Double(event.timestamp) / 1_000_000_000,
              hasModifiers: !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
    }
}
