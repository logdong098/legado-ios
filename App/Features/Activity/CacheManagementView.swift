import SwiftUI

@MainActor
private final class CacheManagementModel: ObservableObject {
    @Published private(set) var entries = 0
    @Published private(set) var bytes = 0
    @Published private(set) var books: [String: (entries: Int, bytes: Int)] = [:]
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let cache: ChapterContentCache

    init(cache: ChapterContentCache = .live()) { self.cache = cache }

    var offlineBytes: Int { books.values.reduce(0) { $0 + $1.bytes } }

    func load(bookURLs: [String]) async {
        do {
            let statistics = try await cache.statistics()
            entries = statistics.entries
            bytes = statistics.bytes
            var books: [String: (entries: Int, bytes: Int)] = [:]
            for url in bookURLs { books[url] = try await cache.statistics(bookURL: url) }
            self.books = books
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear(keepingOffline: Bool, bookURLs: [String]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if keepingOffline { try await cache.removeUnprotected() } else { try await cache.removeAll() }
        } catch {
            errorMessage = error.localizedDescription
        }
        await load(bookURLs: bookURLs)
    }
}

struct CacheManagementView: View {
    @StateObject private var model = CacheManagementModel()
    @ObservedObject private var downloads = OfflineDownloadManager.shared
    @AppStorage("offlineStageSize") private var stageSize = OfflineDownloadManager.stageSizes[0]
    @State private var removing: OfflineDownloadTask?
    @State private var confirmsClearAll = false

    private var bookURLs: [String] { downloads.tasks.map(\.id) }

    var body: some View {
        List {
            Section {
                ReadingLabeledContent("离线书籍", value: "\(downloads.tasks.count) 本 · \(format(model.offlineBytes))")
                ReadingLabeledContent("全部章节缓存", value: "\(model.entries) 章 · \(format(model.bytes))")
            } footer: {
                Text("离线书籍保存在应用数据目录，不受缓存上限影响，也不会被系统自动清理。阅读时自动缓存的章节超出上限后，会优先清理最久未读的。")
            }

            if downloads.tasks.isEmpty {
                Section("离线书籍") {
                    Text("在书籍详情页右上角菜单选择“离线缓存”，即可分阶段保存整本小说。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(downloads.tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
                        row(task)
                            .swipeActions {
                                Button("删除", role: .destructive) { removing = task }
                            }
                            .contextMenu { actions(for: task) }
                    }
                } header: {
                    HStack {
                        Text("离线书籍")
                        Spacer()
                        if downloads.tasks.contains(where: \.isActive) {
                            Button("全部暂停") { downloads.pauseAll() }.font(.caption)
                        } else if downloads.tasks.contains(where: { $0.state == .paused || $0.state == .failed }) {
                            Button("全部继续") { downloads.resumeAll() }.font(.caption)
                        }
                    }
                }
            }

            Section {
                Picker("每阶段章节数", selection: $stageSize) {
                    ForEach(OfflineDownloadManager.stageSizes, id: \.self) { Text("\($0) 章").tag($0) }
                }
            } footer: {
                Text("下载按阶段进行，每完成一个阶段就保存一次进度；暂停或退出应用后，下次从未完成的阶段继续。新设置对之后加入的下载生效。")
            }

            Section {
                Button("清理阅读缓存（保留离线书籍）", systemImage: "sparkles") {
                    Task { await model.clear(keepingOffline: true, bookURLs: bookURLs) }
                }
                .disabled(model.entries == 0 || model.isWorking)
                Button("清空全部章节缓存", systemImage: "trash", role: .destructive) { confirmsClearAll = true }
                    .disabled(model.entries == 0 || model.isWorking)
            }
        }
        .navigationTitle("缓存管理")
        .task(id: downloads.tasks.map { "\($0.id)|\($0.cursor)|\($0.state.rawValue)" }) {
            await model.load(bookURLs: bookURLs)
        }
        .overlay { if model.isWorking { ProgressView() } }
        .confirmationDialog(
            "删除《\(removing?.book.name ?? "")》的离线缓存？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            if let task = removing {
                Button("删除离线缓存和已下载章节", role: .destructive) {
                    Task { await downloads.remove(task.id, deletingChapters: true); await model.load(bookURLs: bookURLs) }
                }
                Button("只取消离线（章节转为普通缓存）") {
                    Task { await downloads.remove(task.id, deletingChapters: false); await model.load(bookURLs: bookURLs) }
                }
            }
        }
        .confirmationDialog("清空全部章节缓存？", isPresented: $confirmsClearAll, titleVisibility: .visible) {
            Button("清空（包括离线书籍）", role: .destructive) {
                Task {
                    downloads.pauseAll()
                    await model.clear(keepingOffline: false, bookURLs: bookURLs)
                }
            }
        } message: {
            Text("离线书籍的下载记录会保留，可在之后重新继续下载。")
        }
        .alert("缓存操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private func row(_ task: OfflineDownloadTask) -> some View {
        let stats = model.books[task.id]
        let running = downloads.isRunning(task.id)
        let stageDone = running ? downloads.stageProgress[task.id] ?? 0 : 0
        let fraction = min(Double(task.cursor - task.startIndex + stageDone) / Double(max(task.totalChapters, 1)), 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.book.name).font(.headline).lineLimit(1)
                Spacer()
                stateButton(task)
            }
            ProgressView(value: fraction).tint(task.state == .failed ? .red : ReadingTheme.accent)
            HStack {
                Text(statusText(task, running: running))
                Spacer()
                Text("\(stats?.entries ?? 0) 章 · \(format(stats?.bytes ?? 0))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let error = task.lastError {
                Text(error).font(.caption).foregroundStyle(task.state == .failed ? .red : .orange)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func stateButton(_ task: OfflineDownloadTask) -> some View {
        if task.isActive {
            Button { downloads.pause(task.id) } label: { Image(systemName: "pause.circle.fill") }
                .buttonStyle(.borderless).font(.title3)
        } else if task.state != .completed || !task.failedIndices.isEmpty {
            Button { downloads.resume(task.id) } label: {
                Image(systemName: task.isFinished ? "arrow.clockwise.circle.fill" : "play.circle.fill")
            }
            .buttonStyle(.borderless).font(.title3)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        }
    }

    @ViewBuilder private func actions(for task: OfflineDownloadTask) -> some View {
        if task.isActive {
            Button("暂停", systemImage: "pause") { downloads.pause(task.id) }
        } else if !task.isFinished {
            Button("继续下载", systemImage: "play") { downloads.resume(task.id) }
        }
        if task.isFinished, !task.failedIndices.isEmpty, !task.isActive {
            Button("重试失败的 \(task.failedIndices.count) 章", systemImage: "arrow.clockwise") { downloads.resume(task.id) }
        }
        Button("删除", systemImage: "trash", role: .destructive) { removing = task }
    }

    private func statusText(_ task: OfflineDownloadTask, running: Bool) -> String {
        let done = task.cursor - task.startIndex
        let stage = "第 \(min(done / task.stageSize + 1, max((task.totalChapters + task.stageSize - 1) / task.stageSize, 1))) 阶段"
        switch task.state {
        case .running where running: return "下载中 · \(stage) · \(done)/\(task.totalChapters)"
        case .queued, .running: return "排队中 · \(done)/\(task.totalChapters)"
        case .paused: return "已暂停 · \(done)/\(task.totalChapters)"
        case .failed: return "下载失败"
        case .completed: return task.failedIndices.isEmpty ? "已完成" : "已完成，\(task.failedIndices.count) 章失败"
        }
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
