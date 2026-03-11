#if os(macOS)
import AppKit
import ApplicationServices
import QuartzCore

@MainActor
public final class MacOverlayPresenter: NSObject, OverlayPresenter {
    private static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let axBoundsForTextMarkerRangeParameterizedAttribute = "AXBoundsForTextMarkerRange"

    public struct AnchorSnapshot: Sendable, Equatable {
        public let frame: CGRect

        public init(frame: CGRect) {
            self.frame = frame
        }
    }

    private var window: NSWindow?
    private var statusDot: NSView?
    private var textField: NSTextField?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var pulseTimer: Timer?
    private var dotPulseHigh = true
    private var wasHidden = true
    private var anchorSnapshot: AnchorSnapshot?

    private static let dotBlue = NSColor(red: 0.118, green: 0.565, blue: 1.0, alpha: 1.0)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
            pulseTimer?.invalidate()
            pulseTimer = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    /// Pre-create the overlay window so the first `show` has no lazy-init stutter.
    public func prepareWindow() {
        ensureWindow()
    }

    public func captureAnchorSnapshot() -> AnchorSnapshot? {
        guard AXIsProcessTrusted(),
              let frame = currentFocusedFrame() else {
            return nil
        }

        return AnchorSnapshot(frame: frame)
    }

    public func setAnchorSnapshot(_ snapshot: AnchorSnapshot?) {
        anchorSnapshot = snapshot
    }

