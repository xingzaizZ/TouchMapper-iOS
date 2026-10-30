//
//  Theme.swift
//  TouchMapper iOS
//
//  深色主题色板，按 Android 版截图取色。
//

import SwiftUI

enum Theme {
    /// 页面背景（近黑偏蓝）
    static let background = Color(red: 0.055, green: 0.075, blue: 0.125)
    /// 卡片背景
    static let card = Color(red: 0.086, green: 0.114, blue: 0.176)
    /// 卡片描边
    static let stroke = Color(red: 0.20, green: 0.27, blue: 0.40)
    /// 主强调色（蓝紫）
    static let accent = Color(red: 0.42, green: 0.60, blue: 0.98)
    /// 次级文字
    static let secondaryText = Color(red: 0.62, green: 0.68, blue: 0.78)
    /// 主文字
    static let primaryText = Color(red: 0.92, green: 0.94, blue: 0.98)
    /// 摇杆底座描边
    static let padStroke = Color(red: 0.36, green: 0.50, blue: 0.78)
    /// 选中态胶囊背景
    static let segmentSelected = Color(red: 0.42, green: 0.60, blue: 0.98)
}

struct DarkCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
            )
    }
}
