//
//  KeyMapping.swift
//  TouchMapper iOS
//
//  按键映射引擎：把「手机屏幕上的手指」重定向成「电脑端游戏里某个按键的触点」。
//
//  为什么需要它：
//    原版全屏触控是把手指坐标原样按比例发给电脑，贴纸只是画在屏幕上的圆圈，
//    点它跟点别的地方没区别。手机上按「攻击」按钮，电脑端收到的还是屏幕那个位置，
//    而电脑端跑的是模拟器里的王者荣耀，按键位置取决于游戏 UI，不是我们画在哪里。
//    所以必须有一层：手指落到哪个贴纸 → 输出该贴纸绑定的电脑端坐标。
//
//  两种落点语义（LayoutSticker.OutputMode）：
//    · point    固定点   —— 技能/攻击/回城：按下即在锚点 down，抬起 up。可配连发。
//    · joystick 拖动摇杆 —— 移动/指向类：以落点为中心，手指位移换算成半径内的偏移，
//                         手指超出半径就截断到圆周。
//  摇杆统一走 screen-touch 的 10 触点通道，不走 android 的 joystick 通道：
//  joystick 通道只能单触点、且电脑端必须先在界面上「锁定中心」，
//  王者荣耀需要同时移动 + 放技能，单通道撑不住。走 screen-touch 才能多键同按。
//
//  几何约定（重要）：
//    归一化坐标 x、y 各自相对内容区宽、高；但圆的判定必须用「等方」长度，
//    否则横屏下同一比例的圆会被算成椭圆。这里统一换算到「短边为 1」的正方形空间
//    （下面把它叫 unit 空间）再算距离，算完再换算回 x/y 归一化。
//

import Foundation
import CoreGraphics

// MARK: - 贴纸输出模式

extension LayoutSticker {

    /// 手指落到这个贴纸时，往电脑端发什么
    enum OutputMode: String, Codable, CaseIterable {
        /// 固定点：按下即 down，抬起即 up。技能、攻击、召唤师技能都属于这种。
        case point
        /// 拖动摇杆：按下取中心，移动按半径换算偏移，抬起归位。方向键、指向类技能用这个。
        case joystick

        var displayName: String {
            switch self {
            case .point:    return "点击"
            case .joystick: return "摇杆"
            }
        }

        var detail: String {
            switch self {
            case .point:    return "按下即触发，适合技能、攻击、回城"
            case .joystick: return "按住拖动，适合移动摇杆与指向类技能"
            }
        }
    }
}

// MARK: - 映射引擎（纯几何计算）

struct KeyMapEngine {

    /// 摇杆半径下限（相对短边的比例）
    static let minRadiusRatio: Double = 0.02
    /// 摇杆半径上限
    static let maxRadiusRatio: Double = 0.60
    /// 命中容差：手指可落在圆外这么多倍半径内，手感更宽松
    static let hitTolerance: CGFloat = 1.35

    // MARK: 空间换算

    /// 归一化坐标 → unit 空间（短边为 1）
    static func toUnit(_ point: CGPoint, aspect: CGFloat) -> CGPoint {
        // aspect = 宽 / 高
        if aspect >= 1 {
            // 横屏：x 覆盖 aspect 个短边单位，y 覆盖 1 个
            return CGPoint(x: point.x * aspect, y: point.y)
        } else {
            // 竖屏：x 覆盖 1 个短边单位，y 覆盖 1/aspect 个
            let inv = 1 / aspect
            return CGPoint(x: point.x, y: point.y * inv)
        }
    }

    /// unit 空间 → 归一化坐标
    static func fromUnit(_ point: CGPoint, aspect: CGFloat) -> CGPoint {
        if aspect >= 1 {
            guard aspect > 0 else { return .zero }
            return CGPoint(x: point.x / aspect, y: point.y)
        } else {
            let inv = 1 / aspect
            guard inv > 0 else { return .zero }
            return CGPoint(x: point.x, y: point.y / inv)
        }
    }

