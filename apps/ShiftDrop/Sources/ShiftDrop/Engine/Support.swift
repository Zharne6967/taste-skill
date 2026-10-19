import AppKit
import Foundation

enum AppError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case writeFailed(String)
    case failed(String)
    case noText
    case noSubject
    case alreadySmall

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn't read \(name)."
        case .unsupported(let message): return message
        case .writeFailed(let name): return "Couldn't write \(name)."
        case .failed(let message): return message
        case .noText: return "No text was found."
        case .noSubject: return "No subject was found to cut out."
        case .alreadySmall: return "Already as small as it gets."
        }
    }
}

struct ActionResult: Sendable {
    var outputs: [URL]
    var failedCount = 0
    var note: String?

    var headline: String {
        if outputs.count == 1 { return "Saved \(outputs[0].lastPathComponent)" }
        return "Saved \(outputs.count) files"
    }

    var detail: String? {
        var parts: [String] = []
        if let note { parts.append(note) }
        if failedCount > 0 { parts.append("\(failedCount) couldn't be converted") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

final class Settings: @unchecked Sendable {
    static let shared = Settings()

    enum OutputLocation: String {
        case nextToOriginal, downloads
    }

    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var outputLocation: OutputLocation {
        get { OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .nextToOriginal }
        set { defaults.set(newValue.rawValue, forKey: "outputLocation") }
    }

    var revealResults: Bool {
        get { defaults.bool(forKey: "revealResults") }
        set { defaults.set(newValue, forKey: "revealResults") }
    }

    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: "hasSeenWelcome") }
        set { defaults.set(newValue, forKey: "hasSeenWelcome") }
    }
}

/// Decides where results go and keeps names from colliding ("Photo.jpg", "Photo 2.jpg", …).
enum Output {
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func directory(for source: URL, override: URL?) -> URL {
        if let override { return override }
        if Settings.shared.outputLocation == .downloads { return downloads }
        let folder = source.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: folder.path) ? folder : downloads
    }

    static func baseName(of source: URL, suffix: String?) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        guard let suffix, !suffix.isEmpty else { return base }
        return base + " " + suffix
    }

    static func url(for source: URL, suffix: String? = nil, ext: String, override: URL?) -> URL {
        unique(in: directory(for: source, override: override), base: baseName(of: source, suffix: suffix), ext: ext)
    }

    static func unique(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    static func folder(for source: URL, suffix: String, override: URL?) throws -> URL {
        let directory = Self.directory(for: source, override: override)
        let base = baseName(of: source, suffix: suffix)
        var candidate = directory.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func sizeChange(from source: URL, to output: URL) -> String {
        let before = ByteCountFormatter.string(fromByteCount: fileSize(source), countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: fileSize(output), countStyle: .file)
        return "\(before) → \(after)"
    }
}

enum Background {
    /// Runs blocking work (ImageIO, PDFKit, Vision) off the main thread.
    static func run<T: Sendable>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

enum Shell {
    static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AppError.failed(message.isEmpty ? "\(executable.lastPathComponent) failed." : message)
        }
    }
}

/// Counts running jobs so the menu bar icon can show that something is happening.
@MainActor
final class JobCenter {
    static let shared = JobCenter()
    var onChange: ((Bool) -> Void)?
    private var active = 0

    func begin() {
        active += 1
        if active == 1 { onChange?(true) }
    }

    func end() {
        active = max(0, active - 1)
        if active == 0 { onChange?(false) }
    }
}

/// A cancellable, main-actor timer (replaces DispatchWorkItem so callbacks stay on the main actor).
@MainActor
final class Delay {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
