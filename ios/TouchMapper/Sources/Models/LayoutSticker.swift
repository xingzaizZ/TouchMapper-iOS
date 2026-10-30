//
//  LayoutSticker.swift
//  TouchMapper iOS
//
//  全屏触控界面上那些「摇杆 / 技能 / 攻击 / 按键」的位置提示贴纸。
//  它们只是视觉标记，不会自己触发触摸 —— 与 Android 端行为一致。
//

import Foundation

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

    var id: UUID = UUID()
    var kind: Kind
    var text: String
    /// 圆心归一化坐标 0..1
    var centerX: Double
    var centerY: Double
    /// 直径，相对屏幕短边的比例
    var diameterRatio: Double

    init(kind: Kind, text: String? = nil, centerX: Double, centerY: Double, diameterRatio: Double? = nil) {
        self.kind = kind
        self.text = text ?? kind.defaultText
        self.centerX = centerX
        self.centerY = centerY
        self.diameterRatio = diameterRatio ?? Double(kind.defaultDiameterRatio)
    }

    /// 文本上限 40 字符，与 Android 端一致
    static let maxTextLength = 40
}

/// 一套布局预设
struct LayoutPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var stickers: [LayoutSticker]
    var updatedAt: Date = Date()
}
