import AppKit
import ApplicationServices
import ScreenCaptureKit

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MarkingView: NSView {
    weak var controller: AnnotationController?
    var start: CGPoint?
    var end: CGPoint?
    var points: [CGPoint] = []
    var frameAtStart: EvidenceFrame?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func normalized(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(1, max(0, p.x / bounds.width)), y: min(1, max(0, p.y / bounds.height)))
    }
    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.mode != 0 else { return }
        let position = convert(event.locationInWindow, from: nil)
        if let note = controller.notes.reversed().first(where: {
            let point = viewRect($0.region).origin
            return CGRect(x: point.x - 22, y: point.y - 49, width: 44, height: 52).contains(position)
        }) {
            controller.cards[note.id]?.show()
            return
        }
        guard let frame = controller.capture.snapshot() else { controller.status("Waiting for screen permission or a fresh frame. Try again in a moment."); return }
        frameAtStart = frame
        start = normalized(event); end = start; points = [start!]; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        end = normalized(event)
        if points.count < 2000 { points.append(end!) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, let controller else { return }
        let last = normalized(event)
        let region = CGRect(x: min(start.x, last.x), y: min(start.y, last.y), width: abs(start.x - last.x), height: abs(start.y - last.y))
        switch controller.mode {
        case 1: if let frameAtStart { controller.addNote(region: CGRect(origin: start, size: .zero), frame: frameAtStart) }
        case 2: if let frameAtStart { controller.addNote(region: region, frame: frameAtStart) }
        case 3: if points.count > 1 { controller.addStroke(Stroke(points: points), evidence: frameAtStart) }
        case 4: if region.width > 0.002 && region.height > 0.002 { controller.addMask(region, evidence: frameAtStart) }
        case 5: if region.width > 0.002 && region.height > 0.002, let frameAtStart { controller.addNote(region: region, frame: frameAtStart, cropped: true) }
        default: break
        }
        cancelGesture()
    }
    func cancelGesture() { start = nil; end = nil; points = []; frameAtStart = nil; needsDisplay = true }
    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height)
    }
    func drawStroke(_ stroke: [CGPoint]) {
        guard let first = stroke.first else { return }
        let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: CGPoint(x: first.x * bounds.width, y: first.y * bounds.height))
        for p in stroke.dropFirst() { path.line(to: CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)) }
        AnnotateStyle.blue.setStroke(); path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard let controller else { return }
        for stroke in controller.strokes { drawStroke(stroke.points) }
        if controller.mode == 3 { drawStroke(points) }
        for note in controller.notes {
            let r = viewRect(note.region)
            AnnotateStyle.blue.setStroke()
            if r.width > 0 && r.height > 0 {
                AnnotateStyle.blue.withAlphaComponent(0.08).setFill()
                let box = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                box.fill(); box.lineWidth = 2; box.stroke()
            }
            drawAnnotationPin(at: r.origin, id: note.id)
        }
        if let start, let end, controller.mode == 2 || controller.mode == 4 || controller.mode == 5 {
            let r = viewRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)))
            if controller.mode == 4 { NSColor.black.setFill(); NSBezierPath(rect: r).fill() }
            else { AnnotateStyle.blue.setStroke(); let box = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4); box.lineWidth = 2; box.stroke() }
        }
        // Opaque masks are on top of all other annotations.
        NSColor.black.setFill()
        for mask in controller.masks { NSBezierPath(rect: viewRect(mask)).fill() }
    }
}

