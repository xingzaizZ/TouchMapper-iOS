//
//  TouchSession.swift
//  TouchMapper iOS
//
//  多点触控采集 + 坐标归一化。
//  对应 Android 端 FullScreenTouchPanel 的 awaitEachGesture / PointerInteropFilter 逻辑。
//

import UIKit
import SwiftUI

/// 把触摸位置转换成协议需要的归一化坐标，并做 10 触点限流。
@MainActor
final class TouchSession: ObservableObject {

    /// 当前按下的触点，key 是我们自己分配的 contactId。
    /// 用 @Published 而不是 UI 状态，仅用于切后台时取残留触点补发 cancel。
    @Published private(set) var contacts: [Int: CGPoint] = [:]

    /// 内容区尺寸（pt），用于算 normalized 与上报 screenWidth/Height
    private(set) var contentSize: CGSize = .zero
    private(set) var screenScale: CGFloat = UIScreen.main.scale

    private var nextContactId: Int = 0

    func updateContentSize(_ size: CGSize) {
        contentSize = size
        screenScale = UIScreen.main.scale
    }

    /// 像素宽度，服务端仅记录不计算
    var pixelWidth: Int { max(1, Int(contentSize.width * screenScale)) }
    var pixelHeight: Int { max(1, Int(contentSize.height * screenScale)) }

    func normalized(_ point: CGPoint) -> CGPoint {
        guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let x = min(max(point.x / contentSize.width, 0), 1)
        let y = min(max(point.y / contentSize.height, 0), 1)
        return CGPoint(x: x, y: y)
    }

    /// 分配或复用 contactId。iOS 的 UITouch 在 SwiftUI 手势里拿不到稳定 id，
    /// 这里用一个自增池：down 分配、up/cancel 归还。
    func allocateContactId() -> Int? {
        guard contacts.count < TouchMapperProtocol.maxContacts else { return nil }
        for _ in 0..<TouchMapperProtocol.maxContacts {
            let candidate = nextContactId
            nextContactId = (nextContactId + 1) % TouchMapperProtocol.maxContacts
            if contacts[candidate] == nil { return candidate }
        }
        return nil
    }

    func beginContact(id: Int, at point: CGPoint) {
        contacts[id] = normalized(point)
    }

    func moveContact(id: Int, to point: CGPoint) {
        guard contacts[id] != nil else { return }
        contacts[id] = normalized(point)
    }

    func endContact(id: Int) {
        contacts.removeValue(forKey: id)
    }

    func reset() {
        contacts.removeAll()
        nextContactId = 0
    }
}
