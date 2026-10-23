import SwiftUI

@MainActor
private final class SourceRepositoryBrowserModel: ObservableObject {
    @Published private(set) var items: [SourceRepositoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasNextPage = false
    @Published var errorMessage: String?
    @Published var query = SourceRepositoryQuery()

    private let client = SourceRepositoryClient()
    private var loadedPage = 0

    func batchURL(ids: [String]) -> URL? { client.batchJSONURL(ids: ids) }

    func reload() async {
        loadedPage = 0
        items = []
        hasNextPage = false
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var page = query
        page.page = loadedPage + 1
        do {
            let result = try await client.fetch(page)
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            hasNextPage = result.hasNextPage && !result.items.isEmpty
            loadedPage = page.page
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Browses a public source repository ("源仓库") and imports selected sources through the
/// regular import preview, so nothing is added without the user confirming it.
struct SourceRepositoryBrowserView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @StateObject private var model = SourceRepositoryBrowserModel()
    @AppStorage("sourceRepositoryShowsAdult") private var showsAdult = false
    @State private var keyword = ""
    @State private var selectedIDs = Set<String>()

    private var visibleItems: [SourceRepositoryItem] {
        showsAdult ? model.items : model.items.filter { !$0.isAdult }
    }

    var body: some View {
        List {
            Section {
                Picker("排序", selection: $model.query.order) {
                    Text("最近更新").tag(SourceRepositoryQuery.Order.latest)
                    Text("下载最多").tag(SourceRepositoryQuery.Order.downloads)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("只列出支持搜索的 3.X 书源。导入前会先显示预览，导入后建议在“测试书源”中校验可用性。")
            }

            Section {
                ForEach(visibleItems) { item in
                    row(item)
                        .onAppear {
                            if item.id == visibleItems.last?.id, model.hasNextPage {
                                Task { await model.loadNextPage() }
                            }
                        }
                }
                if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if visibleItems.isEmpty {
                    Text(model.errorMessage == nil ? "没有找到书源" : "加载失败，下拉重试")
                        .foregroundStyle(.secondary)
                }
            } header: {
                if !model.items.isEmpty {
                    Text("已加载 \(visibleItems.count) 个" + (showsAdult ? "" : "（已隐藏成人内容）"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发现书源")
        .searchable(text: $keyword, prompt: "书源名称或网址")
        .onSubmit(of: .search) {
            model.query.keyword = keyword
        }
        .onChange(of: keyword) { value in
            if value.isEmpty, !model.query.keyword.isEmpty { model.query.keyword = "" }
        }
        .task(id: model.query) { await model.reload() }
        .refreshable { await model.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "ellipsis.circle") {
                    Toggle("显示成人内容", isOn: $showsAdult)
                    if !selectedIDs.isEmpty {
                        Button("取消选择", systemImage: "xmark.circle") { selectedIDs.removeAll() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedIDs.isEmpty {
                Button {
                    importSources(Array(selectedIDs))
                } label: {
                    Text("导入所选 \(selectedIDs.count) 个书源").frame(maxWidth: .infinity)
                }
                .readingProminentButtonStyle()
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .alert("书源仓库加载失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func row(_ item: SourceRepositoryItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        let added = isAdded(item)
        return Button {
            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? ReadingTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                        if added {
                            Text("已添加").font(.caption2).foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().stroke(Color.green.opacity(0.6)))
                        }
                    }
                    if !item.siteURL.isEmpty {
                        Text(item.siteURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(([item.version] + item.tags).filter { !$0.isEmpty }.joined(separator: " · "))
                        Text("↓\(item.downloads)")
                        Text(item.updatedAt)
                        if !item.author.isEmpty { Text(item.author).lineLimit(1) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("导入") { importSources([item.id]) }.tint(ReadingTheme.accent)
        }
    }

    /// Repository titles read "<bookSourceName> <bookSourceUrl>", so match on the trailing URL.
    private func isAdded(_ item: SourceRepositoryItem) -> Bool {
        let title = item.siteURL.isEmpty ? item.name : "\(item.name) \(item.siteURL)"
        return library.sources.contains { source in
            source.bookSourceUrl == item.siteURL || title.hasSuffix(" " + source.bookSourceUrl)
        }
    }

    private func importSources(_ ids: [String]) {
        guard let url = model.batchURL(ids: ids) else { return }
        selectedIDs.subtract(ids)
        Task { await library.previewInput(url.absoluteString) }
    }
}
