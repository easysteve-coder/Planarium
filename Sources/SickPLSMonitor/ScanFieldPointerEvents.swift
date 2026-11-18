import AppKit
import SwiftUI
import SickPLSMonitorKit

/// Hit-tested native ownership for the instrument and reference-field editors.
/// Pointer, gesture, zoom, key and cursor events share AppKit's responder chain.
struct ScanFieldPointerEvents: NSViewRepresentable {
    /// Das rohe Scrollereignis und die Zeigerposition in der Koordinate
    /// dieser Ansicht.
    let onScroll: (ScanFieldScrollEvent, CGPoint) -> Void
    /// Verschiebung eines gedrückten Zwei-Finger-Drags. macOS liefert den
    /// Zwei-Finger-Klick als sekundären Mausknopf; normale Zwei-Finger-
    /// Bewegung bleibt davon getrennt ein Scrollereignis.
    let onPressedTwoFingerDrag: (CGSize) -> Void
    /// Kontextklick nach abgeschlossener Sekundärgeste.
    var onSecondaryClick: ((CGPoint) -> Void)? = nil
    /// Relative Pinch-Änderung des Systemereignisses und Zeigerposition.
    let onMagnify: (Double, CGPoint) -> Void
    /// Tastaturbefehle des fokussierten Messfelds; Textfelder werden vorher
    /// ausgespart und behalten ihre normale Eingabe.
    var onKeyCommand: ((NSEvent) -> Bool)? = nil
    var onKeyRelease: ((NSEvent) -> Void)? = nil
    var onDoubleClick: ((CGPoint) -> Void)? = nil
    /// A handled primary double-click owns the second down/drag/up sequence.
    var onPrimaryDoubleClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)? = nil
    var onFocusLost: (() -> Void)? = nil
    /// Native down/drag/up ownership survives SwiftUI redraws.
    var onPrimaryDrag: ((NSEvent.EventType, CGPoint, NSEvent.ModifierFlags) -> Void)? = nil
    var onSecondaryDrag: ((NSEvent.EventType, CGPoint) -> Void)? = nil
    var onDeleteCommand: (() -> Bool)? = nil
    var onSelectAllCommand: (() -> Bool)? = nil
    var isDeleteCommandEnabled: (() -> Bool)? = nil
    var isSelectAllCommandEnabled: (() -> Bool)? = nil
    /// Ändert sich das Werkzeug, wird eine angefangene Sekundärgeste verworfen.
    var toolName: String = ""
    /// Optionaler Werkzeugcursor für dieselbe Canvas. Cursor-Rechtecke sind
    /// robuster als SwiftUIs `onHover`, das bei überlagerten Canvas-/Gesten-
    /// Ansichten nicht zuverlässig erneut gesetzt wird.
    var cursor: NSCursor? = nil
    var cursorAtPoint: ((CGPoint) -> NSCursor?)? = nil
    /// Layer-list reuse only supplies keyboard focus and never consumes its
    /// context clicks, scrolling or cursor rectangles.
    var isKeyboardOnly = false
    var onKeyboardClick: ((NSEvent) -> Void)? = nil

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.onScroll = onScroll
        view.onPressedTwoFingerDrag = onPressedTwoFingerDrag
        view.onSecondaryClick = onSecondaryClick
        view.onMagnify = onMagnify
        view.onKeyCommand = onKeyCommand
        view.onKeyRelease = onKeyRelease
        view.onDoubleClick = onDoubleClick
        view.onPrimaryDoubleClick = onPrimaryDoubleClick
        view.onFocusLost = onFocusLost
        view.onPrimaryDrag = onPrimaryDrag
        view.onSecondaryDrag = onSecondaryDrag
        view.onDeleteCommand = onDeleteCommand
        view.onSelectAllCommand = onSelectAllCommand
        view.isDeleteCommandEnabled = isDeleteCommandEnabled
        view.isSelectAllCommandEnabled = isSelectAllCommandEnabled
        view.toolName = toolName
        view.cursor = cursor
        view.cursorAtPoint = cursorAtPoint
        view.isKeyboardOnly = isKeyboardOnly
        view.onKeyboardClick = onKeyboardClick
        return view
    }

    func updateNSView(_ nsView: PointerView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onPressedTwoFingerDrag = onPressedTwoFingerDrag
        nsView.onSecondaryClick = onSecondaryClick
        nsView.onMagnify = onMagnify
        nsView.onKeyCommand = onKeyCommand
        nsView.onKeyRelease = onKeyRelease
        nsView.onDoubleClick = onDoubleClick
        nsView.onPrimaryDoubleClick = onPrimaryDoubleClick
        nsView.onFocusLost = onFocusLost
        nsView.onPrimaryDrag = onPrimaryDrag
        nsView.onSecondaryDrag = onSecondaryDrag
        nsView.onDeleteCommand = onDeleteCommand
        nsView.onSelectAllCommand = onSelectAllCommand
        nsView.isDeleteCommandEnabled = isDeleteCommandEnabled
        nsView.isSelectAllCommandEnabled = isSelectAllCommandEnabled
        if nsView.toolName != toolName { nsView.cancelSecondaryGesture() }
        nsView.toolName = toolName
        nsView.cursor = cursor
        nsView.cursorAtPoint = cursorAtPoint
        nsView.isKeyboardOnly = isKeyboardOnly
        nsView.onKeyboardClick = onKeyboardClick
        nsView.refreshCursorUnderPointer()
        nsView.refreshCursorAfterLayout()
    }

    static func dismantleNSView(_ nsView: PointerView, coordinator: ()) {
        nsView.stopListening()
    }

    final class PointerView: NSView {
        var onScroll: ((ScanFieldScrollEvent, CGPoint) -> Void)?
        var onPressedTwoFingerDrag: ((CGSize) -> Void)?
        var onSecondaryClick: ((CGPoint) -> Void)?
        var onMagnify: ((Double, CGPoint) -> Void)?
        var onKeyCommand: ((NSEvent) -> Bool)?
        var onKeyRelease: ((NSEvent) -> Void)?
        var onDoubleClick: ((CGPoint) -> Void)?
        var onPrimaryDoubleClick: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
        private var ownsDoubleClick = false
        var onFocusLost: (() -> Void)?
        var onPrimaryDrag: ((NSEvent.EventType, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onSecondaryDrag: ((NSEvent.EventType, CGPoint) -> Void)?
        var onDeleteCommand: (() -> Bool)?
        var onSelectAllCommand: (() -> Bool)?
        var isDeleteCommandEnabled: (() -> Bool)?
        var isSelectAllCommandEnabled: (() -> Bool)?
        var toolName = ""
        var isKeyboardOnly = false
        var onKeyboardClick: ((NSEvent) -> Void)?
        var cursor: NSCursor? {
            didSet { refreshCursorUnderPointer() }
        }
        var cursorAtPoint: ((CGPoint) -> NSCursor?)?

        private var pointerWasInside = false
        private var secondaryGesture = SecondaryPointerGesture()
        private var secondaryGestureStartedInside = false
        private var primaryGestureStartedInside = false
        private var primaryAnchor: (window: CGPoint, local: CGPoint)?
        private var secondaryAnchor: (window: CGPoint, local: CGPoint)?
        private var cursorRefreshPending = false
        private weak var cursorOwnerWindow: NSWindow?
        private var resignKeyObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            focusRingType = .default
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            focusRingType = .default
        }

        /// Gleiche Achsenrichtung wie SwiftUI (Ursprung oben links),
        /// damit die gemeldete Position ohne Umrechnung zu den
        /// Ziehgesten passt.
        override var isFlipped: Bool { true }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        @objc func delete(_ sender: Any?) {
            _ = onDeleteCommand?()
        }

        override func selectAll(_ sender: Any?) {
            _ = onSelectAllCommand?()
        }

        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(delete(_:)) {
                return isDeleteCommandEnabled?() ?? false
            }
            if item.action == #selector(selectAll(_:)) {
                return isSelectAllCommandEnabled?() ?? false
            }
            return true
        }

        /// AppKit's hit test respects controls/popovers placed above the canvas.
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopListening()
            guard window != nil else { return }
            window?.acceptsMouseMovedEvents = true
            updateTrackingAreas()
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelSecondaryGesture(); self?.primaryGestureStartedInside = false; self?.ownsDoubleClick = false
                    self?.onFocusLost?()
                }
            }
            refreshCursorUnderPointer()
            refreshCursorAfterLayout()
        }

        func stopListening() {
            let hadGesture = primaryGestureStartedInside || secondaryGestureStartedInside
            cancelSecondaryGesture()
            primaryGestureStartedInside = false
            ownsDoubleClick = false
            if hadGesture { onFocusLost?() }
            if let resignKeyObserver {
                NotificationCenter.default.removeObserver(resignKeyObserver)
            }
            resignKeyObserver = nil
            releaseCursorOwnership()
        }

        deinit {
            // Ein `NSView` stirbt auf dem Main Thread; `deinit` ist für
            // den Compiler trotzdem nicht isoliert. Die Annahme wird
            // geprüft, nicht behauptet (SICK-039).
            MainActor.assumeIsolated { stopListening() }
        }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area); tracking = area
        }
        override func resetCursorRects() {
            super.resetCursorRects()
            guard !isKeyboardOnly, let cursor else { return }
            addCursorRect(bounds, cursor: cursor)
        }
        override func mouseDown(with event: NSEvent) {
            if handle(event) != nil { super.mouseDown(with: event) }
        }
        override func mouseDragged(with event: NSEvent) { if handle(event) != nil { super.mouseDragged(with: event) } }
        override func mouseUp(with event: NSEvent) { if handle(event) != nil { super.mouseUp(with: event) } }
        override func rightMouseDown(with event: NSEvent) { if handle(event) != nil { super.rightMouseDown(with: event) } }
        override func rightMouseDragged(with event: NSEvent) { if handle(event) != nil { super.rightMouseDragged(with: event) } }
        override func rightMouseUp(with event: NSEvent) { if handle(event) != nil { super.rightMouseUp(with: event) } }
        override func scrollWheel(with event: NSEvent) { if handle(event) != nil { super.scrollWheel(with: event) } }
        override func magnify(with event: NSEvent) { if handle(event) != nil { super.magnify(with: event) } }
        override func keyDown(with event: NSEvent) { if handle(event) != nil { super.keyDown(with: event) } }
        override func keyUp(with event: NSEvent) { if handle(event) != nil { super.keyUp(with: event) } }
        override func mouseMoved(with event: NSEvent) { _ = handle(event) }
        override func mouseEntered(with event: NSEvent) { refreshCursorUnderPointer() }
        override func mouseExited(with event: NSEvent) {
            if primaryGestureStartedInside || secondaryGestureStartedInside { refreshCursorUnderPointer() }
            else { releaseCursorOwnership() }
        }
        override func cursorUpdate(with event: NSEvent) { refreshCursorUnderPointer() }
        override func resignFirstResponder() -> Bool {
            primaryGestureStartedInside = false; ownsDoubleClick = false; cancelSecondaryGesture(); onFocusLost?()
            return super.resignFirstResponder()
        }

        @discardableResult
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let local = convert(event.locationInWindow, from: nil)
            let isInside = bounds.contains(local)
            if event.type == .keyUp {
                guard window.firstResponder === self else { return event }
                onKeyRelease?(event)
                return event.keyCode == 49 && onKeyRelease != nil ? nil : event
            }
            if event.type == .keyDown {
                guard window.firstResponder === self, let onKeyCommand else { return event }
                if window.firstResponder is NSTextField || window.firstResponder is NSTextView {
                    return event
                }
                return onKeyCommand(event) ? nil : event
            }
            if event.type == .leftMouseDown && isInside && !event.modifierFlags.contains(.control) {
                window.makeFirstResponder(self)
            }
            if isKeyboardOnly {
                if event.type == .leftMouseDown {
                    window.makeFirstResponder(self)
                    onKeyboardClick?(event)
                    return onKeyboardClick == nil ? event : nil
                }
                if event.type == .leftMouseUp && onKeyboardClick != nil {
                    if event.clickCount == 2 { onDoubleClick?(local) }
                    return nil
                }
                return event
            }
            if ownsDoubleClick && (event.type == .leftMouseDragged || event.type == .leftMouseUp) {
                if event.type == .leftMouseUp { ownsDoubleClick = false }
                return nil
            }
            if event.type == .leftMouseDown, isInside, event.clickCount == 2,
               !event.modifierFlags.contains(.control), onPrimaryDoubleClick?(local, event.modifierFlags) == true {
                ownsDoubleClick = true
                refreshCursorUnderPointer(); refreshCursorAfterLayout()
                return nil
            }
            if let onPrimaryDrag, primaryGestureStartedInside || !event.modifierFlags.contains(.control) {
                switch event.type {
                case .leftMouseDown where isInside:
                    primaryGestureStartedInside = true
                    primaryAnchor = (event.locationInWindow, local)
                    onPrimaryDrag(event.type, local, event.modifierFlags)
                    refreshCursorUnderPointer(); refreshCursorAfterLayout()
                    return nil
                case .leftMouseDragged, .leftMouseUp:
                    if primaryGestureStartedInside {
                        let point = anchoredPoint(event.locationInWindow, anchor: primaryAnchor) ?? local
                        onPrimaryDrag(event.type, point, event.modifierFlags)
                        if event.type == .leftMouseUp {
                            primaryGestureStartedInside = false
                            primaryAnchor = nil
                            if isInside && event.clickCount == 2 { onDoubleClick?(local) }
                        }
                        refreshCursorUnderPointer(); refreshCursorAfterLayout()
                        return nil
                    }
                default: break
                }
            }
            if event.type == .leftMouseUp && isInside && event.clickCount == 2 {
                DispatchQueue.main.async { [weak self] in self?.onDoubleClick?(local) }
            }
            if isInside {
                claimCursorOwnership(in: window)
                (cursorAtPoint?(local) ?? cursor)?.set()
                pointerWasInside = true
            } else if pointerWasInside {
                releaseCursorOwnership()
            }
            let isControlClick = event.modifierFlags.contains(.control)
            let isSecondary = event.type == .rightMouseDown || event.type == .rightMouseDragged || event.type == .rightMouseUp ||
                ((event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp) &&
                    (isControlClick || secondaryGestureStartedInside))
            if isSecondary {
                switch event.type {
                case .rightMouseDown, .leftMouseDown:
                    guard isInside else {
                        secondaryGesture.cancel()
                        secondaryGestureStartedInside = false
                        return event
                    }
                    secondaryGestureStartedInside = true
                    secondaryAnchor = (event.locationInWindow, local)
                    window.makeFirstResponder(self)
                    _ = secondaryGesture.down(at: local, inside: isInside)
                    onSecondaryDrag?(.rightMouseDown, local)
                case .rightMouseDragged, .leftMouseDragged:
                    guard secondaryGestureStartedInside else { return event }
                    let point = anchoredPoint(event.locationInWindow, anchor: secondaryAnchor) ?? local
                    if case let .pan(translation) = secondaryGesture.dragged(to: point) {
                        if let onSecondaryDrag { onSecondaryDrag(.rightMouseDragged, point) }
                        else { onPressedTwoFingerDrag?(translation) }
                    }
                case .rightMouseUp, .leftMouseUp:
                    guard secondaryGestureStartedInside else { return event }
                    let point = anchoredPoint(event.locationInWindow, anchor: secondaryAnchor) ?? local
                    let output = secondaryGesture.up(at: point, inside: isInside)
                    // Sub-threshold click jitter opens a menu, not a tiny pan.
                    let releasePoint: CGPoint
                    if case .openContextMenu = output { releasePoint = secondaryAnchor?.local ?? point }
                    else { releasePoint = point }
                    onSecondaryDrag?(.rightMouseUp, releasePoint)
                    if case let .openContextMenu(at: point) = output {
                        onSecondaryClick?(point)
                    }
                    secondaryGestureStartedInside = false
                default: break
                }
                // Ctrl-Klick darf nicht zusätzlich die normale SwiftUI-Geste
                // starten. Sekundärereignisse bleiben sonst unberührt.
                return nil
            }
            guard isInside else { return event }

            switch event.type {
            case .scrollWheel:
                guard let onScroll else { return event }
                onScroll(
                    ScanFieldScrollEvent(
                        deltaY: Double(event.scrollingDeltaY),
                        hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                        isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
                    ),
                    local
                )
                return nil
            case .magnify:
                guard let onMagnify else { return event }
                onMagnify(Double(event.magnification), local)
                return nil
            default:
                break
            }
            return event
        }

        func cancelSecondaryGesture() {
            secondaryGesture.cancel()
            secondaryGestureStartedInside = false
            secondaryAnchor = nil
        }

        private func anchoredPoint(_ point: CGPoint, anchor: (window: CGPoint, local: CGPoint)?) -> CGPoint? {
            guard let anchor else { return nil }
            return .init(x: anchor.local.x + point.x - anchor.window.x,
                         y: anchor.local.y - (point.y - anchor.window.y))
        }

        /// Werkzeugwechsel können stattfinden, während der Zeiger bereits
        /// im Messfeld steht. Dann kommt nicht zwingend sofort ein weiteres
        /// `mouseMoved`; deshalb wird der Cursor auch anhand der aktuellen
        /// Fensterposition unmittelbar nachgeführt.
        func refreshCursorUnderPointer() {
            guard !isKeyboardOnly, cursor != nil || cursorAtPoint != nil else { releaseCursorOwnership(); return }
            guard let window else { return }
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard bounds.contains(local) || primaryGestureStartedInside || secondaryGestureStartedInside else {
                if pointerWasInside { releaseCursorOwnership() }
                return
            }
            claimCursorOwnership(in: window)
            (cursorAtPoint?(local) ?? cursor)?.set()
            pointerWasInside = true
        }

        override func layout() {
            super.layout()
            refreshCursorAfterLayout()
        }

        /// SwiftUI lays out its own cursor regions after updateNSView. Apply
        /// the current tool once that pass ends, without requiring mouseMoved.
        func refreshCursorAfterLayout() {
            guard !cursorRefreshPending else { return }
            cursorRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cursorRefreshPending = false
                self.refreshCursorUnderPointer()
            }
        }

        /// Solange der Zeiger im Messfeld steht, darf nur diese Naht den
        /// Cursor setzen. Sonst konkurrieren SwiftUIs Pfeil-Cursorrechtecke
        /// bei jedem Profil-Redraw mit dem Werkzeugcursor und beide flackern.
        private func claimCursorOwnership(in window: NSWindow) {
            guard cursorOwnerWindow !== window else { return }
            releaseCursorOwnership()
            cursorOwnerWindow = window
        }

        private func releaseCursorOwnership() {
            guard cursorOwnerWindow != nil || pointerWasInside else { return }
            cursorOwnerWindow = nil
            pointerWasInside = false
            NSCursor.arrow.set()
        }
    }
}
