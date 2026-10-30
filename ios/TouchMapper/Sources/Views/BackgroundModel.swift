//
//  BackgroundModel.swift
//  TouchMapper iOS
//
//  背景参数（透明度 / 横向缩放 / 纵向缩放）的独立发布源。
//
//  为什么要单独拆出来：
//    如果滑杆直接写父视图的 @State，每拖一帧都会让整个全屏页重算一遍，
//    里面几十个贴纸跟着 diff，主线程立刻被占满 —— 表现出来就是「调背景卡死」。
//    这里把参数集中到一个 ObservableObject，只有背景层订阅它，
//    拖动时重绘范围就被限制在那一个 Image 上。
//

import SwiftUI
import Combine

@MainActor
final class BackgroundModel: ObservableObject {

    @Published var opacity: Double
    @Published var scaleX: Double
    @Published var scaleY: Double
    @Published var image: UIImage?

    private static let opacityKey = "touchmapper.backgroundOpacity"
    private static let scaleXKey = "touchmapper.backgroundScaleX"
    private static let scaleYKey = "touchmapper.backgroundScaleY"

    init() {
        let ud = UserDefaults.standard
        self.opacity = (ud.object(forKey: Self.opacityKey) as? Double) ?? 0.5
        self.scaleX = (ud.object(forKey: Self.scaleXKey) as? Double) ?? 1.0
        self.scaleY = (ud.object(forKey: Self.scaleYKey) as? Double) ?? 1.0
        self.image = BackgroundModel.loadImage()
    }

    func persist() {
        let ud = UserDefaults.standard
        ud.set(opacity, forKey: Self.opacityKey)
        ud.set(scaleX, forKey: Self.scaleXKey)
        ud.set(scaleY, forKey: Self.scaleYKey)
    }

    func resetToFit() {
        scaleX = 1.0
        scaleY = 1.0
        persist()
    }

    /// 按屏幕比例把图撑满（不等比）
    func fillToScreen(_ screen: CGSize) {
        guard let image, image.size.width > 0, image.size.height > 0,
              screen.width > 0, screen.height > 0 else { return }
        let fit = min(screen.width / image.size.width,
                      screen.height / image.size.height)
        let fittedW = image.size.width * fit
        let fittedH = image.size.height * fit
        scaleX = min(max(Double(screen.width / fittedW), 0.3), 3.0)
        scaleY = min(max(Double(screen.height / fittedH), 0.3), 3.0)
        persist()
    }

    // MARK: - 图片文件

    static var backgroundURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("background.jpg")
    }

    static func loadImage() -> UIImage? {
        guard FileManager.default.fileExists(atPath: backgroundURL.path),
              let data = try? Data(contentsOf: backgroundURL) else { return nil }
        return UIImage(data: data)
    }

    /// 压到 2048 长边再存，避免每次全屏解码超大图
    func setImage(_ newImage: UIImage?) {
        guard let newImage else {
            image = nil
            try? FileManager.default.removeItem(at: BackgroundModel.backgroundURL)
            return
        }

        let maxSide: CGFloat = 2048
        let size = newImage.size
        let ratio = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * ratio),
                            height: max(1, size.height * ratio))

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            newImage.draw(in: CGRect(origin: .zero, size: target))
        }

        if let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: BackgroundModel.backgroundURL, options: .atomic)
        }
        image = resized
        if opacity < 0.2 { opacity = 0.5 }
        persist()
    }
}
