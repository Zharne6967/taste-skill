import AppKit
import AVFoundation
import PDFKit

/// `ShiftDrop --selftest <dir>` runs every non-interactive wheel action and the editors' render code
/// on generated files, and exits non-zero if anything fails. CI runs it on a real Mac.
@MainActor
enum SelfTest {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static var passed = 0
    private static var failed: [String] = []

    static func run(in root: URL) async -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        for directory in [fixtures, scratch] {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        print("ShiftDrop self-test on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("ImageIO writes: \(Codecs.writableImageTypes.sorted().joined(separator: ", "))")
        print("Wheel formats for JPG: \(Catalog.formats(for: .image, source: .jpg).map(\.label).joined(separator: " "))")

        let files: [(URL, FileKind)]
        let photo: URL, rotated: URL, report: URL, clip: URL, logo: URL
        do {
            photo = try Fixtures.photo(at: fixtures.appendingPathComponent("Photo.jpg"))
            rotated = try Fixtures.rotatedPhoto(at: fixtures.appendingPathComponent("Rotated.jpg"))
            logo = try Fixtures.logo(at: fixtures.appendingPathComponent("Logo.png"))
            let notes = try Fixtures.notes(at: fixtures.appendingPathComponent("Notes.txt"))
            let page = try Fixtures.html(at: fixtures.appendingPathComponent("Page.html"))
            let letter = try Fixtures.docx(at: fixtures.appendingPathComponent("Letter.docx"))
            report = try Fixtures.report(at: fixtures.appendingPathComponent("Report.pdf"))
            let scan = fixtures.appendingPathComponent("Scan.pdf")
            try ImageEngine.makePDF(from: [photo], to: scan)
            let tone = try Fixtures.tone(at: fixtures.appendingPathComponent("Tone.wav"))
            clip = try await Fixtures.clip(at: fixtures.appendingPathComponent("Clip.mov"), soundtrack: tone, scratch: scratch)
            files = [(photo, .image), (logo, .image), (notes, .document), (page, .document), (letter, .document),
                     (report, .pdf), (scan, .pdf), (tone, .audio), (clip, .video)]
        } catch {
            print("❌ Couldn't create fixtures: \(error.localizedDescription)")
            return false
        }

        // Every format and every non-interactive tool on the wheel, for every sample file.
        for (file, kind) in files {
            check("FileKind \(file.lastPathComponent)") {
                guard FileKind.of(file) == kind else { throw Failure("detected \(FileKind.of(file).rawValue)") }
                return kind.rawValue
            }
            let output = root.appendingPathComponent("out-" + file.deletingPathExtension().lastPathComponent, isDirectory: true)
            try? manager.createDirectory(at: output, withIntermediateDirectories: true)
            let source = Format.from(url: file)
            var items = Catalog.items(for: kind, source: source, mode: .convert, fileCount: 1)
            items += Catalog.items(for: kind, source: source, mode: .tools, fileCount: 1).filter { item in
                guard case .tool(let tool) = item.action else { return false }
                return !tool.isInteractive && !(tool == .split && file.lastPathComponent == "Scan.pdf")
            }
            for item in items {
                await checkAsync("\(file.lastPathComponent) → \(item.label)") {
                    do {
                        let result = try await ActionRunner.run(item.action, files: [file], kind: kind, override: output)
                        var notes: [String] = []
                        for url in result.outputs { notes.append(try await verify(url)) }
                        if let note = result.note { notes.append(note) }
                        return notes.joined(separator: "; ")
                    } catch AppError.alreadySmall {
                        return "already optimal (expected for generated files)"
                    } catch AppError.noSubject where item.action == .tool(.removeBackground) {
                        return "no subject in the sample (expected)"
                    }
                }
            }
        }

        let checks = root.appendingPathComponent("checks", isDirectory: true)
        try? manager.createDirectory(at: checks, withIntermediateDirectories: true)

        await checkAsync("OCR reads the photo") {
            let result = try await ActionRunner.run(.convert(.txt), files: [photo], kind: .image, override: checks)
            let text = try String(contentsOf: result.outputs[0])
            guard text.uppercased().contains("SHIFTDROP") else { throw Failure("got: \(text.prefix(80))") }
            return text.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        await checkAsync("Scanned PDF → TXT uses OCR") {
            let scan = fixtures.appendingPathComponent("Scan.pdf")
            let result = try await ActionRunner.run(.convert(.txt), files: [scan], kind: .pdf, override: checks)
            let text = try String(contentsOf: result.outputs[0])
            guard text.uppercased().contains("SHIFTDROP") else { throw Failure("got: \(text.prefix(80))") }
            return "ok"
        }
        check("EXIF orientation is applied on load") {
            let loaded = try ImageEngine.load(rotated)
            guard loaded.image.width == 200, loaded.image.height == 300 else {
                throw Failure("\(loaded.image.width)×\(loaded.image.height)")
            }
            return "200×300"
        }
        check("Metadata strip removes camera + GPS") {
            let clean = try ImageEngine.stripMetadata(photo, override: checks)
            guard !ImageEngine.hasIdentifyingMetadata(clean) else { throw Failure("metadata survived") }
            let entries = try ImageEngine.metadataEntries(for: photo).map { $0.0 }
            guard entries.contains("Location"), entries.contains("Camera") else { throw Failure("entries: \(entries)") }
            return clean.lastPathComponent
        }
        check("Metadata strip keeps orientation") {
            let clean = try ImageEngine.stripMetadata(rotated, override: checks)
            let loaded = try ImageEngine.load(clean)
            guard !ImageEngine.hasIdentifyingMetadata(clean) else { throw Failure("GPS survived") }
            guard loaded.image.width == 200, loaded.image.height == 300 else {
                throw Failure("\(loaded.image.width)×\(loaded.image.height)")
            }
            return "upright"
        }
        check("DOCX keeps Polish characters") {
            let text = try DocumentEngine.load(fixtures.appendingPathComponent("Letter.docx")).string
            guard text.contains("Zażółć gęślą jaźń") else { throw Failure("got: \(text.prefix(60))") }
            return "ok"
        }
        check("TXT in Windows-1250 is decoded") {
            let legacy = try Fixtures.legacyNotes(at: scratch.appendingPathComponent("Legacy.txt"))
            let text = try DocumentEngine.readText(legacy)
            guard text == Fixtures.polish else { throw Failure("got: \(text)") }
            return "ok"
        }
        check("Report PDF has several pages") {
            guard let document = PDFDocument(url: report), document.pageCount >= 2 else { throw Failure("too few pages") }
            return "\(document.pageCount) pages"
        }
        await checkAsync("Merge PDF + image") {
            let result = try await ActionRunner.run(.tool(.merge), files: [report, photo], kind: .pdf, override: checks)
            guard let merged = PDFDocument(url: result.outputs[0]), let original = PDFDocument(url: report),
                  merged.pageCount == original.pageCount + 1 else { throw Failure("wrong page count") }
            return "\(merged.pageCount) pages"
        }
        check("Protect PDF") {
            let output = try PDFEngine.protect(report, password: "shift", override: checks)
            guard let document = PDFDocument(url: output), document.isLocked else { throw Failure("not locked") }
            guard document.unlock(withPassword: "shift") else { throw Failure("password rejected") }
            return "locked"
        }
        check("PDF metadata") {
            let entries = try PDFEngine.metadataEntries(for: report)
            _ = try PDFEngine.stripMetadata(report, override: checks)
            return entries.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        }
        await checkAsync("GIF has many frames") {
            let output = checks.appendingPathComponent("Clip.gif")
            try await MediaEngine.makeGIF(from: AVURLAsset(url: clip), to: output)
            guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(source) > 10 else {
                throw Failure("too few frames")
            }
            return "\(CGImageSourceGetCount(source)) frames"
        }
        await checkAsync("Mute removes the soundtrack") {
            let output = try await MediaEngine.mute(clip, override: checks)
            let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
            let video = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            guard audio.isEmpty, !video.isEmpty else { throw Failure("audio: \(audio.count), video: \(video.count)") }
            return "ok"
        }

        // Editors' render code.
        let sample = try? ImageEngine.load(photo).image
        check("Crop") {
            guard let sample, let cropped = ImageEngine.crop(sample, to: CGRect(x: 100, y: 50, width: 400, height: 300)),
                  cropped.width == 400, cropped.height == 300 else { throw Failure("wrong size") }
            return "400×300"
        }
        check("Crop math keeps ratio") {
            let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
            let start = CropMath.fitted(ratio: 16.0 / 9.0, around: CGPoint(x: 600, y: 400), in: bounds)
            for handle in CropHandle.allCases {
                let rect = CropMath.resized(start, handle: handle, delta: CGSize(width: -137, height: -91), ratio: 16.0 / 9.0, in: bounds)
                guard abs(rect.width / rect.height - 16.0 / 9.0) < 0.01, bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else {
                    throw Failure("\(handle) → \(rect)")
                }
            }
            return "ok"
        }
        check("Add background") {
            guard let sample else { throw Failure("no sample") }
            var settings = BackgroundSettings.defaults(for: CGSize(width: sample.width, height: sample.height))
            guard let auto = BackgroundRenderer.render(sample, settings: settings, scale: 1),
                  auto.width == sample.width + Int(settings.padding * 2) else { throw Failure("auto size") }
            settings.ratio = .square
            guard let square = BackgroundRenderer.render(sample, settings: settings, scale: 1), square.width == square.height else {
                throw Failure("square size")
            }
            try ImageEngine.encode(square, as: .png, to: checks.appendingPathComponent("Background.png"))
            return "\(auto.width)×\(auto.height), \(square.width)×\(square.height)"
        }
        check("Edit: warmth and rotation") {
            guard let grey = Fixtures.grey(),
                  let warm = ImageAdjuster.apply(Adjustments(warmth: 1), to: grey),
                  let cool = ImageAdjuster.apply(Adjustments(warmth: -1), to: grey) else { throw Failure("render") }
            let w = pixel(warm, x: 32, y: 32), c = pixel(cool, x: 32, y: 32)
            guard w.r > w.b, c.b > c.r else { throw Failure("warm \(w), cool \(c)") }
            guard let sample, let turned = ImageAdjuster.apply(Adjustments(quarterTurns: 1), to: sample),
                  turned.width == sample.height else { throw Failure("rotation") }
            return String(format: "warm r%.2f b%.2f", w.r, w.b)
        }
        check("Annotate") {
            guard let sample else { throw Failure("no sample") }
            let mark = Annotation(tool: .rectangle, color: RGB(hex: 0xFF0000), width: 12,
                                  points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)])
            guard let drawn = AnnotationRenderer.render([mark], on: sample) else { throw Failure("render") }
            let p = pixel(drawn, x: 100, y: 150)
            guard p.r > 0.8, p.g < 0.3 else { throw Failure("pixel \(p)") }
            return "ok"
        }
        check("Redact") {
            guard let sample else { throw Failure("no sample") }
            let rect = CGRect(x: 100, y: 300, width: 600, height: 200)
            for style in RedactStyle.allCases {
                guard let redacted = Redactor.apply([rect], style: style, to: sample),
                      redacted.width == sample.width else { throw Failure("\(style)") }
                if style == .blackout {
                    let p = pixel(redacted, x: 400, y: 400)
                    guard p.r < 0.1, p.g < 0.1 else { throw Failure("blackout pixel \(p)") }
                }
            }
            return "ok"
        }
        check("Wheel hit testing") {
            let geometry = WheelGeometry(capacity: 4)
            let radius = (geometry.innerRadius + geometry.outerRadius) / 2
            guard geometry.hit(dx: 0, dy: radius, count: 4) == .segment(0),
                  geometry.hit(dx: radius, dy: 0, count: 4) == .segment(1),
                  geometry.hit(dx: 0, dy: -radius, count: 4) == .segment(2),
                  geometry.hit(dx: -radius, dy: 0, count: 4) == .segment(3),
                  geometry.hit(dx: 0, dy: 0, count: 4) == .center,
                  geometry.hit(dx: 400, dy: 0, count: 4) == .outside else { throw Failure("hit mapping") }
            return "ok"
        }

        print("\n\(passed) passed, \(failed.count) failed")
        failed.forEach { print("  ❌ \($0)") }
        return failed.isEmpty
    }

