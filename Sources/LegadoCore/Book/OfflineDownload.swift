import Foundation

/// A book being saved for offline reading. Chapters are fetched in stages of `stageSize`;
/// the cursor is persisted after every stage so a download survives pauses and relaunches.
public struct OfflineDownloadTask: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, running, paused, completed, failed
    }

    public var book: Book
    public var sourceURL: String
    /// First and one-past-last chapter index of the requested range.
    public var startIndex: Int
    public var endIndex: Int
    /// Next chapter index to fetch.
    public var cursor: Int
    public var stageSize: Int
    public var completedChapters: Int
    public var failedIndices: [Int]
    public var state: State
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { book.bookUrl }

    public init(book: Book, sourceURL: String, startIndex: Int, endIndex: Int, stageSize: Int = 50, now: Date = Date()) {
        self.book = book
        self.sourceURL = sourceURL
        self.startIndex = max(startIndex, 0)
        self.endIndex = max(endIndex, self.startIndex)
        cursor = self.startIndex
        self.stageSize = max(stageSize, 1)
        completedChapters = 0
        failedIndices = []
        state = .queued
        createdAt = now
        updatedAt = now
    }

    public var totalChapters: Int { endIndex - startIndex }
    public var isFinished: Bool { cursor >= endIndex }
    public var isActive: Bool { state == .queued || state == .running }

    public var fractionCompleted: Double {
        totalChapters == 0 ? 1 : Double(cursor - startIndex) / Double(totalChapters)
    }

    /// Extends the range instead of starting over when the user asks for more chapters.
    public mutating func extend(to endIndex: Int, from startIndex: Int) {
        if startIndex < self.startIndex {
            self.startIndex = startIndex
            cursor = min(cursor, startIndex)
        }
        self.endIndex = max(self.endIndex, endIndex)
        if !isFinished, state == .completed || state == .failed { state = .queued }
    }

    /// Jobs for the next stage, skipping volume headers. Returns the jobs and the cursor after them.
    public func nextStage(in chapters: [BookChapter]) -> (jobs: [(index: Int, job: ChapterCacheJob)], cursor: Int) {
        let end = min(endIndex, chapters.count)
        var jobs: [(Int, ChapterCacheJob)] = []
        var index = cursor
        while index < end, jobs.count < stageSize {
            if !chapters[index].isVolume {
                let next = chapters[(index + 1)...].first { !$0.isVolume }?.url
                jobs.append((index, .init(chapter: chapters[index], nextChapterURL: next)))
            }
            index += 1
        }
        return (jobs, index)
    }
}

public actor OfflineDownloadStore {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func live() -> OfflineDownloadStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        return OfflineDownloadStore(fileURL: base.appendingPathComponent("offline-downloads.json"))
    }

    public func load() -> [OfflineDownloadTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([OfflineDownloadTask].self, from: data)) ?? []
    }

    public func save(_ tasks: [OfflineDownloadTask]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tasks).write(to: fileURL, options: .atomic)
    }
}

public enum OfflineDownloadRunner {
    /// Downloads one stage with limited concurrency and returns the task advanced past it.
    /// Cancellation leaves the cursor where it was so the stage is retried on resume.
    public static func runStage(
        _ task: OfflineDownloadTask,
        chapters: [BookChapter],
        source: BookSource,
        coordinator: ChapterContentCoordinator,
        concurrency: Int = 3,
        onChapter: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async -> OfflineDownloadTask {
        var task = task
        let stage = task.nextStage(in: chapters)
        guard !stage.jobs.isEmpty else {
            task.cursor = max(stage.cursor, task.endIndex)
            return task
        }
        let result = await fetch(stage.jobs, book: task.book, source: source, coordinator: coordinator, concurrency: concurrency, onChapter: onChapter)
        guard !Task.isCancelled else { return task }
        task.cursor = stage.cursor
        task.completedChapters += result.succeeded
        task.failedIndices = Array(Set(task.failedIndices).union(result.failed)).sorted()
        task.updatedAt = Date()
        return task
    }

    /// Fetches previously failed chapters again; those that still fail stay in `failedIndices`.
    public static func retryFailed(
        _ task: OfflineDownloadTask,
        chapters: [BookChapter],
        source: BookSource,
        coordinator: ChapterContentCoordinator,
        concurrency: Int = 3
    ) async -> OfflineDownloadTask {
        var task = task
        let jobs = task.failedIndices.filter { chapters.indices.contains($0) }.map { index in
            (index, ChapterCacheJob(chapter: chapters[index], nextChapterURL: chapters[(index + 1)...].first { !$0.isVolume }?.url))
        }
        let result = await fetch(jobs, book: task.book, source: source, coordinator: coordinator, concurrency: concurrency) { _ in }
        guard !Task.isCancelled else { return task }
        task.completedChapters += result.succeeded
        task.failedIndices = result.failed.sorted()
        task.updatedAt = Date()
        return task
    }

    private static func fetch(
        _ jobs: [(index: Int, job: ChapterCacheJob)],
        book: Book,
        source: BookSource,
        coordinator: ChapterContentCoordinator,
        concurrency: Int,
        onChapter: @escaping @Sendable (Int) async -> Void
    ) async -> (succeeded: Int, failed: [Int]) {
        guard !jobs.isEmpty else { return (0, []) }
        var failed: [Int] = []
        var succeeded = 0
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let (index, job) = jobs[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return (index, false) }
                    let cached = await coordinator.ensureCached(
                        book: book,
                        chapter: job.chapter,
                        source: source,
                        nextChapterURL: job.nextChapterURL
                    )
                    return (index, cached)
                }
            }
            for _ in 0..<min(max(concurrency, 1), jobs.count) { enqueue() }
            while let (index, cached) = await group.next() {
                if cached { succeeded += 1 } else { failed.append(index) }
                await onChapter(succeeded)
                enqueue()
            }
        }
        return (succeeded, failed)
    }
}
