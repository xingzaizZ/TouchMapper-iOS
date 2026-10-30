//
//  ConnectionView.swift
//  TouchMapper iOS
//
//  连接面板：按 Android 版截图复刻的深色双栏布局。
//  左栏：模式切换（摇杆 / 全屏触控）、电脑 IPv4、端口、状态、连接按钮
//  右栏：摇杆测试区（可拖动），全屏触控模式下换成操作说明
//

import SwiftUI

enum TouchMode: String, CaseIterable {
    case joystick
    case fullScreen

    var displayName: String {
        switch self {
        case .joystick:   return "摇杆模式"
        case .fullScreen: return "全屏触控"
        }
    }
}

struct ConnectionView: View {

    @ObservedObject var connection: TouchConnection
    @ObservedObject var session: TouchSession

    @Binding var stickers: [LayoutSticker]
    @Binding var isFullScreen: Bool

    @State private var mode: TouchMode = .joystick
    @State private var joystickPosition = CGPoint(x: 0.5, y: 0.5)
    @State private var isJoystickDragging = false
    @State private var showDiagnostics = false

    private var isConnected: Bool { connection.status.isConnected }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            GeometryReader { proxy in
                let isWide = proxy.size.width > 640
                Group {
                    if isWide {
                        HStack(spacing: 14) {
                            leftPanel
                                .frame(maxWidth: proxy.size.width * 0.46)
                            rightPanel
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                leftPanel
                                rightPanel
                                    .frame(height: min(proxy.size.width, 420))
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, isWide ? 10 : 0)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 左栏

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("触控映射")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(Theme.primaryText)

            Text("Wi-Fi 局域网 · 支持摇杆和全屏多点触控")
                .font(.system(size: 14))
                .foregroundColor(Theme.secondaryText)
                .padding(.top, 6)

            modeSelector
                .padding(.top, 18)

            VStack(spacing: 12) {
                hostField
                portField
            }
            .padding(.top, 18)

            statusPill
                .padding(.top, 16)

            Text(hintText)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Spacer(minLength: 16)

            if showDiagnostics {
                diagnostics
                    .padding(.bottom, 10)
            }

            connectButton
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var modeSelector: some View {
        HStack(spacing: 12) {
            ForEach(TouchMode.allCases, id: \.self) { item in
                Button {
                    mode = item
                } label: {
                    Text(item.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(mode == item ? Color.white : Theme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(mode == item ? Theme.segmentSelected : Color.clear)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    mode == item ? Color.clear : Theme.stroke,
                                    lineWidth: 1
                                )
                        )
                }
            }
        }
    }

    private var hostField: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.stroke, lineWidth: 1)
            .frame(height: 58)
            .overlay(
                TextField("电脑 IPv4 地址", text: $connection.host)
                    .textFieldStyle(PlainTextFieldStyle())
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .disabled(isConnected)
                    .foregroundColor(Theme.primaryText)
                    .padding(.horizontal, 14),
                alignment: .leading
            )
    }

    private var portField: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.stroke, lineWidth: 1)
            .frame(height: 58)
            .overlay(
                HStack {
                    Text("端口")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                    TextField("17890", value: Binding(
                        get: { connection.port },
                        set: { connection.port = $0 }
                    ), format: .number)
                    .textFieldStyle(PlainTextFieldStyle())
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(Theme.primaryText)
                    .disabled(isConnected)
                }
                .padding(.horizontal, 14)
            )
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Theme.secondaryText.opacity(0.8))
                .frame(width: 7, height: 7)
            Text(connection.status.displayText)
                .font(.system(size: 14))
                .foregroundColor(Theme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.25))
        )
    }

    private var hintText: String {
        if isConnected {
            switch mode {
            case .joystick:
                return "先在电脑端点“定位中心”并把十字拖到游戏左摇杆上，再点“锁定并开始控制”，然后拖动右边摇杆。"
            case .fullScreen:
                return "点下方按钮进入全屏触控，手指位置会按比例映射到电脑桌面。"
            }
        }
        return "电脑端启动后输入其 IPv4 地址，默认端口 \(TouchMapperProtocol.defaultPort)。连接成功再操作。"
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            diagRow("目标", TouchMapperProtocol.url(host: connection.host, port: connection.port)?.absoluteString ?? "地址无效")
            diagRow("已发送包", "\(connection.sentPackets)")
            diagRow("丢弃移动包", "\(connection.droppedMoves)")
            diagRow("本机 IP", LocalNetworkInfo.wifiIPv4() ?? "未取到")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.25))
        )
    }

    private func diagRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.system(size: 11)).foregroundColor(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if isConnected {
            VStack(spacing: 10) {
                if mode == .fullScreen {
                    Button {
                        isFullScreen = true
                    } label: {
                        Text("进入全屏触控")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Capsule().fill(Theme.accent))
                    }
                }

                Button {
                    releaseCurrentMode()
                    connection.disconnect()
                } label: {
                    Text("断开电脑")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Capsule()
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                }
            }
        } else {
            VStack(spacing: 10) {
                Button {
                    connection.connect()
                } label: {
                    Text("连接电脑")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Capsule().fill(Theme.accent))
                }

                Button {
                    withAnimation { showDiagnostics.toggle() }
                } label: {
                    Text(showDiagnostics ? "隐藏连接诊断" : "显示连接诊断")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }
            }
        }
    }

    // MARK: - 右栏

    private var rightPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.card)

            VStack(spacing: 0) {
                Text(rightTitle)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.secondaryText)
                    .padding(.top, 16)

                if mode == .joystick {
                    JoystickPad(
                        position: $joystickPosition,
                        isDragging: $isJoystickDragging,
                        isEnabled: isConnected,
                        padRatio: 0.62
                    ) { phase, point in
                        connection.sendJoystick(phase: phase,
                                                x: Float(point.x),
                                                y: Float(point.y))
                    }
                    .padding(24)
                } else {
                    fullTouchHint
                }
            }
        }
    }

    private var rightTitle: String {
        if mode == .joystick {
            return isConnected ? "左摇杆测试 · 拖动控制电脑" : "左摇杆测试 · 连接后可拖动"
        }
        return "全屏触控 · 手指位置映射到电脑桌面"
    }

    private var fullTouchHint: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 54, weight: .thin))
                .foregroundColor(Theme.accent.opacity(0.85))
            Text("进入全屏后，在屏幕上按、拖或多指同按，电脑会收到对应位置的触摸。")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - 动作

    private func releaseCurrentMode() {
        connection.releaseJoystick()
        connection.releaseAll(contactIds: Set(session.contacts.keys),
                              screenWidth: session.pixelWidth,
                              screenHeight: session.pixelHeight)
        session.reset()
    }
}

/// 取本机 Wi-Fi 的 IPv4（getifaddrs）
enum LocalNetworkInfo {

    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(addr,
                                             socklen_t(addr.pointee.sa_len),
                                             &hostname, socklen_t(hostname.count),
                                             nil, 0, NI_NUMERICHOST)
                    if result == 0 {
                        address = String(cString: hostname)
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return address
    }
}
