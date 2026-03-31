// FloatTimer.swift
// BUILD: swiftc FloatTimer.swift -o FloatTimer
// RUN:   ./FloatTimer

import Cocoa
import AVFoundation

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - KeyablePanel (borderless panels refuse key status by default)
// ─────────────────────────────────────────────────────────────────────────────

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppDelegate
// ─────────────────────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: KeyablePanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Visible UI is 240×110; pad with an invisible grab zone on all sides
        let pad: CGFloat = 30
        let visW: CGFloat = 240, visH: CGFloat = 110
        let size = NSSize(width: visW + pad * 2, height: visH + pad * 2)
        let screen = NSScreen.main!.frame
        let origin = NSPoint(x: (screen.width - size.width) / 2,
                             y: screen.height * 0.75)

        // NSPanel with .nonactivatingPanel is draggable across the whole frame
        // even when fully transparent, and doesn't steal app focus
        panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level              = .floating
        panel.backgroundColor    = .clear
        panel.isOpaque           = false
        panel.hasShadow          = false
        panel.isMovableByWindowBackground = false  // we handle dragging manually
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        let view = TimerView(frame: NSRect(origin: .zero, size: size), pad: pad)
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TimerView
// ─────────────────────────────────────────────────────────────────────────────

class TimerView: NSView {

    enum Mode { case stopwatch, countdown }
    var mode      : Mode = .countdown
    var running          = false
    var elapsed          = 0.0
    var countdown        = 300.0
    var remaining        = 300.0
    var lastTick         = Date()
    var ticker   : Timer?

    // Hover
    var isHovered    = false
    var hoverAlpha   : CGFloat = 0.0
    var fadeAnim     : Timer?
    var trackArea    : NSTrackingArea?

    // Edit
    var isEditing    = false
    var editString   = ""

    // Drag
    var dragOrigin   : NSPoint?  // window origin when drag started
    var dragMouse    : NSPoint?  // mouse screen position when drag started

    // Done state (flash until reset)
    var isDone       = false
    var flashOn      = false
    var flashTimer   : Timer?

    // Audio
    var audioPlayer  : AVAudioPlayer?

    // Visible UI dimensions (the actual timer widget)
    let W: CGFloat = 240
    let H: CGFloat = 110
    // Invisible grab zone padding around the visible UI
    let pad: CGFloat

    var controlsLayer : NSView!
    var modeLabel     : NSTextField!
    var timeLabel     : NSTextField!
    var playBtn       : NSTextField!
    var resetBtn      : NSTextField!
    var modeBtn       : NSTextField!
    var closeBtn      : NSTextField!

