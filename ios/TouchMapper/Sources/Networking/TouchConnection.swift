//
//  TouchConnection.swift
//  TouchMapper iOS
//
//  WebSocket 客户端。等价于 Android 端 TouchChannel.kt：
//  连 ws://host:17890/touch，发送 JSON 文本帧，down/up/cancel 不丢、move 可节流。
//

import Foundation
import Combine

@MainActor
final class TouchConnection: NSObject, ObservableObject {

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var displayText: String {
            switch self {
            case .disconnected: return "未连接"
            case .connecting:   return "正在连接电脑…"
            case .connected:    return "全屏触控已连接"
            case .failed(let message): return "连接失败：\(message)"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - Published

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var sentPackets: Int = 0
    @Published private(set) var droppedMoves: Int = 0

    // MARK: - 配置持久化

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }

    private static let hostKey = "touchmapper.host"
    private static let portKey = "touchmapper.port"

    // MARK: - 内部状态

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var sequence: Int64 = 0
    private var pendingMove: ScreenTouchPacket?
    private var moveFlushTask: Task<Void, Never>?

    /// 摇杆的待发移动包：(x, y)，0.5 为正中心
    private var pendingJoystickMove: (Float, Float)?
    private var joystickFlushTask: Task<Void, Never>?

    /// move 包节流间隔：60Hz
    private let moveIntervalNanos: UInt64 = 16_000_000
    /// 断线自动重连
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false

    override init() {
        let savedHost = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        let savedPort = UserDefaults.standard.object(forKey: Self.portKey) as? Int
        self.host = savedHost
        self.port = savedPort ?? TouchMapperProtocol.defaultPort
        super.init()
    }

    deinit {
        reconnectTask?.cancel()
        moveFlushTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - 连接

    func connect() {
        guard !status.isConnected else { return }
        guard let url = TouchMapperProtocol.url(host: host, port: port) else {
            status = .failed("请输入正确的电脑地址和端口")
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        shouldReconnect = true
        openSocket(url: url)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        moveFlushTask?.cancel()
        moveFlushTask = nil
        pendingMove = nil

        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = .disconnected
    }

    private func openSocket(url: URL) {
        status = .connecting
        sequence = 0
        sentPackets = 0
        droppedMoves = 0

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 0          // 无限，和服务端 readTimeout=0 对齐
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true

        let urlSession = URLSession(configuration: config)
        let webSocketTask = urlSession.webSocketTask(with: url)
        self.session = urlSession
        self.task = webSocketTask

        webSocketTask.resume()
        status = .connected          // URLSession 无 open 回调，先乐观置位，收发出错再降级
        listenForMessages(on: webSocketTask)
    }

    private func listenForMessages(on webSocketTask: URLSessionWebSocketTask) {
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 服务端不发送业务数据；仅用于捕获关闭与错误
                if case .failure(let error) = result {
                    self.handleTransportFailure(error, task: webSocketTask)
                }
            }
        }
    }

    private func handleTransportFailure(_ error: Error, task failedTask: URLSessionWebSocketTask) {
        guard task === failedTask else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil

        guard shouldReconnect else { return }
        status = .failed((error as NSError).localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.shouldReconnect, let url = TouchMapperProtocol.url(host: self.host, port: self.port) else { return }
            self.openSocket(url: url)
        }
    }

    // MARK: - 发送

    /// 发送一个触点事件。down / up / cancel 立即发出；move 走 60Hz 节流。
    func send(phase: ScreenTouchPacket.Phase,
              x: Float,
              y: Float,
              contactId: Int,
              screenWidth: Int,
              screenHeight: Int) {

        guard status.isConnected else { return }

        let packet = ScreenTouchPacket(phase: phase,
                                       x: min(max(x, 0), 1),
                                       y: min(max(y, 0), 1),
                                       sequence: 0,
                                       contactId: contactId,
                                       screenWidth: screenWidth,
                                       screenHeight: screenHeight)

        switch phase {
        case .move:
            // 队列里已有未发出的 move 就覆盖，天然实现「积压时丢弃旧移动包」
            if pendingMove != nil { droppedMoves += 1 }
            pendingMove = packet
            scheduleMoveFlush()
        case .down, .up, .cancel:
            flushPendingMove()
            emit(packet)
        }
    }

    private func scheduleMoveFlush() {
        guard moveFlushTask == nil else { return }
        moveFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.moveIntervalNanos ?? 16_000_000)
            guard !Task.isCancelled, let self else { return }
            self.moveFlushTask = nil
            self.flushPendingMove()
        }
    }

    private func flushPendingMove() {
        moveFlushTask?.cancel()
        moveFlushTask = nil
        guard let packet = pendingMove else { return }
        pendingMove = nil
        emit(packet)
    }

    private func emit(_ packet: ScreenTouchPacket) {
        guard let task, status.isConnected else { return }

        sequence += 1
        let stamped = ScreenTouchPacket(phase: ScreenTouchPacket.Phase(rawValue: packet.phase) ?? .move,
                                        x: packet.x,
                                        y: packet.y,
                                        sequence: sequence,
                                        contactId: packet.contactId,
                                        screenWidth: packet.screenWidth,
                                        screenHeight: packet.screenHeight)

        guard let data = try? JSONEncoder().encode(stamped),
              let text = String(data: data, encoding: .utf8) else { return }

        sentPackets += 1
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, let current = self.task else { return }
                self.handleTransportFailure(error, task: current)
            }
        }
    }

    /// 断线或退出前清空所有触点，避免电脑端触点「粘住」
    func releaseAll(contactIds: Set<Int>, screenWidth: Int, screenHeight: Int) {
        for id in contactIds {
            send(phase: .cancel, x: 0, y: 0, contactId: id,
                 screenWidth: screenWidth, screenHeight: screenHeight)
        }
    }

    // MARK: - 摇杆

    /// 发一个摇杆包。x/y 为相对中心的归一化偏移（0.5 是正中心）。
    /// 摇杆只有单个触点，电脑端要求已「锁定并开始控制」，否则整包被忽略。
    func sendJoystick(phase: JoystickPacket.Phase, x: Float, y: Float) {
        guard status.isConnected else { return }

        switch phase {
        case .move:
            if pendingJoystickMove != nil { droppedMoves += 1 }
            pendingJoystickMove = (min(max(x, 0), 1), min(max(y, 0), 1))
            scheduleJoystickFlush()
        case .down, .up, .cancel:
            flushPendingJoystick()
            emitJoystick(phase: phase, x: x, y: y)
        }
    }

    private func scheduleJoystickFlush() {
        guard joystickFlushTask == nil else { return }
        joystickFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.moveIntervalNanos ?? 16_000_000)
            guard !Task.isCancelled, let self else { return }
            self.joystickFlushTask = nil
            self.flushPendingJoystick()
        }
    }

    private func flushPendingJoystick() {
        joystickFlushTask?.cancel()
        joystickFlushTask = nil
        guard let pending = pendingJoystickMove else { return }
        pendingJoystickMove = nil
        emitJoystick(phase: .move, x: pending.0, y: pending.1)
    }

    private func emitJoystick(phase: JoystickPacket.Phase, x: Float, y: Float) {
        guard let task, status.isConnected else { return }

        sequence += 1
        let packet = JoystickPacket(phase: phase,
                                    x: min(max(x, 0), 1),
                                    y: min(max(y, 0), 1),
                                    sequence: sequence)

        guard let data = try? JSONEncoder().encode(packet),
              let text = String(data: data, encoding: .utf8) else { return }

        sentPackets += 1
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, let current = self.task else { return }
                self.handleTransportFailure(error, task: current)
            }
        }
    }

    /// 松手 / 退出时先把摇杆归零到中心再抬起，避免残留方向
    func releaseJoystick() {
        guard status.isConnected else { return }
        emitJoystick(phase: .cancel, x: 0.5, y: 0.5)
    }
}