    public func show(state: OverlayState) {
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        switch state {
        case .listening(let handsFree, _):
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            updateListeningText()
            startTimer()
            animateDotColor(Self.dotBlue)
            startDotPulse()

        case .liveTranscript(let text, _):
            stopTimer()
            let display = text.count > 80 ? "..." + text.suffix(77) : text
            textField?.stringValue = display
            animateDotColor(Self.dotBlue)
            startDotPulse()

        case .transcribing:
            stopTimer()
            stopDotPulse()
            updateText("Transcribing...")
            animateDotColor(.darkGray)

        case .inserted:
            stopTimer()
            stopDotPulse()
            updateText("Inserted")
            animateDotColor(.systemGreen)

        case .copiedOnly:
            stopTimer()
            stopDotPulse()
            updateText("Copied to clipboard")
            animateDotColor(.systemOrange)

        case .failure(let message):
            stopTimer()
            stopDotPulse()
            updateText("Error: \(message)")
            animateDotColor(.systemRed)
        }

        positionWindow()

        if isFirstShow && !reduceMotion {
            // Entrance animation: fade in + slide up
            window?.alphaValue = 0
            let finalOrigin = window?.frame.origin ?? .zero
            window?.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 20))
            window?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window?.animator().alphaValue = 1
                self.window?.animator().setFrameOrigin(finalOrigin)
            }
        } else {
            window?.alphaValue = 1
            window?.orderFrontRegardless()
        }
    }

    public func hide() {
        stopTimer()
        stopDotPulse()
        wasHidden = true
        anchorSnapshot = nil

        if !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.window?.animator().alphaValue = 0
            }, completionHandler: {
                self.window?.orderOut(nil)
            })
        } else {
            window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        if window != nil {
            return
        }

        let contentRect = NSRect(x: 0, y: 0, width: 260, height: 44)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: contentRect)
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = false
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.layer?.shadowOffset = CGSize(width: 0, height: -2)
        content.layer?.shadowRadius = 16
        content.layer?.shadowOpacity = 1

        // Status dot
        let dot = NSView(frame: NSRect(x: 16, y: 16, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = Self.dotBlue.cgColor
        content.addSubview(dot)
        self.statusDot = dot

        // Status text
        let label = NSTextField(labelWithString: "Listening 00:00")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        panel.contentView = content
        self.window = panel
        self.textField = label
    }

    private func animateDotColor(_ color: NSColor) {
        guard !reduceMotion else {
            statusDot?.layer?.backgroundColor = color.cgColor
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        statusDot?.layer?.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    private func updateText(_ newText: String) {
        guard !reduceMotion else {
            textField?.stringValue = newText
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.textField?.animator().alphaValue = 0
        }, completionHandler: {
            self.textField?.stringValue = newText
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.textField?.animator().alphaValue = 1
            }
        })
    }

    private func startDotPulse() {
        stopDotPulse()
        dotPulseHigh = true
        statusDot?.alphaValue = 1.0
        let newTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dotPulseHigh.toggle()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.6
                    self.statusDot?.animator().alphaValue = self.dotPulseHigh ? 1.0 : 0.4
                }
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        pulseTimer = newTimer
    }

    private func stopDotPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusDot?.alphaValue = 1.0
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateListeningText()
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        listeningStartDate = nil
    }

    private func updateListeningText() {
        guard let start = listeningStartDate else {
            textField?.stringValue = "Listening 00:00"
            return
        }

        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let mode = listeningHandsFree ? "Hands-Free" : "Hold-to-Talk"
        textField?.stringValue = "\(mode) \(String(format: "%02d:%02d", minutes, seconds))"
    }

    private func positionWindow() {
        guard let window else { return }

        if let anchoredOrigin = anchoredWindowOrigin(for: window) {
            window.setFrameOrigin(anchoredOrigin)
            return
        }

        centerWindowNearTop()
    }

    private func anchoredWindowOrigin(for window: NSWindow) -> NSPoint? {
        if let anchorSnapshot {
            return anchoredWindowOrigin(for: window, frame: anchorSnapshot.frame)
        }

        guard AXIsProcessTrusted(),
              let frame = currentFocusedFrame() else {
            return nil
        }

        return anchoredWindowOrigin(for: window, frame: frame)
    }

    private func anchoredWindowOrigin(for window: NSWindow, frame: CGRect) -> NSPoint? {
        let anchorPoint = NSPoint(x: frame.midX, y: frame.maxY)
        guard let screen = screen(containing: anchorPoint) else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 12
        var x = anchorPoint.x - (window.frame.width / 2)
        var y = frame.maxY + margin

        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - window.frame.width - margin)
        y = min(y, visibleFrame.maxY - window.frame.height - margin)

        if y < visibleFrame.minY + margin {
            return nil
        }

        return NSPoint(x: x, y: y)
    }

    private func currentFocusedFrame() -> NSRect? {
        guard let element = focusedElement() else {
            return focusedWindowFrame()
        }

        if let markerBounds = selectedTextMarkerBounds(for: element) {
            return markerBounds
        }

        if let caretBounds = selectedTextBounds(for: element) {
            return caretBounds
        }

        if let elementFrame = elementFrame(for: element) {
            return elementFrame
        }

        return focusedWindowFrame()
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
    }

    private func selectedTextMarkerBounds(for element: AXUIElement) -> NSRect? {
        var selectedMarkerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            Self.axSelectedTextMarkerRangeAttribute as CFString,
            &selectedMarkerRangeRef
        ) == .success,
        let selectedMarkerRangeRef else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            Self.axBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            selectedMarkerRangeRef,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = unsafeDowncast(boundsRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(boundsValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite,
              rect.width >= 0,
              rect.height >= 0 else {
            return nil
        }

        return rect
    }

    private func selectedTextBounds(for element: AXUIElement) -> NSRect? {
        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = unsafeDowncast(boundsRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(boundsValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite,
              rect.width >= 0,
              rect.height >= 0 else {
            return nil
        }

        return rect
    }

    private func elementFrame(for element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(positionAXValue, .cgPoint, &point),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return NSRect(origin: point, size: size)
    }

    private func focusedWindowFrame() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        ) == .success,
        let appRef,
        CFGetTypeID(appRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let appElement = unsafeDowncast(appRef as AnyObject, to: AXUIElement.self)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
        let windowRef,
        CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let windowElement = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        return elementFrame(for: windowElement)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func centerWindowNearTop() {
        guard let window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let y = screenFrame.origin.y + screenFrame.height - window.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_: Notification) {
        handleAccessibilityDisplayOptionsDidChange()
    }

    private func handleAccessibilityDisplayOptionsDidChange() {
        guard reduceMotion else { return }
        stopDotPulse()
    }
}
#endif
