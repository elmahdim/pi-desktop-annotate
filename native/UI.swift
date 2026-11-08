import AppKit

// Shared, intentionally opaque surfaces keep feedback legible over any application.
enum AnnotateStyle {
    static let background = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1)
    static let control = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.20, alpha: 1)
    static let selected = NSColor(srgbRed: 0.30, green: 0.31, blue: 0.32, alpha: 1)
    static let border = NSColor.white.withAlphaComponent(0.16)
    static let text = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.65, green: 0.66, blue: 0.67, alpha: 1)
    static let blue = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)

    static func symbol(_ name: String, in rect: CGRect, color: NSColor, size: CGFloat = 17) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    static func label(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let height = (string as NSString).size(withAttributes: attributes).height
        (string as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), withAttributes: attributes)
    }
}

final class SurfaceView: NSView {
    init(size: CGSize, radius: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = AnnotateStyle.background.cgColor
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.borderColor = AnnotateStyle.border.cgColor
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class ActionButton: NSButton {
    var symbolName: String?
    var primary = false
    var plain = false
    var badge = 0 { didSet { needsDisplay = true } }
    var showsKeyboardFocus = false
    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        showsKeyboardFocus = false
        super.mouseDown(with: event)
    }
    override var isFlipped: Bool { true }
    init(_ title: String, symbol: String? = nil, primary: Bool = false, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title; self.symbolName = symbol; self.primary = primary
        self.target = target; self.action = action
        isBordered = false; focusRingType = .none
        font = .systemFont(ofSize: 16, weight: primary ? .semibold : .regular)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        let fill = primary ? AnnotateStyle.blue : AnnotateStyle.control
        if !plain {
            (isHighlighted ? fill.blended(withFraction: 0.15, of: .white)! : fill).withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        }
        let color = (primary ? AnnotateStyle.text : AnnotateStyle.secondary).withAlphaComponent(opacity)
        let textWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        let total = textWidth + (symbolName == nil ? 0 : 28) + (badge > 0 ? 30 : 0)
        let x = (bounds.width - total) / 2
        if let symbolName { AnnotateStyle.symbol(symbolName, in: CGRect(x: x, y: bounds.midY - 9, width: 18, height: 18), color: color) }
        AnnotateStyle.label(title, in: CGRect(x: x + (symbolName == nil ? 0 : 28), y: 0, width: textWidth + 1, height: bounds.height), font: font!, color: color)
        if badge > 0 {
            let rect = CGRect(x: x + total - 22, y: bounds.midY - 11, width: 22, height: 22)
            AnnotateStyle.blue.setFill(); NSBezierPath(ovalIn: rect).fill()
            AnnotateStyle.label(String(badge), in: rect, font: .systemFont(ofSize: 13, weight: .medium), color: .white, alignment: .center)
        }
        if showsKeyboardFocus && window?.firstResponder === self {
            AnnotateStyle.blue.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class ToolStrip: NSControl {
    let labels = ["Interact", "Note", "Region", "Draw", "Mask", "Crop"]
    let symbols = ["cursorarrow", "bubble.left", "rectangle.dashed", "pencil", "lock", "crop"]
    var selectedSegment = 0 { didSet { needsDisplay = true; updateAccessibility() } }
    var showsKeyboardFocus = false
    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return true
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Annotation tool")
        toolTip = "Interact with apps, pin a Note, select a Region, Draw, Mask private content, or Crop evidence. Use arrow keys to change tools."
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func label(forSegment index: Int) -> String { labels[index] }
    func updateAccessibility() { setAccessibilityValue(labels[selectedSegment]) }
    override func draw(_ dirtyRect: NSRect) {
        AnnotateStyle.control.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        let width = bounds.width / CGFloat(labels.count)
        for index in labels.indices {
            let rect = CGRect(x: CGFloat(index) * width + 3, y: 3, width: width - 6, height: bounds.height - 6)
            if index == selectedSegment {
                let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
                AnnotateStyle.selected.setFill(); path.fill()
            }
            let color = index == selectedSegment ? AnnotateStyle.text : AnnotateStyle.secondary
            let textWidth = (labels[index] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
            let x = rect.midX - (textWidth + 28) / 2
            AnnotateStyle.symbol(symbols[index], in: CGRect(x: x, y: rect.midY - 9, width: 18, height: 18), color: color)
            AnnotateStyle.label(labels[index], in: CGRect(x: x + 28, y: rect.minY, width: textWidth + 1, height: rect.height), font: .systemFont(ofSize: 16), color: color)
        }
        if showsKeyboardFocus && window?.firstResponder === self {
            AnnotateStyle.blue.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
            path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        selectedSegment = min(labels.count - 1, max(0, Int(convert(event.locationInWindow, from: nil).x / (bounds.width / CGFloat(labels.count)))))
        sendAction(action, to: target)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            showsKeyboardFocus = true
            selectedSegment = (selectedSegment + (event.keyCode == 124 ? 1 : labels.count - 1)) % labels.count
            sendAction(action, to: target)
        } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformIncrement() -> Bool {
        selectedSegment = (selectedSegment + 1) % labels.count; sendAction(action, to: target); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        selectedSegment = (selectedSegment + labels.count - 1) % labels.count; sendAction(action, to: target); return true
    }
}

final class CategoryPicker: NSPopUpButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        AnnotateStyle.border.setStroke(); path.lineWidth = 1; path.stroke()
        AnnotateStyle.label(titleOfSelectedItem ?? "Note", in: CGRect(x: 16, y: 0, width: bounds.width - 45, height: bounds.height), font: font ?? .systemFont(ofSize: 16), color: AnnotateStyle.text)
        AnnotateStyle.symbol("chevron.down", in: CGRect(x: bounds.width - 25, y: bounds.midY - 6, width: 12, height: 12), color: AnnotateStyle.secondary)
    }
}

// The point of the pin is the exact annotated position. Shared by screen and export.
func drawAnnotationPin(at point: CGPoint, id: Int) {
    let pin = NSBezierPath()
    pin.move(to: point)
    pin.curve(to: CGPoint(x: point.x - 19, y: point.y - 27), controlPoint1: CGPoint(x: point.x - 4, y: point.y), controlPoint2: CGPoint(x: point.x - 19, y: point.y - 19))
    pin.curve(to: CGPoint(x: point.x, y: point.y - 46), controlPoint1: CGPoint(x: point.x - 19, y: point.y - 38), controlPoint2: CGPoint(x: point.x - 11, y: point.y - 46))
    pin.curve(to: CGPoint(x: point.x + 19, y: point.y - 27), controlPoint1: CGPoint(x: point.x + 11, y: point.y - 46), controlPoint2: CGPoint(x: point.x + 19, y: point.y - 38))
    pin.curve(to: point, controlPoint1: CGPoint(x: point.x + 19, y: point.y - 19), controlPoint2: CGPoint(x: point.x + 4, y: point.y))
    pin.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 4; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.set()
    AnnotateStyle.blue.setFill(); pin.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke(); pin.lineWidth = 2; pin.stroke()
    AnnotateStyle.label(String(id), in: CGRect(x: point.x - 18, y: point.y - 43, width: 36, height: 32), font: .systemFont(ofSize: 16, weight: .semibold), color: .white, alignment: .center)
}