final class NoteEditor: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("What should the agent know?" as NSString).draw(at: CGPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

@MainActor final class NoteCard: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let panel: FloatingPanel
    let textView = NoteEditor()
    let picker = CategoryPicker()
    let counter = NSTextField(labelWithString: "")
    var saveButton: ActionButton!
    var committed: (kind: String, text: String)?
    var isEditing = true
    weak var controller: AnnotationController?
    let id: Int
    init(note: Note, screen: NSScreen, controller: AnnotationController) {
        self.id = note.id; self.controller = controller
        let size = CGSize(width: min(386, screen.visibleFrame.width - 24), height: 214)
        let targetFrame = controller.overlay.frame
        let x = targetFrame.minX + note.region.minX * targetFrame.width + 28
        let y = targetFrame.maxY - note.region.minY * targetFrame.height - size.height + 50
        let origin = CGPoint(x: min(screen.visibleFrame.maxX - size.width - 8, max(screen.visibleFrame.minX + 8, x)), y: max(screen.visibleFrame.minY + 8, min(screen.visibleFrame.maxY - size.height - 8, y)))
        panel = FloatingPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Note #\(id)"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.delegate = self
        panel.isMovableByWindowBackground = true
        let content = SurfaceView(size: size, radius: 22); panel.contentView = content
        picker.frame = CGRect(x: 14, y: 160, width: 116, height: 42)
        picker.addItems(withTitles: ["Note", "Bug", "Change", "Question"])
        picker.selectItem(at: ["note", "bug", "change", "question"].firstIndex(of: note.kind) ?? 0)
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 16, weight: .semibold); picker.menu?.font = .systemFont(ofSize: 16)
        picker.setAccessibilityLabel("Note category")
        picker.target = self; picker.action = #selector(changeKind)
        content.addSubview(picker)
        let number = NSTextField(labelWithString: "#\(id)")
        number.frame = CGRect(x: size.width - 65, y: 171, width: 45, height: 22)
        number.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        number.textColor = AnnotateStyle.secondary; number.alignment = .right
        content.addSubview(number)
        let scroll = NSScrollView(frame: CGRect(x: 19, y: 62, width: size.width - 38, height: 94))
        scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        textView.frame = scroll.bounds; textView.minSize = scroll.bounds.size
        textView.maxSize = CGSize(width: scroll.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false; textView.font = .systemFont(ofSize: 18); textView.delegate = self
        textView.drawsBackground = false; textView.textColor = AnnotateStyle.text; textView.insertionPointColor = AnnotateStyle.blue
        textView.textContainerInset = CGSize(width: 0, height: 4)
        textView.setAccessibilityLabel("Feedback for the agent")
        textView.string = note.text
        scroll.documentView = textView; content.addSubview(scroll)
        let hint = NSTextField(labelWithString: note.cropped ? "Crop · shared on Send" : "Shared only on Send")
        hint.toolTip = note.cropped ? "Only the selected rectangle is exported for this note." : "This note includes a screenshot of your selected desktop or window. Use Crop to share only a selected area."
        hint.frame = CGRect(x: 20, y: 22, width: 170, height: 20)
        hint.font = .systemFont(ofSize: 13); hint.textColor = AnnotateStyle.secondary; content.addSubview(hint)
        counter.frame = CGRect(x: 20, y: 50, width: 110, height: 14)
        counter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        counter.textColor = AnnotateStyle.secondary; content.addSubview(counter)
        let cancel = ActionButton("Cancel", target: self, action: #selector(cancel))
        cancel.plain = true; cancel.frame = CGRect(x: size.width - 168, y: 13, width: 76, height: 38)
        cancel.keyEquivalent = "\u{1b}"; content.addSubview(cancel)
        saveButton = ActionButton("Save", primary: true, target: self, action: #selector(save))
        saveButton.frame = CGRect(x: size.width - 88, y: 13, width: 74, height: 38)
        saveButton.keyEquivalent = "\r"; saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save this local note (⌘Return). Click its pin in an annotation mode to edit again."
        content.addSubview(saveButton)
        refreshEditor()
        show()
    }
    func show() {
        isEditing = true
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(textView)
    }
    func refreshEditor() {
        counter.stringValue = textView.string.count >= 1800 ? "\(textView.string.count) / 2,000" : ""
        saveButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.needsDisplay = true; textView.needsDisplay = true
    }
    @objc func changeKind() {
        picker.needsDisplay = true
        controller?.updateNote(id: id, kind: ["note", "bug", "change", "question"][picker.indexOfSelectedItem], text: textView.string)
    }
    @objc func save() {
        guard saveButton.isEnabled else { return }
        changeKind()
        committed = (["note", "bug", "change", "question"][picker.indexOfSelectedItem], textView.string)
        isEditing = false; panel.orderOut(nil)
        controller?.status("Note saved locally. Click its pin in an annotation mode to edit. Shared only on Send.")
    }
    @objc func cancel() {
        if let committed {
            textView.string = committed.text
            picker.selectItem(at: ["note", "bug", "change", "question"].firstIndex(of: committed.kind) ?? 0)
            changeKind(); refreshEditor(); isEditing = false; panel.orderOut(nil)
        } else { controller?.deleteNote(id) }
    }
    func textDidChange(_ notification: Notification) {
        if textView.string.count > 2000 { textView.string = String(textView.string.prefix(2000)); NSSound.beep() }
        refreshEditor(); changeKind()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}

enum UndoAction { case note(Int), mask, stroke }

@MainActor final class AnnotationController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let capture = DesktopCapture()
    var overlay: FloatingPanel!
    var toolbar: FloatingPanel!
    let markingView = MarkingView()
    let statusLabel = NSTextField(labelWithString: "Choose a tool to enable local screen capture.")
    let tools = ToolStrip(frame: .zero)
    var actionButtons: [String: ActionButton] = [:]
    var notes: [Note] = []; var masks: [CGRect] = []; var strokes: [Stroke] = []
    var cards: [Int: NoteCard] = [:]
    var undo: [UndoAction] = []
    var markEvidence: EvidenceFrame?
    var nextID = 1
    var mode = 0
    var displayScreen: NSScreen!
    var signals: [DispatchSourceSignal] = []
    var streamStarted = false
    var sending = false
    // Resolved once at launch: Pi passes --output <dir> (survives LaunchServices launch without env).
    let outputDirectory: URL? = resolveOutputDirectory()
    var selectedWindow: SCWindow?
    let sourceButton = NSButton(title: "Desktop ▾", target: nil, action: nil)
    let sourcePopover = NSPopover()
    let sourcePicker = NSPopUpButton()
    let sourceHint = NSTextField(wrappingLabelWithString: "")
    let sourceStart = NSButton(title: "Enable Screen Access", target: nil, action: nil)
    var sourceWindows: [SCWindow] = []
    var pendingMode = 0
    var captureBusy = false
    var captureSource = "Desktop"
    var targetTimer: Timer?
    var reviewPanel: FloatingPanel?
    var reviewImages: [NSImage] = []
    var reviewNotes: [[ExportNote]] = []
    let reviewNotesText = NSTextView()
    let reviewPicker = NSPopUpButton()
    let reviewImage = NSImageView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let primary = NSScreen.screens.first else { NSApp.terminate(nil); return }
        displayScreen = primary
        overlay = FloatingPanel(contentRect: primary.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = false
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.hidesOnDeactivate = false; overlay.ignoresMouseEvents = true
        markingView.frame = CGRect(origin: .zero, size: primary.frame.size); markingView.controller = self
        overlay.contentView = markingView; overlay.orderFrontRegardless()
        buildToolbar(primary)
        capture.onError = { [weak self] message in self?.streamStarted = false; self?.setMode(0); self?.status("Capture stopped: \(message). Close and reopen /annotate to retry.") }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signals.append(source)
        }
        signal(SIGUSR1, SIG_IGN)
        let restore = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        restore.setEventHandler { [weak self] in self?.restoreWindows() }; restore.resume(); signals.append(restore)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Pi can't signal the LaunchServices-detached app via its `open` child, so expose the real PID.
        if let directory = outputDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "\(getpid())".write(to: directory.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > flag + 1 {
            do {
                try runSelfTest(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                print("Native smoke passed: click-through modes, readable cards, per-note evidence, masked PNG export")
                NSApp.terminate(nil)
            } catch {
                fputs("Native smoke failed: \(error)\n", stderr)
                exit(1)
            }
        } else { status("Choose a tool to enable local screen capture. Nothing is shared until Send.") }
    }

    func buildToolbar(_ screen: NSScreen) {
        let size = CGSize(width: min(940, screen.visibleFrame.width - 32), height: 108)
        toolbar = FloatingPanel(contentRect: CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 16, width: size.width, height: size.height), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.title = "pi-desktop-annotate"
        toolbar.titleVisibility = .hidden
        toolbar.titlebarAppearsTransparent = true
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = true
        toolbar.delegate = self
        toolbar.isReleasedWhenClosed = false
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.isMovableByWindowBackground = true; toolbar.hidesOnDeactivate = false
        let content = SurfaceView(size: size, radius: 28)
        toolbar.contentView = content
        sourceButton.frame = CGRect(x: 96, y: size.height - 39, width: 210, height: 28)
        sourceButton.bezelStyle = .rounded
        sourceButton.target = self; sourceButton.action = #selector(showCaptureSource)
        sourceButton.toolTip = "Choose desktop or window · Manage screen access"
        sourceButton.cell?.lineBreakMode = .byTruncatingTail
        content.addSubview(sourceButton)
        buildSourcePopover()
        tools.frame = CGRect(x: 14, y: 12, width: size.width - 28, height: 46)
        tools.selectedSegment = 0; tools.target = self; tools.action = #selector(changeMode)
        content.addSubview(tools)
        let actions: [(String, String, CGFloat, Selector)] = [
            ("Undo", "arrow.uturn.backward", 84, #selector(undoLast)),
            ("Clear", "trash", 84, #selector(clear)),
            ("Review", "list.bullet", 126, #selector(reviewFeedback)),
            ("Send", "arrow.up", 104, #selector(sendFeedback))
        ]
        var x = size.width - 14 - actions.reduce(0, { $0 + $1.2 }) - 24
        for (label, symbol, width, selector) in actions {
            let button = ActionButton(label, symbol: symbol, primary: label == "Send", target: self, action: selector)
            button.frame = CGRect(x: x, y: size.height - 42, width: width, height: 34)
            button.font = .systemFont(ofSize: 14, weight: label == "Send" ? .semibold : .regular)
            button.toolTip = ["Undo": "Undo the last annotation", "Clear": "Discard this local batch", "Review": "Preview the exact masked images before sending", "Send": "Send notes and masked evidence to Pi"][label]
            actionButtons[label] = button; content.addSubview(button)
            x += width + 8
        }
        statusLabel.frame = CGRect(x: 22, y: 5, width: size.width - 44, height: 36)
        statusLabel.textColor = AnnotateStyle.secondary
        statusLabel.font = .systemFont(ofSize: 15); statusLabel.maximumNumberOfLines = 2; statusLabel.lineBreakMode = .byWordWrapping
        // Routine hints stay out of the toolbar; failures use an actionable alert.
        toolbar.orderFrontRegardless()
        // Retain native close/minimize semantics, positioned inside the custom header.
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = toolbar.standardWindowButton(type) {
                button.setFrameOrigin(CGPoint(x: 20 + CGFloat(index) * 24, y: 3))
            }
        }
        refreshActions()
    }

    func buildSourcePopover() {
        let controller = NSViewController()
        controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 210))
        let title = NSTextField(labelWithString: "Capture source")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = CGRect(x: 18, y: 173, width: 344, height: 22)
        sourceHint.frame = CGRect(x: 18, y: 88, width: 344, height: 76)
        sourceHint.font = .systemFont(ofSize: 13); sourceHint.textColor = .secondaryLabelColor
        sourcePicker.frame = CGRect(x: 18, y: 56, width: 344, height: 28)
        sourcePicker.cell?.lineBreakMode = .byTruncatingTail
        sourcePicker.menu?.minimumWidth = 344
        sourceStart.frame = CGRect(x: 144, y: 14, width: 218, height: 32)
        sourceStart.bezelStyle = .rounded
        sourceStart.target = self; sourceStart.action = #selector(startSelectedSource)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCaptureSource))
        cancel.frame = CGRect(x: 18, y: 14, width: 100, height: 32); cancel.bezelStyle = .rounded
        for view in [title, sourceHint, sourcePicker, sourceStart, cancel] { controller.view.addSubview(view) }
        sourcePopover.contentViewController = controller; sourcePopover.behavior = .transient; sourcePopover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) { pendingMode = 0 }

    @objc func cancelCaptureSource() {
        pendingMode = 0
        sourcePopover.close()
        status("Capture selection cancelled. Nothing sent; choose a tool whenever you’re ready.")
    }

    @objc func showCaptureSource() {
        guard !captureBusy else { return }
        sourcePopover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .minY)
        Task { await loadCaptureSources() }
    }

    func loadCaptureSources() async {
        guard !captureBusy else { return }
        sourcePicker.isEnabled = false; sourceStart.isEnabled = false
        sourcePicker.removeAllItems(); sourceWindows = []
        sourcePicker.addItem(withTitle: "Entire desktop · primary display")
        guard CGPreflightScreenCaptureAccess() else {
            sourceHint.stringValue = "Screen access is needed for annotation tools. Enable it here, then choose a desktop or window. Images stay local until Send."
            sourceStart.title = "Enable Screen Access"; sourceStart.isEnabled = true
            return
        }
        sourceHint.stringValue = "Loading available windows…"
        captureBusy = true
        defer { captureBusy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            sourceWindows = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 && !($0.title ?? "").isEmpty
            }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            for window in sourceWindows {
                let name = "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Window")"
                sourcePicker.addItem(withTitle: String(name.prefix(65)) + (name.count > 65 ? "…" : ""))
                sourcePicker.lastItem?.toolTip = name
            }
            if let selectedWindow, let index = sourceWindows.firstIndex(where: { $0.windowID == selectedWindow.windowID }) { sourcePicker.selectItem(at: index + 1) }
            let hasContent = !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty
            sourceHint.stringValue = hasContent ? "Send or clear this batch before changing source, so evidence stays aligned." : "Choose your desktop or a single window. Window capture excludes other apps. Images stay local until Send."
            sourcePicker.isEnabled = !hasContent; sourceStart.isEnabled = !hasContent
            sourceStart.title = "Start annotating"
        } catch {
            sourceHint.stringValue = "Screen access is unavailable. Enable Pi Desktop Annotate in System Settings → Privacy & Security → Screen Recording, then try again. macOS may require an app restart."
            sourceStart.title = "Open Settings"; sourceStart.isEnabled = true
        }
    }

    @objc func startSelectedSource() {
        guard !captureBusy else { return }
        if sourceStart.title == "Open Settings" {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            if CGRequestScreenCaptureAccess() { Task { await loadCaptureSources() } }
            else {
                sourceHint.stringValue = "Screen access wasn’t enabled. You can keep the toolbar open and enable it in System Settings when ready. Nothing has been sent."
                sourceStart.title = "Open Settings"
            }
            return
        }
        guard notes.isEmpty && masks.isEmpty && strokes.isEmpty else { return }
        let index = sourcePicker.indexOfSelectedItem
        guard index >= 0, index <= sourceWindows.count else { return }
        let window = index == 0 ? nil : sourceWindows[index - 1]
        captureBusy = true; sourceStart.isEnabled = false; sourcePicker.isEnabled = false
        Task { [self] in
            defer { captureBusy = false }
            targetTimer?.invalidate(); streamStarted = false; setMode(0)
            await capture.stop()
            do {
                displayScreen = NSScreen.screens.first!
                let id = (displayScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                try await capture.start(displayID: id, window: window)
                guard sourcePopover.isShown else { await capture.stop(); return }
                selectedWindow = window
                captureSource = window.map { "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Window")" } ?? "Desktop"
                sourceButton.title = String(captureSource.prefix(24)) + " ▾"
                sourceButton.toolTip = "Capturing: \(captureSource)"
                if let window { positionOverlay(window.frame) }
                else { overlay.setFrame(displayScreen.frame, display: true); markingView.frame = CGRect(origin: .zero, size: displayScreen.frame.size) }
                overlay.orderFrontRegardless(); streamStarted = true
                if window != nil {
                    targetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateWindowTarget() }
                    }
                }
                let requested = pendingMode; pendingMode = 0
                sourcePopover.close()
                if let window { activateTarget(window) }
                setMode(requested)
            } catch {
                sourceHint.stringValue = "Couldn’t start capture. Try again or choose another source. \(error.localizedDescription)"
                sourceStart.isEnabled = true; sourcePicker.isEnabled = true
            }
        }
    }

    func activateTarget(_ window: SCWindow) {
        guard let pid = window.owningApplication?.processID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [])
        // Raising a specific window requires Accessibility. Use it only if already
        // granted; screen capture must not introduce another permission prompt.
        guard AXIsProcessTrusted(), let title = window.title, !title.isEmpty else { return }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { candidate in
            var candidateTitle: CFTypeRef?
            return AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &candidateTitle) == .success &&
                (candidateTitle as? String) == title
        }
        // Do not raise an arbitrary window when titles are ambiguous.
        if matches.count == 1 { AXUIElementPerformAction(matches[0], kAXRaiseAction as CFString) }
    }

    func positionOverlay(_ frame: CGRect) {
        // ScreenCaptureKit uses top-left global coordinates, AppKit uses bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let appFrame = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        overlay.setFrame(appFrame, display: true)
        markingView.frame = CGRect(origin: .zero, size: appFrame.size)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(appFrame) }) { displayScreen = screen }
    }

    func updateWindowTarget() {
        guard let selectedWindow, streamStarted else { return }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], selectedWindow.windowID) as? [[String: Any]]
        guard let item = info?.first, let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else {
            stopWindowTarget("Capture stopped: the selected window was closed. Reopen /annotate to choose another source.")
            return
        }
        guard abs(frame.width - selectedWindow.frame.width) < 1 && abs(frame.height - selectedWindow.frame.height) < 1 else {
            stopWindowTarget("Capture stopped: the selected window was resized. Send existing notes or reopen /annotate to capture its new size.")
            return
        }
        positionOverlay(frame)
    }

    func stopWindowTarget(_ message: String) {
        streamStarted = false; targetTimer?.invalidate(); setMode(0); overlay.orderOut(nil)
        Task { await capture.stop() }
        status(message)
    }

    func status(_ text: String) {
        statusLabel.stringValue = text
        toolbar?.contentView?.toolTip = text
        let failures = ["Cannot", "Capture stopped", "Maximum", "Waiting", "Write text", "No current", "Export failed", "Display configuration", "Screen capture is not ready", "Mask limit", "Drawing limit"]
        if failures.contains(where: { text.hasPrefix($0) }) {
            let alert = NSAlert(); alert.messageText = "pi-desktop-annotate"; alert.informativeText = text
            alert.alertStyle = .warning; alert.addButton(withTitle: "OK")
            alert.window.level = NSWindow.Level(rawValue: toolbar.level.rawValue + 1)
            alert.runModal()
        }
    }
    func refreshActions() {
        let hasContent = !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty
        actionButtons["Undo"]?.isEnabled = !undo.isEmpty
        for name in ["Clear", "Review", "Send"] { actionButtons[name]?.isEnabled = hasContent && !sending }
        actionButtons["Review"]?.badge = notes.count
        for button in actionButtons.values { button.needsDisplay = true }
    }
    @objc func changeMode() { setMode(tools.selectedSegment) }
    func setMode(_ value: Int) {
        guard !sending else { return }
        if value != 0 && !streamStarted {
            pendingMode = value; tools.selectedSegment = 0
            showCaptureSource(); return
        }
        markingView.cancelGesture(); mode = value; tools.selectedSegment = value
        overlay.ignoresMouseEvents = value == 0
        if value == 0 { status("Interact · Click and scroll in your apps. Notes stay visible. Nothing is shared until Send.") }
        else { status(["", "Click anywhere to drop a pinned note.", "Drag to select a region and attach a note.", "Draw anywhere. Your apps keep running underneath.", "Drag to mask private content in every exported image.", "Drag to crop evidence and attach a note. Only the selected area is shared for this note."][value]) }
    }
    func addNote(region: CGRect, frame: EvidenceFrame, cropped: Bool = false) {
        guard notes.count < 12 else { status("Maximum 12 notes per batch. Send these first."); return }
        var frames = Set(notes.filter { !$0.cropped }.map { $0.evidence.id })
        if !cropped { frames.insert(frame.id) }
        let imageCount = frames.count + notes.filter { $0.cropped }.count + (cropped ? 1 : 0)
        guard imageCount <= 8 else { status("Maximum 8 evidence images per batch. Send these notes first."); return }
        let note = Note(id: nextID, region: region, evidence: frame, cropped: cropped); nextID += 1
        notes.append(note); undo.append(.note(note.id)); trimUndo()
        cards[note.id] = NoteCard(note: note, screen: displayScreen, controller: self)
        markingView.needsDisplay = true; refreshActions()
    }
    func updateNote(id: Int, kind: String, text: String) {
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index].kind = kind; notes[index].text = text }
    }
    func deleteNote(_ id: Int) {
        cards.removeValue(forKey: id)?.panel.orderOut(nil); notes.removeAll { $0.id == id }
        undo.removeAll { if case .note(let noteID) = $0 { return noteID == id }; return false }
        markingView.needsDisplay = true; refreshActions()
    }
    func addMask(_ rect: CGRect, evidence: EvidenceFrame? = nil) {
        guard masks.count < 100 else { status("Mask limit reached. Send this batch first."); return }
        if markEvidence == nil { markEvidence = evidence }
        masks.append(rect); undo.append(.mask); trimUndo()
    }
    func addStroke(_ stroke: Stroke, evidence: EvidenceFrame? = nil) {
        guard strokes.count < 100, strokes.reduce(0, { $0 + $1.points.count }) < 20000 else { status("Drawing limit reached. Send this batch first."); return }
        if markEvidence == nil { markEvidence = evidence }
        strokes.append(stroke); undo.append(.stroke); trimUndo()
    }
    func trimUndo() { if undo.count > 40 { undo.removeFirst() }; refreshActions() }
    @objc func undoLast() {
        guard let last = undo.popLast() else { return }
        switch last { case .note(let id): deleteNote(id); case .mask: if !masks.isEmpty { masks.removeLast() }; case .stroke: if !strokes.isEmpty { strokes.removeLast() } }
        if masks.isEmpty && strokes.isEmpty { markEvidence = nil }
        markingView.needsDisplay = true; refreshActions()
    }
    func confirm(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc func clear() {
        if !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty {
            guard confirm("Discard this batch?", "This removes unsent notes, drawings, masks, and retained evidence.") else { return }
        }
        reviewPanel?.close()
        for card in cards.values { card.panel.orderOut(nil) }; cards = [:]; notes = []; masks = []; strokes = []; undo = []; markEvidence = nil
        markingView.cancelGesture(); refreshActions(); status("Cleared. Your apps are still running; choose a tool to add new feedback.")
    }
    @objc func closeApp() {
        if !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty {
            guard confirm("Close without sending?", "Unsent notes and evidence will be discarded.") else { return }
        }
        NSApp.terminate(nil)
    }
    @objc func reviewFeedback() {
        guard !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty else { status("Add a note, drawing, or mask first."); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try exportBundle(notes: notes, masks: masks, strokes: strokes, fallback: markEvidence ?? capture.snapshot(), to: directory)
            let doc = try JSONDecoder().decode(BundleDocument.self, from: Data(contentsOf: directory.appendingPathComponent("annotations.json")))
            let images = try doc.evidence.map { item -> NSImage in
                guard let image = NSImage(data: try Data(contentsOf: directory.appendingPathComponent(item.file))) else { throw CocoaError(.fileReadCorruptFile) }
                return image
            }
            reviewPanel?.close()
            reviewImages = images
            reviewNotes = doc.evidence.map { item in doc.notes.filter { $0.evidenceId == item.id } }
            let size = CGSize(width: min(1120, displayScreen.visibleFrame.width - 60), height: min(680, displayScreen.visibleFrame.height - 100))
            let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "pi-desktop-annotate · Review screenshots"
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = AnnotateStyle.background; panel.titlebarAppearsTransparent = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 5)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.delegate = self
            panel.contentMinSize = CGSize(width: min(760, size.width), height: min(420, size.height))
            let content = NSView(frame: CGRect(origin: .zero, size: size)); panel.contentView = content
            reviewPicker.removeAllItems()
            for (index, item) in doc.evidence.enumerated() {
                let ids = doc.notes.filter { $0.evidenceId == item.id }.map { "#\($0.id)" }.joined(separator: ", ")
                reviewPicker.addItem(withTitle: "Screenshot \(index + 1) · \(ids.isEmpty ? "Drawings and masks" : ids)")
            }
            reviewPicker.frame = CGRect(x: 12, y: size.height - 44, width: size.width - 24, height: 32)
            reviewPicker.autoresizingMask = [.width, .minYMargin]; reviewPicker.font = .systemFont(ofSize: 15)
            reviewPicker.target = self; reviewPicker.action = #selector(reviewChanged); content.addSubview(reviewPicker)
            let sidebarWidth = min(300, size.width * 0.32)
            reviewImage.frame = CGRect(x: 12, y: 12, width: size.width - sidebarWidth - 36, height: size.height - 66)
            reviewImage.autoresizingMask = [.width, .height]; reviewImage.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(reviewImage)
            let scroll = NSScrollView(frame: CGRect(x: size.width - sidebarWidth - 12, y: 12, width: sidebarWidth, height: size.height - 66))
            scroll.autoresizingMask = [.minXMargin, .height]
            scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
            scroll.drawsBackground = false; scroll.wantsLayer = true
            scroll.layer?.backgroundColor = AnnotateStyle.control.cgColor; scroll.layer?.cornerRadius = 14
            reviewNotesText.frame = scroll.bounds; reviewNotesText.minSize = scroll.contentSize
            reviewNotesText.maxSize = CGSize(width: sidebarWidth, height: .greatestFiniteMagnitude)
            reviewNotesText.isVerticallyResizable = true; reviewNotesText.isHorizontallyResizable = false
            reviewNotesText.autoresizingMask = [.width]; reviewNotesText.textContainer?.widthTracksTextView = true
            reviewNotesText.isEditable = false; reviewNotesText.isSelectable = true; reviewNotesText.drawsBackground = false
            reviewNotesText.textContainerInset = CGSize(width: 14, height: 16)
            reviewNotesText.setAccessibilityLabel("Notes attached to the selected evidence")
            scroll.documentView = reviewNotesText; content.addSubview(scroll)
            reviewPicker.selectItem(at: 0); reviewChanged()
            reviewPanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
            status("Review every evidence image. Masks cover fixed screen locations, not moving private content.")
        } catch { status("Cannot review evidence: \(error.localizedDescription)") }
    }
    @objc func reviewChanged() {
        let index = reviewPicker.indexOfSelectedItem
        guard reviewImages.indices.contains(index), reviewNotes.indices.contains(index) else { return }
        reviewImage.image = reviewImages[index]
        let text = NSMutableAttributedString()
        func append(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = AnnotateStyle.text) {
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 10; paragraph.lineSpacing = 3
            text.append(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        append("NOTES · \(reviewNotes[index].count)\n", size: 11, weight: .semibold, color: AnnotateStyle.secondary)
        if reviewNotes[index].isEmpty {
            append("No notes on this image.\n", size: 15)
            append("This evidence contains drawings or privacy masks.\n", size: 13, color: AnnotateStyle.secondary)
        }
        for note in reviewNotes[index] {
            append("#\(note.id)  \(note.kind.capitalized)\n", size: 15, weight: .semibold, color: AnnotateStyle.blue)
            append(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty draft — add text before sending.\n\n" : "\(note.text)\n\n", size: 15)
        }
        reviewNotesText.textStorage?.setAttributedString(text)
        reviewNotesText.sizeToFit(); reviewNotesText.scrollToBeginningOfDocument(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === toolbar { closeApp(); return false }
        return true
    }
    func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === toolbar else { return }
        setMode(0)
        overlay.orderOut(nil); reviewPanel?.orderOut(nil)
        for card in cards.values { card.panel.orderOut(nil) }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === toolbar else { return }
        restoreWindows()
    }
    func restoreWindows() {
        if toolbar.isMiniaturized { toolbar.deminiaturize(nil) }
        overlay.orderFrontRegardless()
        for card in cards.values where card.isEditing { card.panel.orderFrontRegardless() }
        reviewPanel?.orderFrontRegardless(); toolbar.orderFrontRegardless()
    }
    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSWindow, panel === reviewPanel {
            reviewImages = []; reviewNotes = []; reviewNotesText.string = ""; reviewImage.image = nil; reviewPanel = nil
        }
    }

    func sendConfirmation() -> NSAlert {
        let imageCount = Set(notes.filter { !$0.cropped }.map { $0.evidence.id }).count + notes.filter { $0.cropped }.count
        let alert = NSAlert()
        alert.messageText = "Send to Pi?"
        let noteSummary = notes.count == 1 ? "1 note" : "\(notes.count) notes"
        let count = max(1, imageCount)
        let imageSummary = count == 1 ? "1 screenshot" : "\(count) screenshots"
        alert.informativeText = "\(noteSummary) and \(imageSummary) from \(captureSource).\n\nYour notes and saved screenshots will be shared with Pi and your model provider. Check screenshots and note text for private information. Masks hide fixed locations, not moving content."
        alert.addButton(withTitle: "Send feedback")
        alert.addButton(withTitle: "Keep editing")
        alert.addButton(withTitle: "Review screenshots")
        alert.buttons[0].keyEquivalent = "" // Avoid sending accidentally with Return.
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.window.level = NSWindow.Level(rawValue: toolbar.level.rawValue + 1)
        return alert
    }

    @objc func sendFeedback() {
        guard !sending else { return }
        guard !notes.isEmpty || !masks.isEmpty || !strokes.isEmpty else { status("Add a note, drawing, or mask first."); return }
        guard notes.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 2000 }) else { status("Write text in every note card, or close empty cards."); return }
        let fallback = markEvidence ?? capture.snapshot()
        guard !notes.isEmpty || fallback != nil else { status("No current evidence frame available. Check capture permission."); return }
        let response = sendConfirmation().runModal()
        if response == .alertThirdButtonReturn { reviewFeedback(); return }
        guard response == .alertFirstButtonReturn else { return }
        let output: URL
        if let directory = outputDirectory { output = directory }
        else {
            let dialog = NSOpenPanel(); dialog.canChooseDirectories = true; dialog.canChooseFiles = false; dialog.canCreateDirectories = true
            dialog.message = "Choose where to save the feedback bundle"
            guard dialog.runModal() == .OK, let url = dialog.url else { return }
            output = url.appendingPathComponent("pi-feedback-\(Int(Date().timeIntervalSince1970))")
        }
        sending = true; refreshActions(); status("Exporting masked evidence…")
        do {
            try exportBundle(notes: notes, masks: masks, strokes: strokes, fallback: fallback, to: output)
            if outputDirectory == nil { NSWorkspace.shared.open(output) }
            NSApp.terminate(nil)
        } catch { sending = false; refreshActions(); status("Export failed: \(error.localizedDescription)") }
    }
    @objc func screenChanged() {
        streamStarted = false; setMode(0)
        status("Display configuration changed. Close and reopen /annotate before adding more evidence.")
        Task { await capture.stop() }
    }
    func runSelfTest(to directory: URL) throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try check(!streamStarted && mode == 0, "Launch must not capture or request screen access")
        try check(sourceButton.superview != nil && sourcePopover.contentViewController != nil, "Capture settings must be accessible from the toolbar")
        pendingMode = 3; cancelCaptureSource()
        try check(pendingMode == 0 && !streamStarted && overlay.ignoresMouseEvents, "Cancelling source selection must leave the app open and click-through without capture")
        try check(toolbar.styleMask.contains(.closable) && toolbar.styleMask.contains(.miniaturizable), "Toolbar must expose close and minimize controls")
        try check(tools.label(forSegment: 0) == "Interact", "Click-through tool must have a clear label")
        try check(overlay.ignoresMouseEvents, "Interact must pass through clicks")
        streamStarted = true; setMode(1)
        try check(!overlay.ignoresMouseEvents, "Note mode must accept clicks")
        setMode(5)
        try check(!overlay.ignoresMouseEvents && tools.label(forSegment: 5) == "Crop", "Crop tool must accept drag input")
        setMode(1)
        let cg = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(NSColor.white.cgColor); cg.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = cg.makeImage()!
        addNote(region: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), frame: EvidenceFrame(id: 1, image: image, capturedAt: Date(timeIntervalSince1970: 1000)))
        updateNote(id: 1, kind: "bug", text: "First popup evidence")
        try check(cards[1]?.picker.font?.pointSize == 16, "Category font must be readable")
        addNote(region: CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1), frame: EvidenceFrame(id: 2, image: image, capturedAt: Date(timeIntervalSince1970: 1001)))
        updateNote(id: 2, kind: "change", text: "Later application state")
        addMask(CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1))
        addStroke(Stroke(points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.4, y: 0.8)]))
        setMode(0)
        try check(overlay.ignoresMouseEvents && notes.count == 2, "Use apps must preserve notes")
        windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: toolbar))
        try check(!overlay.isVisible && cards.values.allSatisfy { !$0.panel.isVisible } && mode == 0, "Minimizing must hide annotations and release pointer input")
        restoreWindows()
        try check(overlay.isVisible && cards.values.allSatisfy { $0.panel.isVisible } && notes.count == 2, "Restoring must preserve drafts")
        reviewFeedback()
        try check(reviewImages.count == 2, "Review must show both evidence frames")
        try check(reviewNotesText.string.contains("#1  Bug") && reviewNotesText.string.contains("First popup evidence") && !reviewNotesText.string.contains("Later application state"), "Review must list the selected image's notes with their original pin numbers")
        reviewPicker.selectItem(at: 1); reviewChanged()
        try check(reviewNotesText.string.contains("#2  Change") && reviewNotesText.string.contains("Later application state") && !reviewNotesText.string.contains("First popup evidence"), "Switching evidence must switch the numbered note list")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let view = reviewPanel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("ui-review.png"))
        }
        reviewPanel?.close()
        try check(reviewImages.isEmpty, "Closing review must release preview images")
        try check(toolbar.contentView!.bounds.height == 108 && tools.frame.height == 46, "Toolbar must use the compact header-action layout")
        try check(actionButtons["Send"]!.frame.maxX == toolbar.contentView!.bounds.width - 14, "Send must be anchored to the far right")
        try check(actionButtons.values.allSatisfy { $0.frame.minY > tools.frame.maxY }, "Batch actions must sit in the window header")
        try check(actionButtons["Review"]?.badge == 2, "Review badge must track notes")
        try check(statusLabel.superview == nil, "Toolbar must not show the routine hint line")
        let confirmation = sendConfirmation()
        try check(confirmation.buttons.map { $0.title } == ["Send feedback", "Keep editing", "Review screenshots"], "Send must offer explicit send, edit, and review actions")
        try check(confirmation.informativeText.contains("2 notes and 2 screenshots") && confirmation.informativeText.contains(captureSource), "Send must summarize the actual batch and capture source")
        try check(confirmation.buttons[0].keyEquivalent.isEmpty, "Return must not accidentally send feedback")
        let root = toolbar.contentView!.superview!
        for button in actionButtons.values {
            let point = root.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), from: toolbar.contentView)
            let hit = root.hitTest(point)
            try check(hit === button || hit?.isDescendant(of: button) == true, "Header actions must receive clicks instead of dragging the window")
        }
        let card = cards[1]!
        try check(!card.saveButton.isEnabled, "Empty notes must not be saved")
        card.textView.string = "First popup evidence"
        card.picker.selectItem(at: 1)
        card.refreshEditor(); card.save()
        try check(!card.panel.isVisible && !card.isEditing && notes.count == 2, "Save must dismiss the editor without discarding evidence")
        card.show(); card.textView.string = "Unwanted edit"; card.changeKind(); card.cancel()
        try check(notes[0].text == "First popup evidence" && !card.panel.isVisible, "Cancel must restore the last saved local draft")
        card.show()
        try check(card.panel.isVisible && card.isEditing, "Saved pins must reopen for editing")
        addNote(region: CGRect(x: 0.3, y: 0.4, width: 0, height: 0), frame: notes[0].evidence)
        cards[3]!.cancel()
        try check(notes.count == 2 && cards[3] == nil && actionButtons["Review"]?.badge == 2, "Canceling a new note must discard it and update the badge")
        card.show()
        // Keep deterministic UI artifacts alongside the smoke-test evidence for visual inspection.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, view) in [("ui-toolbar", toolbar.contentView!.superview ?? toolbar.contentView!), ("ui-note", card.panel.contentView!)] {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        try exportBundle(notes: notes, masks: masks, strokes: strokes, fallback: nil, to: directory)
        for id in [1, 2] {
            let bitmap = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("evidence-\(id).png")))!
            let hidden = bitmap.colorAt(x: 15, y: 25)!.usingColorSpace(.deviceRGB)!
            let visible = bitmap.colorAt(x: 15, y: 75)!.usingColorSpace(.deviceRGB)!
            try check(hidden.redComponent < 0.01 && hidden.greenComponent < 0.01 && hidden.blueComponent < 0.01, "Mask must be opaque at top-left image coordinates")
            try check(visible.redComponent > 0.99, "Mask must not be vertically mirrored")
        }
        let cropDirectory = directory.appendingPathComponent("cropped")
        let cropped = Note(id: 10, region: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.5), evidence: notes[0].evidence, cropped: true, text: "Cropped detail")
        let secondCrop = Note(id: 11, region: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2), evidence: notes[0].evidence, cropped: true, text: "Another crop of the same frame")
        try exportBundle(notes: [cropped, secondCrop], masks: masks, strokes: strokes, fallback: nil, to: cropDirectory)
        let doc = try JSONDecoder().decode(BundleDocument.self, from: Data(contentsOf: cropDirectory.appendingPathComponent("annotations.json")))
        try check(doc.evidence.count == 2 && doc.evidence.allSatisfy { $0.width < 100 && $0.height < 100 }, "Crop-only batches must never export the full frame")
        try check(doc.notes[0].evidenceId != doc.notes[1].evidenceId, "Different crops of one capture must remain separate evidence")
        let first = doc.evidence.first { $0.id == doc.notes[0].evidenceId }!
        try check(first.width == 51 && first.height == 51 && doc.notes[0].region.x == 0.5 && doc.notes[0].region.y == 0.5, "Crop must round outward and rebase note coordinates")
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: cropDirectory.appendingPathComponent(first.file)))!
        let hidden = bitmap.colorAt(x: 3, y: 13)!.usingColorSpace(.deviceRGB)!
        let visible = bitmap.colorAt(x: 3, y: 43)!.usingColorSpace(.deviceRGB)!
        try check(hidden.redComponent < 0.01 && visible.redComponent > 0.99, "Cropped masks must retain top-left orientation and opacity")
        let mixedDirectory = directory.appendingPathComponent("mixed")
        try exportBundle(notes: [notes[0], cropped, secondCrop], masks: masks, strokes: strokes, fallback: nil, to: mixedDirectory)
        let mixed = try JSONDecoder().decode(BundleDocument.self, from: Data(contentsOf: mixedDirectory.appendingPathComponent("annotations.json")))
        try check(mixed.evidence.count == 3 && mixed.evidence.filter { $0.width == 100 }.count == 1, "Normal notes must retain full context independently of cropped notes")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        targetTimer?.invalidate()
        // Sentinel marking a clean shutdown; written after any Send export, so annotations.json
        // (which Pi checks first) still takes priority over treating this as a cancel.
        if let directory = outputDirectory { try? Data().write(to: directory.appendingPathComponent("closed")) }
        Task { await capture.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

func resolveOutputDirectory() -> URL? {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--output"), args.count > flag + 1 { return URL(fileURLWithPath: args[flag + 1]) }
    if let path = ProcessInfo.processInfo.environment["PI_ANNOTATE_OUTPUT"] { return URL(fileURLWithPath: path) }
    return nil
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AnnotationController()
    app.delegate = controller
    app.run()
    withExtendedLifetime(controller) {}
}
