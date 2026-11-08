import AppKit

struct Note {
    let id: Int
    let region: CGRect // normalized, top-left origin
    let evidence: EvidenceFrame
    var cropped = false // Export only this note's region, never the full frame.
    var kind = "note"
    var text = ""
}
struct Stroke { var points: [CGPoint] } // normalized, top-left origin
struct PixelRegion: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
struct ExportNote: Codable {
    let id: Int; let kind: String; let text: String; let evidenceId: Int; let region: PixelRegion
}
struct ExportEvidence: Codable {
    let id: Int; let file: String; let width: Int; let height: Int; let capturedAt: String
}
struct BundleDocument: Codable {
    let version: Int; let notes: [ExportNote]; let evidence: [ExportEvidence]
}

func pixelRegion(_ rect: CGRect, _ width: Int, _ height: Int) -> PixelRegion {
    PixelRegion(x: rect.minX * Double(width), y: rect.minY * Double(height), width: rect.width * Double(width), height: rect.height * Double(height))
}

func exportBundle(notes: [Note], masks: [CGRect], strokes: [Stroke], fallback: EvidenceFrame?, to directory: URL) throws {
    var frames: [Int: EvidenceFrame] = [:]
    for note in notes { frames[note.evidence.id] = note.evidence }
    if frames.isEmpty, let fallback { frames[fallback.id] = fallback }
    // Cropped notes get independent evidence, even when they share a capture frame.
    var noteEvidence: [Int: Int] = [:]
    var crops: [Int: CGRect] = [:]
    var nextEvidenceID = (frames.keys.max() ?? 0) + 1
    for note in notes {
        if note.cropped {
            let id = nextEvidenceID; nextEvidenceID += 1
            let r = pixelRegion(note.region, note.evidence.image.width, note.evidence.image.height)
            let bounds = CGRect(x: 0, y: 0, width: note.evidence.image.width, height: note.evidence.image.height)
            let crop = CGRect(x: r.x, y: r.y, width: r.width, height: r.height).integral.intersection(bounds)
            guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { throw CocoaError(.fileWriteUnknown) }
            frames[id] = note.evidence; crops[id] = crop; noteEvidence[note.id] = id
        } else { noteEvidence[note.id] = note.evidence.id }
    }
    if !notes.isEmpty { frames = frames.filter { Set(noteEvidence.values).contains($0.key) } }
    guard !frames.isEmpty, frames.count <= 8, notes.count <= 12 else {
        throw NSError(domain: "Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keep each batch to 12 notes and 8 different evidence frames."])
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var evidence: [ExportEvidence] = []
    var total = 0
    for id in frames.keys.sorted() {
        let frame = frames[id]!
        let width = frame.image.width, height = frame.image.height
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        cg.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
        cg.setStrokeColor(AnnotateStyle.blue.cgColor); cg.setLineWidth(3)
        cg.setLineCap(.round); cg.setLineJoin(.round)
        for stroke in strokes where stroke.points.count > 1 {
            cg.beginPath()
            cg.move(to: CGPoint(x: stroke.points[0].x * CGFloat(width), y: stroke.points[0].y * CGFloat(height)))
            for point in stroke.points.dropFirst() { cg.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))) }
            cg.strokePath()
        }
        for note in notes where noteEvidence[note.id] == id {
            let r = pixelRegion(note.region, width, height)
            if r.width > 0 && r.height > 0 { cg.stroke(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            drawAnnotationPin(at: CGPoint(x: r.x, y: r.y), id: note.id)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Masks are deliberately last: nothing can draw over hidden pixels.
        cg.setFillColor(NSColor.black.cgColor)
        for mask in masks {
            let r = pixelRegion(mask, width, height)
            cg.fill(CGRect(x: floor(r.x), y: floor(r.y), width: ceil(r.width) + 1, height: ceil(r.height) + 1))
        }
        guard let rendered = cg.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let output: CGImage
        if let crop = crops[id] {
            guard let image = rendered.cropping(to: crop) else { throw CocoaError(.fileWriteUnknown) }
            output = image
        } else { output = rendered }
        guard let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        total += png.count
        guard total <= 20 * 1024 * 1024 else { throw NSError(domain: "Export", code: 2, userInfo: [NSLocalizedDescriptionKey: "Evidence exceeds 20 MB. Send fewer notes at a time."]) }
        let file = "evidence-\(id).png"
        let url = directory.appendingPathComponent(file)
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        evidence.append(ExportEvidence(id: id, file: file, width: output.width, height: output.height, capturedAt: ISO8601DateFormatter().string(from: frame.capturedAt)))
    }
    let exportedNotes = notes.map { n -> ExportNote in
        let id = noteEvidence[n.id]!
        let r = pixelRegion(n.region, n.evidence.image.width, n.evidence.image.height)
        let crop = crops[id] ?? .zero
        let region = PixelRegion(x: r.x - crop.minX, y: r.y - crop.minY, width: r.width, height: r.height)
        return ExportNote(id: n.id, kind: n.kind, text: n.text, evidenceId: id, region: region)
    }
    let doc = BundleDocument(version: 2, notes: exportedNotes, evidence: evidence)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = directory.appendingPathComponent("annotations.json")
    try encoder.encode(doc).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
