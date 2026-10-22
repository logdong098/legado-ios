import Compression
import CoreFoundation
import Foundation
import Testing
@testable import LegadoCore

struct BookSourceImporterTests {
    private let importer = BookSourceImporter()

    @Test func decodesArrayAndObjectRules() throws {
        let data = Data(
            """
            [{
              "bookSourceUrl": "https://example.test",
              "bookSourceName": "示例书源",
              "enabled": true,
              "bookSourceType": 0,
              "searchUrl": "https://example.test/search?q={{key}}",
              "ruleSearch": {
                "bookList": "@css:.book",
                "name": "@css:h2@text",
                "bookUrl": "@css:a@href"
              },
              "ruleContent": "{\\\"content\\\":\\\"@css:article@html\\\"}"
            }]
            """.utf8
        )

        let sources = try importer.decode(data)

        #expect(sources.count == 1)
        #expect(sources[0].bookSourceName == "示例书源")
        #expect(sources[0].ruleSearch?.bookList == "@css:.book")
        #expect(sources[0].ruleContent?.content == "@css:article@html")
    }

    @Test func exportedSourcesRoundTripThroughImport() throws {
        let original = try importer.decode(Data(
            """
            [{
              "bookSourceUrl": "光遇聚合",
              "bookSourceName": "🔅光遇聚合",
              "bookSourceGroup": "聚合,番茄",
              "enabled": true,
              "jsLib": "function BaseUrl() { return 'https://v1.example.test'; }",
              "loginUi": "[{\\"name\\":\\"邮箱\\",\\"type\\":\\"text\\"}]",
              "searchUrl": "<js>key</js>",
              "ruleSearch": { "bookList": "$.data", "name": "$.book_name" },
              "customField": "kept"
            }]
            """.utf8
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        let restored = try importer.decode(encoder.encode(original))

        #expect(restored == original)
        #expect(restored.first?.ruleSearch?.name == "$.book_name")
    }

    @Test func acceptsUTF8BOMAndLossyPrimitiveTypes() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(
            contentsOf: """
            {
              "bookSourceUrl": "https://example.test",
              "bookSourceName": "兼容书源",
              "enabled": "1",
              "enabledExplore": 0,
              "bookSourceType": "2",
              "respondTime": "1200"
            }
            """.utf8
        )

        let source = try #require(importer.decode(data).first)

        #expect(source.enabled)
        #expect(!source.enabledExplore)
        #expect(source.bookSourceType == 2)
        #expect(source.respondTime == 1_200)
    }

    @Test func preservesEnabledCookieJarDefaultAndExplicitNull() throws {
        let sources = try importer.decode(Data(
            #"[{"bookSourceUrl":"https://default-cookie.test","bookSourceName":"默认"},{"bookSourceUrl":"https://null-cookie.test","bookSourceName":"空值","enabledCookieJar":null}]"#.utf8
        ))

        #expect(sources[0].enabledCookieJar == true)
        #expect(sources[1].enabledCookieJar == nil)
    }

    @Test func rejectsWholeBatchBeforeMutation() throws {
        let existing = [BookSource(bookSourceUrl: "https://kept.test", bookSourceName: "保留")]
        let data = Data(
            """
            [
              {"bookSourceUrl":"https://valid.test","bookSourceName":"有效"},
              {"bookSourceUrl":"","bookSourceName":"无效"}
            ]
            """.utf8
        )

        #expect(throws: BookSourceImportError.self) {
            try importer.prepare(data: data, existing: existing)
        }
        #expect(existing.count == 1)
    }

    @Test func handlesDuplicatePolicies() throws {
        var old = BookSource(bookSourceUrl: "https://same.test", bookSourceName: "旧名称")
        old.enabled = false
        let data = Data(
            """
            {"bookSourceUrl":"https://same.test","bookSourceName":"新名称"}
            """.utf8
        )

        let replaced = try importer.prepare(data: data, existing: [old], duplicatePolicy: .replace)
        #expect(replaced.replaced == 1)
        #expect(replaced.sources[0].bookSourceName == "新名称")

        let skipped = try importer.prepare(data: data, existing: [old], duplicatePolicy: .skip)
        #expect(skipped.skipped == 1)
        #expect(skipped.sources[0].bookSourceName == "旧名称")

        #expect(throws: BookSourceImportError.self) {
            try importer.prepare(data: data, existing: [old], duplicatePolicy: .fail)
        }
    }

    @Test func roundTripsWithoutLosingCompatibilityFields() throws {
        let originalData = Data(
            """
            {
              "bookSourceUrl":"https://roundtrip.test",
              "bookSourceName":"往返测试",
              "bookSourceGroup":"测试,文本",
              "header":"{\\"User-Agent\\":\\"Legado\\"}",
              "eventListener":true,
              "customButton":true,
              "ruleToc":{"chapterList":"//li","chapterName":"a/text()"}
            }
            """.utf8
        )
        let source = try #require(importer.decode(originalData).first)

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BookSource.self, from: encoded)

        #expect(decoded == source)
    }

    @Test func importsDesensitizedJavaScriptFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "legado-js-audio-source",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let source = try #require(importer.decode(Data(contentsOf: url)).first)

        #expect(source.bookSourceType == 1)
        #expect(source.searchUrl?.contains("searchKey") == true)
        #expect(source.ruleSearch?.bookUrl?.contains("@js:") == true)
        #expect(source.ruleToc?.chapterUrl?.contains("java.get('bookId')") == true)
        #expect(source.ruleReview?.reviewUrl == "/review/{{chapterId}}")

        let roundTrip = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(source))
        #expect(roundTrip == source)
    }

    @Test func importsSourceDocumentsLargerThanTwentyMegabytes() throws {
        var data = Data(#"[{"bookSourceUrl":"https://large.test","bookSourceName":"大书源"}]"#.utf8)
        data.append(Data(repeating: 0x20, count: 21 * 1_024 * 1_024))

        let source = try #require(importer.decode(data).first)
        #expect(source.bookSourceName == "大书源")
    }

    @Test func decodesGBKEncodedSourceDocuments() throws {
        let json = #"[{"bookSourceUrl":"https://gbk.test","bookSourceName":"编码书源","searchUrl":"/search?q={{key}}"}]"#
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        let data = try #require(json.data(using: gbk))

        let source = try #require(importer.decode(data).first)

        #expect(source.bookSourceName == "编码书源")
        #expect(source.searchUrl == "/search?q={{key}}")
    }

    @Test func decodesGzipCompressedSourceDocuments() throws {
        let json = Data(#"[{"bookSourceUrl":"https://gzip.test","bookSourceName":"压缩书源"}]"#.utf8)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: json.count + 4_096)
        defer { destination.deallocate() }
        let produced = json.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, json.count + 4_096,
                base, json.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        #expect(produced > 0)
        var gzipped = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        gzipped.append(destination, count: produced)
        gzipped.append(Data(repeating: 0, count: 8))

        let source = try #require(importer.decode(gzipped).first)

        #expect(source.bookSourceName == "压缩书源")
    }
}
