import AppKit
import YabaibyeCore

struct TileDragContext {
    let space: UInt64
    let source: ManagedWindow
    let candidates: [ManagedWindow]
}

/// Observes native window movement; never intercepts or synthesizes mouse events.
@MainActor final class DragTiling {
    var capture: ((CGPoint) -> TileDragContext?)?
    var validate: ((TileDragContext) -> Bool)?
    var commit: ((TileDragContext, String?, DropZone?) -> Void)?
    private var timer: Timer?
    private var wasDown = false
    private var ticks = 0
    private var startPoint = CGPoint.zero
    private var context: TileDragContext?
    private var moved = false
    private var cancelled = false
    private var target: String?
    private var zone: DropZone?
    private let overlay = DropOverlay()
    var isTracking: Bool { wasDown }

    func start() {
        stop()
        // If enabled while a mouse button is held, wait for a fresh gesture.
        wasDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        ticks = -1
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil; cancel(); wasDown = false
    }
    private func cancel() {
        context = nil; moved = false; cancelled = false; target = nil; zone = nil; overlay.hide()
    }
    private func poll() {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let point = CGEvent(source: nil)?.location ?? .zero
        if down && !wasDown { startPoint = point; ticks = 0; cancel() }
        if down && CGEventSource.keyState(.combinedSessionState, key: 53) {
            cancelled = true; target = nil; zone = nil; overlay.hide(); wasDown = down; return
        }
        if down {
            if ticks >= 0 { ticks += 1 }
            // Let focus settle, then capture only a currently tiled source.
            if ticks == 2 { context = capture?(startPoint) }
            if let context {
                guard let frame = AX.frame(context.source.element) else { cancel(); wasDown = down; return }
                let initial = context.source.frame
                // Resizing or selecting content must not initiate a tile drop.
                if abs(frame.width - initial.width) > 5 || abs(frame.height - initial.height) > 5 {
                    cancel(); wasDown = down; return
                }
                if abs(frame.minX - initial.minX) > 5 || abs(frame.minY - initial.minY) > 5 { moved = true }
                if moved && !cancelled {
                    if ticks % 5 == 0, validate?(context) != true { cancel(); wasDown = down; return }
                    updateTarget(context, at: point)
                }
            }
        } else if wasDown {
            if let context, moved, validate?(context) == true {
                if !cancelled { updateTarget(context, at: point) }
                let target = self.target, zone = self.zone
                cancel(); wasDown = false
                commit?(context, target, zone)
                return
            }
            cancel()
        }
        wasDown = down
    }
    private func updateTarget(_ context: TileDragContext, at point: CGPoint) {
        // These are the stationary target frames captured before the source occludes them.
        guard let candidate = context.candidates.first(where: { $0.id != context.source.id && $0.frame.contains(point) }),
              let zone = DropZone.hit(at: point, in: candidate.frame) else {
            target = nil; self.zone = nil; overlay.hide(); return
        }
        target = candidate.identity; self.zone = zone
        overlay.show(axFrame: zone.preview(in: candidate.frame))
    }
}

@MainActor final class DropOverlay {
    private let panel: NSPanel
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = HatchView()
        panel.isReleasedWhenClosed = false
    }
    func show(axFrame: CGRect) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: axFrame.minX, y: top - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

private final class HatchView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(calibratedRed: 0.70, green: 0.36, blue: 0.39, alpha: 1)
        color.withAlphaComponent(0.17).setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        color.withAlphaComponent(0.65).setStroke()
        let lines = NSBezierPath(); lines.lineWidth = 1.4
        lines.setLineDash([6, 5], count: 2, phase: 0)
        for x in stride(from: -bounds.height, through: bounds.width, by: 16) {
            lines.move(to: CGPoint(x: x, y: 0)); lines.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
        }
        lines.stroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        border.lineWidth = 2; border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
