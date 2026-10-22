import CoreText
import ImageIO
import SwiftUI
import UIKit

private struct ReaderPositionPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD))
    ]
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        return legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    static func install(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if target != source {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        guard font(at: target.path, size: 20, weight: 0) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return target.path
    }

    /// Installed iOS fonts are stored as `system:<PostScript name>` instead of a file path.
    static let systemPrefix = "system:"

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        if path.hasPrefix(systemPrefix) {
            return UIFont(name: String(path.dropFirst(systemPrefix.count)), size: size)
                .map { styled($0, size: size, weight: weight) }
        }
        guard !path.isEmpty,
              let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let graphicsFont = CGFont(provider) else { return nil }
        CTFontManagerRegisterGraphicsFont(graphicsFont, nil)
        guard let postScriptName = graphicsFont.postScriptName else { return nil }
        let name = postScriptName as String
        guard let base = UIFont(name: name, size: size) else { return nil }
        return styled(base, size: size, weight: weight)
    }

    private static func styled(_ base: UIFont, size: CGFloat, weight: Int) -> UIFont {
        if weight == 1,
           let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

/// Reading fonts offered in settings: two that ship with iOS and open-source (SIL OFL)
/// fonts downloaded on demand from their GitHub releases.
struct ReaderRecommendedFont: Identifiable {
    let id: String
    let name: String
    let detail: String
    let systemName: String?
    let downloadURL: URL?
    let fileName: String?

    static let all: [ReaderRecommendedFont] = [
        .init(id: "songti", name: "宋体（默认）", detail: "系统自带，传统书籍风格", systemName: nil, downloadURL: nil, fileName: nil),
        .init(id: "pingfang", name: "苹方", detail: "系统自带，清晰现代的黑体", systemName: "PingFangSC-Regular", downloadURL: nil, fileName: nil),
        .init(
            id: "wenkai-screen", name: "霞鹜文楷 屏幕阅读版", detail: "开源楷体，为屏幕加粗，约 25 MB",
            systemName: nil,
            downloadURL: URL(string: "https://github.com/lxgw/LxgwWenKai-Screen/releases/latest/download/LXGWWenKaiScreen.ttf"),
            fileName: "LXGWWenKaiScreen.ttf"
        ),
        .init(
            id: "neozhisong", name: "霞鹜新致宋", detail: "开源宋体，字形更舒展，约 10 MB",
            systemName: nil,
            downloadURL: URL(string: "https://github.com/lxgw/LxgwNeoZhiSong/releases/latest/download/LXGWNeoZhiSong.ttf"),
            fileName: "LXGWNeoZhiSong.ttf"
        )
    ]

    /// The value stored in the `textFont` setting when this font is selected.
    var settingValue: String? {
        if let systemName { return ReaderFontStore.systemPrefix + systemName }
        if let fileName { return isDownloaded ? localURL(fileName).path : nil }
        return ""
    }

    var isDownloaded: Bool {
        guard let fileName else { return true }
        return FileManager.default.fileExists(atPath: localURL(fileName).path)
    }

    func matches(_ fontPath: String) -> Bool {
        if systemName == nil, fileName == nil { return fontPath.isEmpty }
        if let systemName { return fontPath == ReaderFontStore.systemPrefix + systemName }
        return fileName.map { URL(fileURLWithPath: fontPath).lastPathComponent == $0 } ?? false
    }

    func download() async throws -> String {
        guard let downloadURL, let fileName else { return settingValue ?? "" }
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
            throw URLError(.badServerResponse)
        }
        let named = temporary.deletingLastPathComponent().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: temporary, to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        return try ReaderFontStore.install(from: named)
    }

    private func localURL(_ fileName: String) -> URL {
        ReaderFontStore.directory.appendingPathComponent(fileName)
    }
}
