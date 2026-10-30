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

/// 服务端默认端口
enum TouchMapperProtocol {
    static let defaultPort: Int = 17890
    static let path: String = "/touch"
    /// 服务端单连接上限
    static let maxContacts: Int = 10

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
