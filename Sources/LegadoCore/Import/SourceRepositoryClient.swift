import Foundation

/// One book source listed on a yckceo-style source repository ("源仓库").
public struct SourceRepositoryItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var siteURL: String
    public var updatedAt: String
    public var version: String
    /// The site's capability badges: 发(explore) 搜(search) 图(image) 声(audio).
    public var tags: [String]
    public var author: String
    public var downloads: Int

    public var supportsSearch: Bool { tags.contains("搜") }
    public var supportsExplore: Bool { tags.contains("发") }

    /// The repository marks adult sources with 🔞 in the title.
    public var isAdult: Bool { name.contains("🔞") || siteURL.contains("🔞") }
}

public struct SourceRepositoryQuery: Hashable, Sendable {
    public enum Order: String, Sendable { case latest = "time", downloads = "down" }

    public var keyword = ""
    public var order: Order = .latest
    public var page = 1
    /// Only Legado 3.x sources run in this app.
    public var requiresVersion3 = true
    public var requiresSearch = true

    public init(keyword: String = "", order: Order = .latest, page: Int = 1) {
        self.keyword = keyword
        self.order = order
        self.page = page
    }
}

public struct SourceRepositoryPage: Sendable {
    public var items: [SourceRepositoryItem]
    public var hasNextPage: Bool
}

public struct SourceRepositoryClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://www.yckceo.com")!

    public var baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL = Self.defaultBaseURL, transport: any HTTPTransport = URLSessionHTTPTransport.shared) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func listURL(for query: SourceRepositoryQuery) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("yuedu/shuyuan/index.html"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "page", value: String(max(query.page, 1))),
            URLQueryItem(name: "order1", value: query.order.rawValue),
            URLQueryItem(name: "order2", value: "1")
        ]
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty { items.append(URLQueryItem(name: "keys", value: keyword)) }
        if query.requiresVersion3 { items.append(URLQueryItem(name: "ver", value: "3")) }
        if query.requiresSearch { items.append(URLQueryItem(name: "sousuo", value: "1")) }
        components.queryItems = items
        return components.url!
    }

    /// One request returns every selected source as a Legado JSON array.
    public func batchJSONURL(ids: [String]) -> URL? {
        let ids = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard !ids.isEmpty else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("yuedu/shuyuan/jsons"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: ids.joined(separator: "-"))]
        return components.url
    }

    public func fetch(_ query: SourceRepositoryQuery) async throws -> SourceRepositoryPage {
        var request = URLRequest(url: listURL(for: query), timeoutInterval: 30)
        request.setValue(LegadoURLBuilder.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let response = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return Self.parse(html: response.decodedText, page: query.page)
    }

    /// The repository has no JSON listing API, so items are read from the list page markup.
    public static func parse(html: String, page: Int) -> SourceRepositoryPage {
        let blocks = html.components(separatedBy: "class=\"ylist\"").dropFirst()
        let items = blocks.compactMap(parseItem)
        let hasNext = html.contains("index.html?") && html.contains("page=\(page + 1)")
        return .init(items: items, hasNextPage: hasNext)
    }

    private static func parseItem(_ block: String) -> SourceRepositoryItem? {
        guard let id = first(#"/yuedu/shuyuan/content/id/(\d+)\.html"#, in: block),
              let rawTitle = first(#"content/id/\d+\.html">(.*?)</a>"#, in: block) else { return nil }
        let title = decodeEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        // Titles are "<name> <site URL>"; the URL part is optional.
        var name = title
        var site = ""
        if let range = title.range(of: #"\s+(https?://\S+)\s*$"#, options: .regularExpression) {
            site = title[range].trimmingCharacters(in: .whitespaces)
            name = String(title[..<range.lowerBound])
        }
        let badges = all(#"<span class="layui-badge-rim[^"]*"[^>]*>(.*?)</span>"#, in: block).map(decodeEntities)
        let version = badges.first { $0.hasSuffix(".X") } ?? ""
        let tags = badges.first { badge in
            let parts = badge.split(separator: " ")
            return !parts.isEmpty && parts.allSatisfy { ["发", "搜", "图", "声"].contains($0) }
        }?.split(separator: " ").map(String.init) ?? []
        let author = badges.first { $0.hasPrefix("用户:") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) } ?? ""
        let downloads = badges.first { $0.hasPrefix("下载:") }.flatMap { Int($0.dropFirst(3)) } ?? 0
        let updated = first(#"<p class="m-right"[^>]*>(.*?)</p>"#, in: block).map(decodeEntities) ?? ""
        return .init(id: id, name: name, siteURL: site, updatedAt: updated, version: version, tags: tags, author: author, downloads: downloads)
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        all(pattern, in: text).first
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private static func decodeEntities(_ value: String) -> String {
        [("&middot;", "·"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")]
            .reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
