import AppKit
import UniformTypeIdentifiers

/// The files under the cursor while the user drags. Finder hands over URLs; apps such as
/// Photos or Safari hand over file promises, which are only written out when dropped.
struct DragPayload {
    var urls: [URL] = []
    var promisedTypes: [String] = []

    var count: Int { urls.isEmpty ? promisedTypes.count : urls.count }

    var kind: FileKind {
        if let url = urls.first { return FileKind.of(url) }
        if let identifier = promisedTypes.first, let type = UTType(identifier) { return FileKind.of(type) }
        return .unsupported
    }

    var sourceFormat: Format? {
        if let url = urls.first { return Format.from(url: url) }
        if let identifier = promisedTypes.first, let type = UTType(identifier) { return Format.from(type: type) }
        return nil
    }

    /// Short text for the hub of the wheel, e.g. "1.2 MB" or "3 files".
    var summary: String {
        if count > 1 { return "\(count) files" }
        if let url = urls.first,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return kind.displayName
    }
}

enum DragPasteboard {
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return !isFolder
        }
    }

    static func promiseReceivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    static func payload(from pasteboard: NSPasteboard) -> DragPayload? {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty { return DragPayload(urls: urls) }
        let types = promiseReceivers(in: pasteboard).flatMap { $0.fileTypes }
        if !types.isEmpty { return DragPayload(promisedTypes: types) }
        return nil
    }
}

/// Collects files that another app promised during a drop.
final class PromiseBatch: @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let lock = NSLock()
    private var received: [URL] = []
    private var lastError: Error?
    private var remaining: Int
    private var finished = false
    private var continuation: CheckedContinuation<[URL], Error>?
    private let receivers: [NSFilePromiseReceiver]
    let directory: URL

    init(receivers: [NSFilePromiseReceiver]) {
        self.receivers = receivers
        remaining = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiftDrop-\(UUID().uuidString)", isDirectory: true)
    }

    /// Must be called while the drop is being performed.
    func start() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            finish(error: error)
            return
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: Self.queue) { [self] url, error in
                deliver(url: url, error: error)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [self] in
            finish(error: AppError.failed("The app you dragged from never delivered the file."))
        }
    }

    func value() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if finished {
                resume(continuation)
            } else {
                self.continuation = continuation
            }
        }
    }

    private func deliver(url: URL, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error { lastError = error } else { received.append(url) }
        remaining -= 1
        if remaining <= 0 { finishLocked() }
    }

    private func finish(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if lastError == nil { lastError = error }
        finishLocked()
    }

    private func finishLocked() {
        guard !finished else { return }
        finished = true
        if let continuation {
            self.continuation = nil
            resume(continuation)
        }
    }

    private func resume(_ continuation: CheckedContinuation<[URL], Error>) {
        if received.isEmpty {
            continuation.resume(throwing: lastError ?? AppError.failed("Nothing was dropped."))
        } else {
            continuation.resume(returning: received)
        }
    }
}