    private static func check(_ name: String, _ body: () throws -> String) {
        do {
            let detail = try body()
            passed += 1
            print("✅ \(name) — \(detail)")
        } catch {
            failed.append("\(name): \(error.localizedDescription)")
            print("❌ \(name) — \(error.localizedDescription)")
        }
    }

    private static func checkAsync(_ name: String, _ body: () async throws -> String) async {
        do {
            let detail = try await body()
            passed += 1
            print("✅ \(name) — \(detail)")
        } catch {
            failed.append("\(name): \(error.localizedDescription)")
            print("❌ \(name) — \(error.localizedDescription)")
        }
    }

    /// Opens a result the way its format requires and describes it.
    private static func verify(_ url: URL) async throws -> String {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw Failure("missing \(url.lastPathComponent)")
        }
        if isFolder.boolValue {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            guard !items.isEmpty else { throw Failure("empty folder \(url.lastPathComponent)") }
            for item in items { _ = try await verify(item) }
            return "\(url.lastPathComponent)/ (\(items.count) files)"
        }
        let size = ByteCountFormatter.string(fromByteCount: Output.fileSize(url), countStyle: .file)
        guard Output.fileSize(url) > 0 else { throw Failure("empty \(url.lastPathComponent)") }
        let name = "\(url.lastPathComponent) \(size)"
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "heic", "webp", "avif", "tiff", "bmp", "gif":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("unreadable \(name)") }
            return "\(name) \(image.width)×\(image.height)"
        case "pdf":
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw Failure("unreadable \(name)") }
            return "\(name) \(document.pageCount)p"
        case "mp4", "mov", "m4a", "wav", "aiff", "flac":
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard duration > 0.5 else { throw Failure("\(name) lasts \(duration)s") }
            return "\(name) \(String(format: "%.1f", duration))s"
        case "docx", "odt", "rtf", "html":
            let text = try DocumentEngine.load(url).string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("no text in \(name)") }
            return "\(name) \(text.count) chars"
        case "txt":
            let text = try String(contentsOf: url)
            guard !text.isEmpty else { throw Failure("no text in \(name)") }
            return "\(name) \(text.count) chars"
        default:
            return name
        }
    }

    /// Colour of one pixel (top-left origin), in sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let context = Bitmap.context(width: 1, height: 1, colorSpace: Bitmap.sRGB), let data = context.data else {
            return (0, 0, 0)
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
