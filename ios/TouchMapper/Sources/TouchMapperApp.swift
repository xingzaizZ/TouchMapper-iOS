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

    @State private var stickers: [LayoutSticker] = LayoutSticker.loadSaved() ?? LayoutSticker.defaultLayout
    @State private var isEditingStickers = false
    @State private var isFullScreen = false

    /// 键位参考背景图（用来对着电脑画面摆按钮），以及不透明度、缩放
    /// 背景参数集中管理，滑杆只改它，不触发本视图重绘
    @StateObject private var background = BackgroundModel()

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
                        isPresented: $isFullScreen,
                        background: background
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isFullScreen)
            .onChange(of: stickers) { newValue in
                LayoutSticker.save(newValue)
            }
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

    private static let stickersKey = "touchmapper.stickers"
    private static let backgroundKey = "touchmapper.background"
    private static let backgroundOpacityKey = "touchmapper.backgroundOpacity"
    private static let backgroundScaleXKey = "touchmapper.backgroundScaleX"
    private static let backgroundScaleYKey = "touchmapper.backgroundScaleY"
    private static let backgroundFile = "background.png"

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

    // MARK: - 布局持久化

    static func loadSaved() -> [LayoutSticker]? {
        guard let data = UserDefaults.standard.data(forKey: stickersKey),
              let decoded = try? JSONDecoder().decode([LayoutSticker].self, from: data) else {
            return nil
        }
        return decoded
    }

    static func save(_ stickers: [LayoutSticker]) {
        guard let data = try? JSONEncoder().encode(stickers) else { return }
        UserDefaults.standard.set(data, forKey: stickersKey)
    }

    // MARK: - 背景图持久化

    static var backgroundURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(backgroundFile)
    }

    static func loadBackgroundImage() -> UIImage? {
        guard FileManager.default.fileExists(atPath: backgroundURL.path),
              let data = try? Data(contentsOf: backgroundURL) else { return nil }
        return UIImage(data: data)
    }

    static func saveBackgroundImage(_ image: UIImage?) {
        guard let image else {
            try? FileManager.default.removeItem(at: backgroundURL)
            return
        }
        // 压到 2048 长边，避免每次全屏解码超大图拖慢渲染
        let maxSide: CGFloat = 2048
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        if let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: backgroundURL, options: .atomic)
        }
    }

    static func loadBackgroundOpacity() -> Double {
        let value = UserDefaults.standard.object(forKey: backgroundOpacityKey) as? Double
        return value ?? 0.45
    }

    static func saveBackgroundOpacity(_ value: Double) {
        UserDefaults.standard.set(value, forKey: backgroundOpacityKey)
    }

    static func loadBackgroundScaleX() -> Double {
        (UserDefaults.standard.object(forKey: backgroundScaleXKey) as? Double) ?? 1.0
    }

    static func saveBackgroundScaleX(_ value: Double) {
        UserDefaults.standard.set(value, forKey: backgroundScaleXKey)
    }

    static func loadBackgroundScaleY() -> Double {
        (UserDefaults.standard.object(forKey: backgroundScaleYKey) as? Double) ?? 1.0
    }

    static func saveBackgroundScaleY(_ value: Double) {
        UserDefaults.standard.set(value, forKey: backgroundScaleYKey)
    }
}
