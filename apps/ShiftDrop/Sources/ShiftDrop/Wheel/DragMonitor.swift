import AppKit

/// Notices when the user drags files anywhere on the Mac and presses Shift.
///
/// Needs no Accessibility or Input Monitoring permission: a global mouse-down monitor starts a short
/// polling loop that reads the shared drag pasteboard and the hardware modifier/button state,
/// and stops as soon as the mouse button is released.
@MainActor
final class DragMonitor: NSObject {
    var onShift: ((DragPayload, CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var isEnabled = true

    private let pasteboard = NSPasteboard(name: .drag)
    private var monitor: Any?
    private var timer: Timer?
    private var baselineChangeCount = 0
    private var lastChangeCount = 0
    private var payload: DragPayload?
    private var shiftWasDown = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.mouseWentDown() }
        }
    }

    private func mouseWentDown() {
        guard isEnabled else { return }
        baselineChangeCount = pasteboard.changeCount
        lastChangeCount = baselineChangeCount
        payload = nil
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finish()
            return
        }
        let changeCount = pasteboard.changeCount
        if changeCount != lastChangeCount {
            lastChangeCount = changeCount
            payload = DragPasteboard.payload(from: pasteboard)
        }
        let shift = NSEvent.modifierFlags.contains(.shift)
        defer { shiftWasDown = shift }
        guard shift, !shiftWasDown, changeCount != baselineChangeCount, let payload,
              payload.kind != .unsupported else { return }
        onShift?(payload, NSEvent.mouseLocation)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if payload != nil { onDragEnded?() }
        payload = nil
    }
}
