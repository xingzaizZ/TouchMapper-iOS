//
//  TouchMapperApp.swift
//  TouchMapper iOS
//
//  入口。等价于 Android 端 MainActivity。
//

import SwiftUI

@main
struct TouchMapperApp: App {

    @StateObject private var connection = TouchConnection()
    @StateObject private var session = TouchSession()

    @State private var stickers: [LayoutSticker] = LayoutSticker.defaultLayout
    @State private var isEditingStickers = false
    @State private var isFullScreen = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ConnectionView(
                    connection: connection,
                    session: session,
                    stickers: $stickers,
                    isFullScreen: $isFullScreen
                )

                if isFullScreen {
                    FullScreenTouchView(
                        connection: connection,
                        session: session,
                        stickers: $stickers,
                        isEditingStickers: $isEditingStickers,
                        isPresented: $isFullScreen
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isFullScreen)
            .onChange(of: scenePhase) { phase in
                // 切后台时把没抬起的触点全部释放，避免电脑端触点卡住
                if phase != .active {
                    connection.releaseAll(contactIds: Set(session.contacts.keys),
                                          screenWidth: session.pixelWidth,
                                          screenHeight: session.pixelHeight)
                    session.reset()
                }
            }
        }
    }
}

extension LayoutSticker {
    /// 首启默认布局
    static var defaultLayout: [LayoutSticker] {
        [
            LayoutSticker(kind: .joystick, text: "移动",  centerX: 0.18, centerY: 0.70),
            LayoutSticker(kind: .attack,   text: "攻击",  centerX: 0.84, centerY: 0.78),
            LayoutSticker(kind: .skill,    text: "技能1", centerX: 0.72, centerY: 0.62),
            LayoutSticker(kind: .skill,    text: "技能2", centerX: 0.85, centerY: 0.50),
            LayoutSticker(kind: .button,   text: "蹲",    centerX: 0.09, centerY: 0.45)
        ]
    }
}
