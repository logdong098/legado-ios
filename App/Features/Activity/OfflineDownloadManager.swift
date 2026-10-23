import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

/// Runs offline downloads one book at a time, stage by stage, independent of any screen.
/// Progress is persisted after every stage; unfinished downloads resume on the next launch.
@MainActor
final class OfflineDownloadManager: ObservableObject {
    static let shared = OfflineDownloadManager()
    static let stageSizes = [50, 100, 200]

    @Published private(set) var tasks: [OfflineDownloadTask] = []
    /// Chapters finished within the stage currently running, for smooth progress.
    @Published private(set) var stageProgress: [String: Int] = [:]

    private let store = OfflineDownloadStore.live()
    private let coordinator = ChapterContentCoordinator()
    private let chapterRepository = AppBookChapterRepository.live()
    private var sourceResolver: @MainActor (String) -> BookSource? = { _ in nil }
    private var worker: Task<Void, Never>?
    private var runningBookURL: String?
    private var didStart = false

    func start(sourceResolver: @escaping @MainActor (String) -> BookSource?) async {
        self.sourceResolver = sourceResolver
        guard !didStart else { return }
        didStart = true
        tasks = await store.load()
        // A download interrupted by termination is queued again rather than left "running".
        for index in tasks.indices where tasks[index].state == .running { tasks[index].state = .queued }
        publishProtectedBooks()
        pump()
    }

    func task(for bookURL: String) -> OfflineDownloadTask? {
        tasks.first { $0.id == bookURL }
    }

    func isRunning(_ bookURL: String) -> Bool { runningBookURL == bookURL }

    /// Queues `count` chapters starting at `start` (nil = to the end), extending an existing download.
    func download(book: Book, source: BookSource, chapterCount: Int, from start: Int, count: Int?) {
        let start = min(max(start, 0), max(chapterCount - 1, 0))
        let end = count.map { min(start + $0, chapterCount) } ?? chapterCount
        guard end > start else { return }
        let stageSize = UserDefaults.standard.integer(forKey: "offlineStageSize")
        if let index = tasks.firstIndex(where: { $0.id == book.bookUrl }) {
            tasks[index].book = book
            tasks[index].sourceURL = source.bookSourceUrl
            tasks[index].extend(to: end, from: start)
            if tasks[index].state == .paused { tasks[index].state = .queued }
        } else {
            tasks.append(.init(
                book: book,
                sourceURL: source.bookSourceUrl,
                startIndex: start,
                endIndex: end,
                stageSize: stageSize > 0 ? stageSize : Self.stageSizes[0]
            ))
        }
        changed()
    }

    func pause(_ bookURL: String) {
        guard let index = tasks.firstIndex(where: { $0.id == bookURL }), tasks[index].isActive else { return }
        tasks[index].state = .paused
        if runningBookURL == bookURL { worker?.cancel() }
        changed()
    }

    func resume(_ bookURL: String) {
        guard let index = tasks.firstIndex(where: { $0.id == bookURL }) else { return }
        if tasks[index].isFinished, tasks[index].failedIndices.isEmpty { return }
        tasks[index].state = .queued
        tasks[index].lastError = nil
        changed()
    }

    func pauseAll() { tasks.filter(\.isActive).forEach { pause($0.id) } }

    func resumeAll() {
        for task in tasks where task.state == .paused || task.state == .failed { resume(task.id) }
    }

    /// Stops the download and forgets it; optionally deletes the chapters it saved.
    func remove(_ bookURL: String, deletingChapters: Bool) async {
        if runningBookURL == bookURL { worker?.cancel() }
        tasks.removeAll { $0.id == bookURL }
        changed()
        if deletingChapters { await coordinator.invalidate(bookURL: bookURL) }
    }

    private func changed() {
        publishProtectedBooks()
        let snapshot = tasks
        Task { try? await store.save(snapshot) }
        pump()
    }

    private func publishProtectedBooks() {
        ChapterContentCache.setProtectedBooks(tasks.map(\.id))
    }

    private func pump() {
        guard worker == nil, didStart, let next = tasks.first(where: { $0.isActive }) else { return }
        let bookURL = next.id
        runningBookURL = bookURL
        worker = Task { [weak self] in
            await self?.run(bookURL)
            guard let self else { return }
            self.worker = nil
            self.runningBookURL = nil
            self.stageProgress[bookURL] = nil
            self.pump()
        }
    }

    private func run(_ bookURL: String) async {
        guard var initial = task(for: bookURL) else { return }
        guard let source = sourceResolver(initial.sourceURL) else {
            finish(bookURL, state: .failed, error: "找不到书源：\(initial.sourceURL)")
            return
        }
        update(bookURL) { $0.state = .running }
        var chapters = (try? await chapterRepository.load(bookURL: bookURL)) ?? []
        if chapters.isEmpty {
            let report = await BookUpdateCoordinator(repository: chapterRepository).refresh(book: initial.book, source: source)
            chapters = report.chapters
        }
        guard !chapters.isEmpty else {
            finish(bookURL, state: .failed, error: "目录为空，无法缓存")
            return
        }
        // Resuming a finished download means "retry the chapters that failed".
        if initial.isFinished, !initial.failedIndices.isEmpty {
            initial = await OfflineDownloadRunner.retryFailed(initial, chapters: chapters, source: source, coordinator: coordinator)
            guard !Task.isCancelled else { return }
            apply(initial)
        }
        while !Task.isCancelled, let current = self.task(for: bookURL), current.state == .running, !current.isFinished {
            stageProgress[bookURL] = 0
            let advanced = await OfflineDownloadRunner.runStage(
                current,
                chapters: chapters,
                source: source,
                coordinator: coordinator
            ) { [weak self] done in
                await MainActor.run { self?.stageProgress[bookURL] = done }
            }
            guard !Task.isCancelled else { return }
            apply(advanced)
        }
        guard !Task.isCancelled, let current = self.task(for: bookURL), current.state == .running else { return }
        finish(bookURL, state: .completed, error: current.failedIndices.isEmpty ? nil : "\(current.failedIndices.count) 章下载失败")
    }

    /// Saves a stage result without overwriting a pause or range change made meanwhile.
    private func apply(_ advanced: OfflineDownloadTask) {
        update(advanced.id) { task in
            task.cursor = advanced.cursor
            task.completedChapters = advanced.completedChapters
            task.failedIndices = advanced.failedIndices
            task.updatedAt = advanced.updatedAt
        }
    }

    private func finish(_ bookURL: String, state: OfflineDownloadTask.State, error: String?) {
        update(bookURL) {
            $0.state = state
            $0.lastError = error
        }
    }

    private func update(_ bookURL: String, _ change: (inout OfflineDownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == bookURL }) else { return }
        change(&tasks[index])
        tasks[index].updatedAt = Date()
        publishProtectedBooks()
        let snapshot = tasks
        Task { try? await store.save(snapshot) }
    }
}
