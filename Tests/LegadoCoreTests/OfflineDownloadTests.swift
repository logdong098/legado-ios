import Foundation
import Testing
@testable import LegadoCore

private struct CountingLoader: ChapterContentLoading {
    let failingURLs: Set<String>

    func loadContent(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String?,
        maxPages: Int
    ) async -> ChapterContentReport {
        failingURLs.contains(chapter.url) ? .init(content: "") : .init(title: chapter.title, content: "正文 \(chapter.url)")
    }
}

struct OfflineDownloadTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)", isDirectory: true)
    }

    private func chapters(_ count: Int, volumeAt: Int? = nil) -> [BookChapter] {
        (0..<count).map { index in
            var chapter = BookChapter(url: "/c/\(index)", title: "第\(index)章", bookUrl: "https://book.test/1", index: index)
            chapter.isVolume = index == volumeAt
            return chapter
        }
    }

    @Test func plansStagesAndSkipsVolumes() {
        let book = Book(bookUrl: "https://book.test/1", name: "书")
        var task = OfflineDownloadTask(book: book, sourceURL: "s", startIndex: 2, endIndex: 9, stageSize: 3)
        let list = chapters(10, volumeAt: 3)

        let first = task.nextStage(in: list)
        #expect(first.jobs.map(\.index) == [2, 4, 5])
        #expect(first.cursor == 6)

        task.cursor = first.cursor
        let second = task.nextStage(in: list)
        #expect(second.jobs.map(\.index) == [6, 7, 8])
        #expect(second.cursor == 9)

        task.extend(to: 20, from: 0)
        #expect(task.startIndex == 0 && task.cursor == 0 && task.endIndex == 20)
    }

    @Test func runsStagesRecordsFailuresAndRetries() async throws {
        let directory = temporaryDirectory()
        let cache = ChapterContentCache(directory: directory)
        let coordinator = ChapterContentCoordinator(loader: CountingLoader(failingURLs: ["/c/1"]), cache: cache)
        let book = Book(bookUrl: "https://book.test/1", name: "书")
        let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "源")
        let list = chapters(5)
        var task = OfflineDownloadTask(book: book, sourceURL: source.bookSourceUrl, startIndex: 0, endIndex: 5, stageSize: 3)

        task = await OfflineDownloadRunner.runStage(task, chapters: list, source: source, coordinator: coordinator)
        #expect(task.cursor == 3)
        #expect(task.completedChapters == 2)
        #expect(task.failedIndices == [1])

        task = await OfflineDownloadRunner.runStage(task, chapters: list, source: source, coordinator: coordinator)
        #expect(task.isFinished)
        #expect(try await cache.statistics(bookURL: book.bookUrl).entries == 4)

        let fixed = ChapterContentCoordinator(loader: CountingLoader(failingURLs: []), cache: cache)
        task = await OfflineDownloadRunner.retryFailed(task, chapters: list, source: source, coordinator: fixed)
        #expect(task.failedIndices.isEmpty)
        #expect(task.completedChapters == 5)
    }

    @Test func protectedBooksSurvivePruningAndPartialClear() async throws {
        let directory = temporaryDirectory()
        let cache = ChapterContentCache(directory: directory, maximumTotalBytes: 1)
        ChapterContentCache.setProtectedBooks(["https://offline.test"])
        defer { ChapterContentCache.setProtectedBooks([]) }

        try await cache.save(.init(bookURL: "https://offline.test", chapterURL: "/1", content: "离线"))
        try await cache.save(.init(bookURL: "https://reading.test", chapterURL: "/1", content: "临时"))
        #expect(try await cache.statistics(bookURL: "https://offline.test").entries == 1)

        try await cache.save(.init(bookURL: "https://reading.test", chapterURL: "/2", content: "临时2"))
        try await cache.removeUnprotected()
        #expect(try await cache.statistics(bookURL: "https://offline.test").entries == 1)
        #expect(try await cache.statistics(bookURL: "https://reading.test").entries == 0)
    }

    @Test func persistsTasks() async throws {
        let store = OfflineDownloadStore(fileURL: temporaryDirectory().appendingPathComponent("tasks.json"))
        let task = OfflineDownloadTask(book: Book(bookUrl: "https://book.test/2", name: "书2"), sourceURL: "s", startIndex: 0, endIndex: 10)
        try await store.save([task])
        #expect(await store.load() == [task])
    }

    @Test func parsesRepositoryListAndBuildsBatchURL() {
        let html = """
        <div class="ylist">
            <p class="checkboxclass">
                <input type="checkbox" class="class_one" name="ids[]" value="7249" title="" lay-skin="primary">
            </p>
            <h2><a href="/yuedu/shuyuan/content/id/7249.html">🔅光遇聚合26.10.9 光遇聚合</a>
                <p class="m-right" style="top: 3px;">10/09 13:04</p>
            </h2>
            <span class="layui-badge-rim layui-bg-gray layui-font-black">3.X</span>
            <span class="layui-badge-rim layui-bg-gray layui-font-orange">发 搜 图 声 </span>
            <span class="layui-badge-rim layui-bg-gray layui-font-red" title="UID:8653">用户: 晴天</span>
            <span class="layui-badge-rim layui-bg-gray layui-font-purple">下载:16990</span>
        </div>
        <div class="ylist">
            <h2><a href="/yuedu/shuyuan/content/id/5660.html">🔞 UAA&middot;小说 https://www.uaa.com/</a>
                <p class="m-right" style="top: 3px;">2024/09/11</p>
            </h2>
            <span class="layui-badge-rim layui-bg-gray layui-font-black">3.X</span>
            <span class="layui-badge-rim layui-bg-gray layui-font-orange">发 搜 </span>
            <span class="layui-badge-rim layui-bg-gray layui-font-purple">下载:301920</span>
        </div>
        <a href="/yuedu/shuyuan/index.html?page=2">2</a>
        """

        let page = SourceRepositoryClient.parse(html: html, page: 1)

        #expect(page.hasNextPage)
        #expect(page.items.count == 2)
        let first = page.items[0]
        #expect(first.id == "7249")
        #expect(first.name == "🔅光遇聚合26.10.9 光遇聚合")
        #expect(first.tags == ["发", "搜", "图", "声"])
        #expect(first.author == "晴天" && first.downloads == 16990 && first.version == "3.X")
        #expect(!first.isAdult)
        #expect(page.items[1].name == "🔞 UAA·小说" && page.items[1].siteURL == "https://www.uaa.com/")
        #expect(page.items[1].isAdult)

        let client = SourceRepositoryClient()
        #expect(client.batchJSONURL(ids: ["7249", "5660", "x"])?.absoluteString == "https://www.yckceo.com/yuedu/shuyuan/jsons?id=7249-5660")
        let list = client.listURL(for: .init(keyword: "番茄", order: .downloads, page: 3)).absoluteString
        #expect(list.contains("page=3") && list.contains("order1=down") && list.contains("ver=3") && list.contains("sousuo=1"))
    }
}
