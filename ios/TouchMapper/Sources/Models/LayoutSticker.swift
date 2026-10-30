//
//  LayoutSticker.swift
//  TouchMapper iOS
//
//  全屏触控界面上那些「摇杆 / 技能 / 攻击 / 按键」的位置提示贴纸。
//  它们只是视觉标记，不会自己触发触摸 —— 与 Android 端行为一致。
//
//  两种形态：
//    · 文字键位 —— 圆圈 + 文字
//    · 图标键位 —— 圆圈 + 自定义图标
//  图标以 PNG 存在 Documents/stickerIcons/<uuid>.png，模型里只存文件名。
//

import Foundation
import UIKit

struct LayoutSticker: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case joystick
        case skill
        case attack
        case button

        var displayName: String {
            switch self {
            case .joystick: return "摇杆"
            case .skill:    return "技能"
            case .attack:   return "攻击"
            case .button:   return "按键"
            }
        }

        var defaultText: String {
            switch self {
            case .joystick: return "移动"
            case .skill:    return "技能"
            case .attack:   return "攻击"
            case .button:   return "按钮"
            }
        }

        /// 默认直径，相对于屏幕短边的比例
        var defaultDiameterRatio: CGFloat {
            switch self {
            case .joystick: return 0.28
            case .skill:    return 0.13
            case .attack:   return 0.15
            case .button:   return 0.09
            }
        }
    }

    /// 键位显示形态
    enum Style: String, Codable, CaseIterable {
        case text
        case icon

        var displayName: String {
            switch self {
            case .text: return "文字键位"
            case .icon: return "图标键位"
            }
        }
    }

    /// 键位外形
    enum Shape: String, Codable, CaseIterable {
        case circle
        case square

        var displayName: String {
            switch self {
            case .circle: return "圆形"
            case .square: return "方形"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var text: String
    /// 圆心归一化坐标 0..1
    var centerX: Double
    var centerY: Double
    /// 直径，相对屏幕短边的比例
    var diameterRatio: Double
    /// 自身不透明度 0.15 ~ 1.0
    var opacity: Double = 0.85
    /// 显示形态
    var style: Style = .text
    /// 外形
    var shape: Shape = .circle
    /// 图标文件名（存在 Documents/stickerIcons 下），style == .icon 时有效
    var iconFileName: String?

    init(kind: Kind,
         text: String? = nil,
         centerX: Double,
         centerY: Double,
         diameterRatio: Double? = nil,
         opacity: Double = 0.85,
         style: Style = .text,
         shape: Shape = .circle,
         iconFileName: String? = nil) {
        self.kind = kind
        self.text = text ?? kind.defaultText
        self.centerX = centerX
        self.centerY = centerY
        self.diameterRatio = diameterRatio ?? Double(kind.defaultDiameterRatio)
        self.opacity = opacity
        self.style = style
        self.shape = shape
        self.iconFileName = iconFileName
    }

    // MARK: - 旧数据兼容

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, centerX, centerY, diameterRatio, opacity, style, shape, iconFileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .button
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? kind.defaultText
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        diameterRatio = try c.decodeIfPresent(Double.self, forKey: .diameterRatio)
            ?? Double(kind.defaultDiameterRatio)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .text
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .circle
        iconFileName = try c.decodeIfPresent(String.self, forKey: .iconFileName)
    }

    /// 文本上限 40 字符，与 Android 端一致
    static let maxTextLength = 40
    /// 直径可调范围（相对屏幕短边）
    static let diameterRange: ClosedRange<Double> = 0.04...0.7
    /// 不透明度可调范围
    static let opacityRange: ClosedRange<Double> = 0.15...1.0
}

// MARK: - 图标文件存取

enum StickerIconStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("stickerIcons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 存图标，压到 512 长边，返回文件名
    @discardableResult
    static func save(_ image: UIImage, id: UUID) -> String {
        let maxSide: CGFloat = 512
        let size = image.size
        guard size.width > 0, size.height > 0 else { return "" }

        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        let fileName = "\(id.uuidString).png"
        if let data = resized.pngData() {
            try? data.write(to: url(for: fileName), options: .atomic)
        }
        return fileName
    }

    /// 按文件名载入，带内存缓存（同时最多 128 张）
    private static let cache = NSCache<NSString, UIImage>()

    static func load(_ fileName: String?) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let cached = cache.object(forKey: fileName as NSString) { return cached }

        let path = url(for: fileName)
        guard let image = UIImage(contentsOfFile: path.path) else { return nil }
        cache.setObject(image, forKey: fileName as NSString)
        return image
    }

    static func delete(_ fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        cache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}

/// 一套布局预设
struct LayoutPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var stickers: [LayoutSticker]
    var updatedAt: Date = Date()
}