    /// 屏幕 pt → 归一化坐标
    static func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(max(point.x / size.width, 0), 1),
                       y: min(max(point.y / size.height, 0), 1))
    }

    static func aspect(of size: CGSize) -> CGFloat {
        guard size.height > 0 else { return 1 }
        return size.width / size.height
    }

    // MARK: 命中测试

    /// 找命中的贴纸。同时命中多个时取「距离/半径」最小的，避免大圆压住小键。
    static func hitTest(point: CGPoint,
                        stickers: [LayoutSticker],
                        aspect: CGFloat) -> LayoutSticker? {
        guard aspect > 0 else { return nil }

        let p = toUnit(point, aspect: aspect)
        var best: (sticker: LayoutSticker, score: CGFloat)?

        for sticker in stickers {
            guard sticker.isMapped else { continue }

            let c = toUnit(CGPoint(x: sticker.centerX, y: sticker.centerY), aspect: aspect)
            let radius = CGFloat(sticker.diameterRatio) * 0.5
            guard radius > 0 else { continue }

            let dx = p.x - c.x
            let dy = p.y - c.y
            let distance = sqrt(dx * dx + dy * dy)

            let limit = radius * hitTolerance
            guard distance <= limit, limit > 0 else { continue }

            let score = distance / limit
            if best == nil || score < best!.score {
                best = (sticker, score)
            }
        }
        return best?.sticker
    }

    // MARK: 摇杆换算

    /// 手指位移 → 摇杆输出。
    /// - Returns: 电脑端归一化坐标，已截断在半径圆周内
    static func joystickDelta(center: CGPoint,
                              point: CGPoint,
                              radiusRatio: Double,
                              aspect: CGFloat) -> CGPoint {
        guard aspect > 0 else { return center }

        let r = CGFloat(min(max(radiusRatio, minRadiusRatio), maxRadiusRatio))
        let c = toUnit(center, aspect: aspect)
        let p = toUnit(point, aspect: aspect)

        let dx = p.x - c.x
        let dy = p.y - c.y
        let length = sqrt(dx * dx + dy * dy)

        // 手指就在圆心，或半径退化为 0：原地不动
        guard length > 1e-9, r > 1e-9 else { return center }

        // 只有超出半径才截断到圆周，半径内按真实位移（细粒度走位靠这个）
        let scale = length > r ? r / length : 1.0
        let out = CGPoint(x: c.x + dx * scale, y: c.y + dy * scale)

        let result = fromUnit(out, aspect: aspect)
        return CGPoint(x: min(max(result.x, 0), 1), y: min(max(result.y, 0), 1))
    }

    /// 根据视频/截图里的相对位置，把贴纸中心换算成电脑端落点。
    /// 目前一一对应（贴纸中心即落点），留这个口子方便以后做「贴纸与游戏 UI 错位校正」。
    static func anchor(of sticker: LayoutSticker) -> CGPoint {
        CGPoint(x: min(max(sticker.centerX, 0), 1),
                y: min(max(sticker.centerY, 0), 1))
    }
}

// MARK: - 触点状态

/// 一根手指在映射层的完整状态
struct MappedContact {
    let contactId: Int
    let stickerId: UUID
    let mode: LayoutSticker.OutputMode
    /// 锚点：点击的固定落点 / 摇杆的圆心
    let anchor: CGPoint
    /// 上一次实际发出的坐标
    var lastSent: CGPoint
    /// 摇杆半径（相对短边比例）
    let radiusRatio: Double
}

// MARK: - 映射运行时

/// 负责「手指 → 贴纸 → 坐标」的运行时。只管决策，发送交给 TouchConnection。
@MainActor
final class KeyMapRuntime: ObservableObject {

    /// 当前按住的触点
    @Published private(set) var contacts: [Int: MappedContact] = [:]
    /// 当前被按住的贴纸，供高亮
    @Published private(set) var activeStickerIds: Set<UUID> = []

    /// 手指按下：命中返回触点状态，未命中返回 nil
    func begin(contactId: Int,
               point: CGPoint,
               size: CGSize,
               stickers: [LayoutSticker]) -> MappedContact? {
        let normalized = KeyMapEngine.normalize(point, in: size)
        let aspect = KeyMapEngine.aspect(of: size)

        guard let sticker = KeyMapEngine.hitTest(point: normalized,
                                                 stickers: stickers,
                                                 aspect: aspect) else {
            return nil
        }

        let anchor = KeyMapEngine.anchor(of: sticker)
        let radius = sticker.mode == .joystick
            ? sticker.radiusRatio
            : sticker.diameterRatio * 0.5

        let contact = MappedContact(contactId: contactId,
                                    stickerId: sticker.id,
                                    mode: sticker.mode,
                                    anchor: anchor,
                                    lastSent: anchor,
                                    radiusRatio: radius)
        contacts[contactId] = contact
        refreshActive()
        return contact
    }

    /// 手指移动，返回要发出的新坐标
    func move(contactId: Int,
              point: CGPoint,
              size: CGSize) -> CGPoint? {
        guard var contact = contacts[contactId] else { return nil }

        let normalized = KeyMapEngine.normalize(point, in: size)
        let aspect = KeyMapEngine.aspect(of: size)

        let target: CGPoint
        switch contact.mode {
        case .point:
            // 点击类：手指移出按钮也不跑点，固定在锚点
            target = contact.anchor
        case .joystick:
            target = KeyMapEngine.joystickDelta(center: contact.anchor,
                                                point: normalized,
                                                radiusRatio: contact.radiusRatio,
                                                aspect: aspect)
        }

        contact.lastSent = target
        contacts[contactId] = contact
        return target
    }

    /// 手指抬起，返回最终坐标（摇杆归位到圆心）
    func end(contactId: Int) -> CGPoint? {
        guard let contact = contacts.removeValue(forKey: contactId) else { return nil }
        refreshActive()
        return contact.mode == .joystick ? contact.anchor : contact.lastSent
    }

    func cancel(contactId: Int) -> CGPoint? {
        guard let contact = contacts.removeValue(forKey: contactId) else { return nil }
        refreshActive()
        return contact.anchor
    }

    func reset() {
        contacts.removeAll()
        activeStickerIds = []
    }

    func isActive(_ stickerId: UUID) -> Bool {
        activeStickerIds.contains(stickerId)
    }

    private func refreshActive() {
        activeStickerIds = Set(contacts.values.map { $0.stickerId })
    }
}
