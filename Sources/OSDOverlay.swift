import AppKit
import CoreGraphics

/// A native-looking macOS OSD overlay (like the volume/brightness HUD from keyboard keys).
/// Shows a translucent rounded-rect with an SF Symbol icon and a level bar.
class OSDOverlay {
    private var window: NSWindow?
    private var iconView: NSImageView?
    private var barView: LevelBarView?
    private var hideTimer: Timer?
    
    private var currentIconName: String?
    private var displayToken = UUID()

    private let osdSize = NSSize(width: 200, height: 200)
    private let cornerRadius: CGFloat = 18
    private let displayDuration: TimeInterval = 1.2
    private let fadeDuration: TimeInterval = 0.3

    // MARK: - Public

    /// Show the OSD for volume level
    func showVolume(level: Float, muted: Bool) {
        let iconName = muted ? "speaker.slash.fill" : volumeIcon(for: level)
        show(iconName: iconName, level: muted ? 0 : level, segments: 16)
    }

    /// Show the OSD for brightness level
    func showBrightness(level: Float) {
        let iconName = level < 0.01 ? "sun.min" : "sun.max.fill"
        show(iconName: iconName, level: level, segments: 16)
    }

    /// Immediately hide the OSD
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        
        let token = UUID()
        self.displayToken = token
        
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.displayToken == token {
                win.orderOut(nil)
            }
        })
    }

    // MARK: - Private

    private func volumeIcon(for level: Float) -> String {
        if level < 0.01 { return "speaker.slash.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func show(iconName: String, level: Float, segments: Int) {
        ensureWindow()
        guard let win = window, let iconView = iconView, let barView = barView else { return }

        displayToken = UUID()

        // Update icon only if changed
        if currentIconName != iconName {
            currentIconName = iconName
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .medium)
                iconView.image = img.withSymbolConfiguration(config)
                iconView.contentTintColor = .white
            }
        }

        // Update level bar
        if barView.level != level || barView.segmentCount != segments {
            barView.level = level
            barView.segmentCount = segments
            barView.needsDisplay = true
        }

        // Position on the active screen only if not already visible
        if !win.isVisible || win.alphaValue == 0 {
            let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first!
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - osdSize.width / 2
            let y = screenFrame.minY + screenFrame.height * 0.15
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Show with fade-in if not already fully visible
        if !win.isVisible {
            win.alphaValue = 0
            win.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                win.animator().alphaValue = 1
            }
        } else if win.alphaValue < 1.0 {
            // Cancel any in-progress fade-out immediately (no animation conflict)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                win.animator().alphaValue = 1
            }
        }

        // Schedule hide
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: osdSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        // Background: translucent dark rounded rect (matches macOS HUD style)
        let bgView = OSDBackgroundView(frame: NSRect(origin: .zero, size: osdSize))
        bgView.cornerRadius = cornerRadius
        win.contentView = bgView

        // Icon (centered horizontally, upper portion)
        let icon = NSImageView(frame: NSRect(x: (osdSize.width - 64) / 2, y: 80, width: 64, height: 64))
        icon.imageScaling = .scaleProportionallyUpOrDown
        bgView.addSubview(icon)
        self.iconView = icon

        // Level bar (bottom portion)
        let barHeight: CGFloat = 8
        let barInset: CGFloat = 28
        let barWidth = osdSize.width - barInset * 2
        let bar = LevelBarView(frame: NSRect(x: barInset, y: 40, width: barWidth, height: barHeight))
        bgView.addSubview(bar)
        self.barView = bar

        self.window = win
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}

// MARK: - OSD Background View

/// Translucent dark rounded-rect background matching macOS HUD style.
private class OSDBackgroundView: NSView {
    var cornerRadius: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
    }
}

// MARK: - Level Bar View

/// Segmented level bar (like the native macOS OSD).
private class LevelBarView: NSView {
    var level: Float = 0.5
    var segmentCount: Int = 16

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let totalGaps = CGFloat(segmentCount - 1) * gap
        let segWidth = (bounds.width - totalGaps) / CGFloat(segmentCount)
        let filledCount = Int(Float(segmentCount) * max(0, min(1, level)) + 0.5)

        for i in 0..<segmentCount {
            let x = CGFloat(i) * (segWidth + gap)
            let rect = NSRect(x: x, y: 0, width: segWidth, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)

            if i < filledCount {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.2).setFill()
            }
            path.fill()
        }
    }
}
