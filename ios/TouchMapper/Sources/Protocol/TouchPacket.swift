//
//  TouchPacket.swift
//  TouchMapper iOS
//
//  与 Windows 端 TouchMapper.exe 的协议定义，字段名与服务端一致。
//

import Foundation

/// 全屏触控消息。服务端用 JsonSerializerDefaults.Web 反序列化，字段名大小写不敏感，
/// 但统一用这里的驼峰写法，保证和 Android 端发出的报文一致。
struct ScreenTouchPacket: Codable {
    /// 固定 "screen-touch"
    let type: String
    /// "down" | "move" | "up" | "cancel"，服务端会 ToLowerInvariant 归一，这里直接发小写
    let phase: String
    /// 归一化横坐标 0.0 ~ 1.0
    let x: Float
    /// 归一化纵坐标 0.0 ~ 1.0
    let y: Float
    /// 单调递增序号，服务端透传不校验
    let sequence: Int64
    /// 触点 ID，同一根手指必须保持一致
    let contactId: Int
    /// 手机内容区宽度（px），服务端不参与坐标计算
    let screenWidth: Int
    /// 手机内容区高度（px）
    let screenHeight: Int

    enum Phase: String {
        case down
        case move
        case up
        case cancel
    }

    init(phase: Phase,
         x: Float,
         y: Float,
         sequence: Int64,
         contactId: Int,
         screenWidth: Int,
         screenHeight: Int) {
        self.type = "screen-touch"
        self.phase = phase.rawValue
        self.x = x
        self.y = y
        self.sequence = sequence
        self.contactId = contactId
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

/// 摇杆消息。
///
/// 服务端语义（反编译 TouchInjector.CalculatePosition 得到）：
///   · x / y 是 **相对摇杆中心的归一化偏移**，0.5 = 正中心
///   · 偏移量 (x-0.5)*2*radius、(y-0.5)*2*radius 加在电脑端设定的中心点上
///   · 超出 radius 会被截断到圆周上（服务端做了向量归一化）
///   · down 时服务端强制先发一个 (0.5, 0.5) 的按下，再发真实位置
///   · 摇杆只有一个触点，pointerId 固定 0；电脑端必须已「锁定并开始控制」，否则整包被忽略
struct JoystickPacket: Codable {
    /// 固定 "joystick"
    let type: String
    /// "down" | "move" | "up" | "cancel"
    let phase: String
    /// 0.0 ~ 1.0，0.5 为正中心
    let x: Float
    let y: Float
    let sequence: Int64
    /// 摇杆恒为 0
    let contactId: Int

    enum Phase: String {
        case down
        case move
        case up
        case cancel
    }

    init(phase: Phase, x: Float, y: Float, sequence: Int64, contactId: Int = 0) {
        self.type = "joystick"
        self.phase = phase.rawValue
        self.x = x
        self.y = y
        self.sequence = sequence
        self.contactId = contactId
    }
}

/// 服务端默认端口
enum TouchMapperProtocol {
    static let defaultPort: Int = 17890
    static let path: String = "/touch"
    /// 服务端单连接上限
    static let maxContacts: Int = 10
    /// 摇杆半径取值范围（电脑端 clamp 到 20...160）
    static let joystickRadiusRange: ClosedRange<Double> = 20...160
    static let joystickDefaultRadius: Double = 86

    static func url(host: String, port: Int) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmed
        components.port = port
        components.path = path
        return components.url
    }
}