    var allBtns: [NSTextField] { [playBtn, resetBtn, modeBtn, closeBtn].compactMap { $0 } }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Force hit-testing to always return this view for any point within bounds.
    // Without this, macOS ignores clicks on transparent/low-alpha pixels and
    // events never reach mouseDown/mouseDragged at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func roboto(_ size: CGFloat) -> NSFont {
        for name in ["RobotoMono-Thin","RobotoMono-Light","Roboto Mono Thin","Roboto Mono"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .thin)
    }

    init(frame: NSRect, pad: CGFloat) {
        self.pad = pad
        super.init(frame: frame)
        buildUI()
        rebuildTracking()
        prepareChime()
    }
    required init?(coder: NSCoder) { fatalError() }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Chime (synthesized sine burst)
    // ─────────────────────────────────────────────────────────────────────────

    func prepareChime() {
        // Generate a short chime: three sine tones (C5, E5, G5) fading out
        let sampleRate: Double = 44100
        let duration: Double   = 1.2
        let numSamples = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: numSamples)

        let tones: [(freq: Double, start: Double, amp: Double)] = [
            (523.25, 0.00, 0.6),   // C5
            (659.25, 0.18, 0.5),   // E5
            (783.99, 0.36, 0.45),  // G5
        ]

        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            var val: Double = 0
            for tone in tones {
                if t >= tone.start {
                    let age = t - tone.start
                    let env = exp(-age * 3.5)   // decay envelope
                    val += tone.amp * env * sin(2 * .pi * tone.freq * t)
                }
            }
            samples[i] = Int16(max(-32767, min(32767, val * 32767)))
        }

        // Build a minimal WAV in memory
        var wav = Data()
        func u32le(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16le(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        let dataBytes = UInt32(numSamples * 2)
        wav.append("RIFF".data(using: .ascii)!); u32le(36 + dataBytes)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        u32le(16); u16le(1); u16le(1)               // PCM, mono
        u32le(UInt32(sampleRate)); u32le(UInt32(sampleRate) * 2)
        u16le(2); u16le(16)                          // block align, bits
        wav.append("data".data(using: .ascii)!); u32le(dataBytes)
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }

        audioPlayer = try? AVAudioPlayer(data: wav, fileTypeHint: "wav")
        audioPlayer?.prepareToPlay()
    }

    func playChime() {
        audioPlayer?.currentTime = 0
        audioPlayer?.play()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Build UI
    // ─────────────────────────────────────────────────────────────────────────

    // The inner rect where visible UI lives (inset by pad from panel edges)
    var innerOrigin: NSPoint { NSPoint(x: pad, y: pad) }

    func buildUI() {
        // Container view for all visible UI, offset by pad
        let inner = NSView(frame: NSRect(x: pad, y: pad, width: W, height: H))
        addSubview(inner)

        timeLabel = lbl("05:00", font: roboto(48), color: .white)
        timeLabel.frame = NSRect(x: 0, y: (H - 62) / 2, width: W, height: 62)
        let sh = NSShadow()
        sh.shadowOffset = NSSize(width: 2, height: -2)
        sh.shadowBlurRadius = 0
        sh.shadowColor = .black.withAlphaComponent(0.5)
        timeLabel.shadow = sh
        inner.addSubview(timeLabel)

        controlsLayer = NSView(frame: NSRect(origin: .zero, size: NSSize(width: W, height: H)))
        controlsLayer.wantsLayer = true
        controlsLayer.layer?.opacity = 0
        inner.addSubview(controlsLayer)

        modeLabel = lbl("COUNTDOWN", font: roboto(12), color: .white.withAlphaComponent(0.45))
        let timeLabelTop = (H - 62) / 2 + 62  // top of time label
        let modeLabelH: CGFloat = 16
        modeLabel.frame = NSRect(x: 0, y: (timeLabelTop + H) / 2 - modeLabelH / 2 - 10, width: W, height: modeLabelH)
        controlsLayer.addSubview(modeLabel)

        let btnW: CGFloat = 32, btnH: CGFloat = 22, btnY: CGFloat = 8
        let total: CGFloat = btnW * 4 + 8 * 3
        let sx: CGFloat = (W - total) / 2
        playBtn  = mkBtn("▶", x: sx,                 y: btnY, w: btnW, h: btnH, id: "play")
        resetBtn = mkBtn("↺", x: sx + btnW + 8,      y: btnY, w: btnW, h: btnH, id: "reset")
        modeBtn  = mkBtn("⇄", x: sx + btnW * 2 + 16, y: btnY, w: btnW, h: btnH, id: "mode")
        closeBtn = mkBtn("✕", x: sx + btnW * 3 + 24, y: btnY, w: btnW, h: btnH, id: "close")
    }

    func lbl(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font; f.textColor = color
        f.isBezeled = false; f.isEditable = false
        f.drawsBackground = false; f.alignment = .center
        return f
    }

    @discardableResult
    func mkBtn(_ sym: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, id: String) -> NSTextField {
        let f = lbl(sym, font: roboto(15), color: .white.withAlphaComponent(0.55))
        f.frame = NSRect(x: x, y: y, width: w, height: h)
        f.identifier = NSUserInterfaceItemIdentifier(id)
        controlsLayer.addSubview(f)
        return f
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Draw
    // ─────────────────────────────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        // Dark rounded rect background — visible enough for hit testing, subtle enough to float
        let bgRect = NSRect(x: pad, y: pad, width: W, height: H)
        NSColor(white: 0, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 14, yRadius: 14).fill()

        if isEditing {
            let path = NSBezierPath()
            let underY = pad + (H - 62) / 2 - 4
            path.move(to: NSPoint(x: pad + 24, y: underY))
            path.line(to: NSPoint(x: pad + W - 24, y: underY))
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1; path.stroke()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Tracking / Hover
    // ─────────────────────────────────────────────────────────────────────────

    func rebuildTracking() {
        if let t = trackArea { removeTrackingArea(t) }
        trackArea = NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(trackArea!)
    }

    override func updateTrackingAreas() { super.updateTrackingAreas(); rebuildTracking() }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; animateFade(to: 1.0)
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if isEditing { return }
        isHovered = false; animateFade(to: 0.0)
    }

    override func mouseMoved(with event: NSEvent) { updateBtnHover(event.locationInWindow) }

    func animateFade(to target: CGFloat) {
        fadeAnim?.invalidate()
        let step: CGFloat = target > hoverAlpha ? 0.1 : -0.1
        fadeAnim = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.hoverAlpha += step
            if (step > 0 && self.hoverAlpha >= target) || (step < 0 && self.hoverAlpha <= target) {
                self.hoverAlpha = target; t.invalidate()
            }
            self.controlsLayer.layer?.opacity = Float(self.hoverAlpha)
        }
    }

    /// Convert window-space point to inner UI coordinate space (subtract pad offset)
    func innerPoint(_ windowPt: NSPoint) -> NSPoint {
        NSPoint(x: windowPt.x - pad, y: windowPt.y - pad)
    }

    func updateBtnHover(_ pt: NSPoint) {
        let ip = innerPoint(pt)
        for b in allBtns {
            let id = b.identifier?.rawValue ?? ""
            let hit = b.frame.insetBy(dx: -4, dy: -4).contains(ip)
            b.textColor = hit
                ? (id == "close" ? NSColor(red:1, green:0.37, blue:0.25, alpha:1) : .white)
                : .white.withAlphaComponent(0.55)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Mouse
    // ─────────────────────────────────────────────────────────────────────────

    override func mouseDown(with event: NSEvent) {
        let ip = innerPoint(event.locationInWindow)
        for b in allBtns {
            if b.frame.insetBy(dx: -4, dy: -4).contains(ip) {
                switch b.identifier?.rawValue {
                case "play":  toggleTimer()
                case "reset": resetTimer()
                case "mode":  switchMode()
                case "close": NSApp.terminate(nil)
                default: break
                }
                return
            }
        }
        if event.clickCount == 2 {
            let digitZone = NSRect(x: 10, y: (H - 62) / 2 - 10, width: W - 20, height: 82)
            if digitZone.contains(ip) { startEditing(); return }
        }
        if isEditing { commitEdit(); return }
        // Start manual drag — record window origin and mouse screen position
        guard let win = window else { return }
        dragOrigin = win.frame.origin
        dragMouse  = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let origin = dragOrigin, let startMouse = dragMouse else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        win.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        dragMouse  = nil
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Edit
    // ─────────────────────────────────────────────────────────────────────────

    func startEditing() {
        guard !running else { return }
        isEditing = true; editString = ""
        timeLabel.stringValue = "00:00"
        timeLabel.textColor   = .white.withAlphaComponent(0.5)
        fadeAnim?.invalidate()
        hoverAlpha = 1.0; controlsLayer.layer?.opacity = 1.0
        needsDisplay = true
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    func commitEdit() {
        isEditing = false; timeLabel.textColor = .white
        flashTimer?.invalidate(); flashTimer = nil
        isDone = false; flashOn = false
        let digits = editString.filter { $0.isNumber }
        var secs = 0
        switch digits.count {
        case 0: break
        case 1, 2: secs = Int(digits) ?? 0
        case 3, 4: secs = (Int(digits.dropLast(2)) ?? 0) * 60 + (Int(digits.suffix(2)) ?? 0)
        default:
            secs = (Int(digits.dropLast(4)) ?? 0) * 3600
                 + (Int(digits.dropLast(2).suffix(2)) ?? 0) * 60
                 + (Int(digits.suffix(2)) ?? 0)
        }
        if secs > 0 {
            if mode == .stopwatch { elapsed = Double(secs) }
            else { countdown = Double(secs); remaining = countdown }
        }
        editString = ""; needsDisplay = true; refreshDisplay()
        if !isHovered { animateFade(to: 0.0) }
    }

    func cancelEdit() {
        isEditing = false; editString = ""
        flashTimer?.invalidate(); flashTimer = nil
        isDone = false; flashOn = false
        timeLabel.textColor = .white
        needsDisplay = true; refreshDisplay()
        if !isHovered { animateFade(to: 0.0) }
    }

    func updateEditDisplay() {
        let digits = editString.filter { $0.isNumber }
        guard !digits.isEmpty else { timeLabel.stringValue = "00:00"; return }
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        if digits.count <= 4 {
            timeLabel.stringValue = "\(padded.prefix(2)):\(padded.suffix(2))"
        } else {
            timeLabel.stringValue = "\(digits.dropLast(4)):\(digits.dropLast(2).suffix(2)):\(digits.suffix(2))"
        }
        needsDisplay = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Keyboard
    // ─────────────────────────────────────────────────────────────────────────

    override func keyDown(with event: NSEvent) {
        if isEditing {
            switch event.keyCode {
            case 36, 76: commitEdit()
            case 53:     cancelEdit()
            case 51:
                if !editString.isEmpty { editString.removeLast() }
                updateEditDisplay()
            default:
                if let ch = event.charactersIgnoringModifiers,
                   ch.allSatisfy({ $0.isNumber }), editString.count < 6 {
                    editString.append(contentsOf: ch); updateEditDisplay()
                }
            }
        } else {
            if event.keyCode == 49 { toggleTimer() }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Timer logic
    // ─────────────────────────────────────────────────────────────────────────

    func toggleTimer() {
        guard !isEditing else { return }
        running = !running
        playBtn.stringValue = running ? "⏸" : "▶"
        if running {
            lastTick = Date()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } else {
            ticker?.invalidate(); ticker = nil
        }
    }

    func resetTimer() {
        ticker?.invalidate(); ticker = nil
        flashTimer?.invalidate(); flashTimer = nil
        running = false; elapsed = 0; remaining = countdown
        isDone = false; flashOn = false
        playBtn.stringValue = "▶"
        refreshDisplay()
    }

    func switchMode() {
        resetTimer()
        mode = mode == .stopwatch ? .countdown : .stopwatch
        modeLabel.stringValue = mode == .stopwatch ? "STOPWATCH" : "COUNTDOWN"
        refreshDisplay()
    }

    func tick() {
        let now = Date(); let dt = now.timeIntervalSince(lastTick); lastTick = now
        if mode == .stopwatch {
            elapsed += dt
        } else {
            remaining -= dt
            if remaining <= 0 {
                remaining = 0
                ticker?.invalidate(); ticker = nil
                running = false; playBtn.stringValue = "▶"
                triggerDone()
                return
            }
        }
        refreshDisplay()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Done (chime + persistent flash)
    // ─────────────────────────────────────────────────────────────────────────

    func triggerDone() {
        isDone = true; flashOn = true
        playChime()
        refreshDisplay()
        // Flash at 2Hz until reset
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.flashOn = !self.flashOn
            self.refreshDisplay()
        }
    }

    func refreshDisplay() {
        guard !isEditing else { return }
        let val = mode == .stopwatch ? elapsed : remaining
        timeLabel.stringValue = formatTime(Int(val))

        if isDone {
            timeLabel.textColor = flashOn
                ? NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 1)
                : NSColor(red: 0.5, green: 0.1, blue: 0.1, alpha: 1)
        } else {
            let urgent = mode == .countdown && remaining <= 10 && running
            timeLabel.textColor = urgent
                ? NSColor(red: 1, green: 0.37, blue: 0.25, alpha: 1)
                : .white
        }
    }

    func formatTime(_ seconds: Int) -> String {
        let s = abs(seconds), neg = seconds < 0 ? "-" : ""
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "\(neg)%d:%02d:%02d", h, m, sec) }
        return String(format: "\(neg)%02d:%02d", m, sec)
    }
}
