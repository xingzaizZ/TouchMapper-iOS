//
//  ConnectionView.swift
//  TouchMapper iOS
//
//  连接面板：输入电脑 IPv4 + 端口，连 / 断。
//  对应 Android 端 ConnectionPanel。
//

import SwiftUI

struct ConnectionView: View {

    @ObservedObject var connection: TouchConnection
    @ObservedObject var session: TouchSession

    @Binding var stickers: [LayoutSticker]
    @Binding var isFullScreen: Bool

    @State private var showDiagnostics = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    addressCard
                    actionRow
                    hintCard
                    if showDiagnostics {
                        diagnosticsCard
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("触控映射")
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 卡片

    private var headerCard: some View {
        VStack(spacing: 10) {
            Image(systemName: connection.status.isConnected ? "wifi" : "wifi.slash")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(connection.status.isConnected ? Color.green : Color.secondary)

            Text(connection.status.displayText)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Wi-Fi 局域网 · 默认端口 \(TouchMapperProtocol.defaultPort)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(cardBackground)
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("电脑 IPv4 地址")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("例如 192.168.1.23", text: $connection.host)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numbersAndPunctuation)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .disabled(connection.status.isConnected)

            HStack {
                Text("端口").font(.subheadline)
                TextField("17890", value: Binding(
                    get: { connection.port },
                    set: { connection.port = $0 }
                ), format: .number)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
                .frame(width: 110)
                .disabled(connection.status.isConnected)

                Spacer()
            }

            Text("填电脑当前 Wi-Fi 的 IPv4，不是路由器地址，也不是手机自己的 IP。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var actionRow: some View {
        VStack(spacing: 12) {
            if connection.status.isConnected {
                Button {
                    isFullScreen = true
                } label: {
                    HStack {
                        Image(systemName: "hand.tap.fill")
                        Text("进入全屏触控")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    connection.disconnect()
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("断开电脑")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .foregroundColor(.red)
            } else {
                Button {
                    connection.connect()
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.fill")
                        Text("连接电脑")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    withAnimation { showDiagnostics.toggle() }
                } label: {
                    Text(showDiagnostics ? "隐藏连接诊断" : "显示连接诊断")
                        .font(.footnote)
                }
            }
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("使用要点").font(.subheadline).fontWeight(.semibold)
            }

            bullet("电脑端 TouchMapper.exe 必须保持运行，窗口显示「等待手机连接」。")
            bullet("手机和电脑要连同一个 Wi-Fi；访客网络、客户端隔离会挡住互访。")
            bullet("第一次连不上，先在 Windows 防火墙允许该程序通过「专用网络」。")
            bullet("把游戏或模拟器设为全屏，并让手机与电脑画面方向一致，位置才对得上。")
            bullet("屏幕上那些按钮只是位置提示，不会自己触发；真正发送的是你的手指位置。")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                Text("连接诊断").font(.subheadline).fontWeight(.semibold)
            }

            row("目标地址", TouchMapperProtocol.url(host: connection.host, port: connection.port)?.absoluteString ?? "地址无效")
            row("已发送包数", "\(connection.sentPackets)")
            row("丢弃的移动包", "\(connection.droppedMoves)")
            row("本机 IP", LocalNetworkInfo.wifiIPv4() ?? "未取到（需在 Wi-Fi 下）")

            Text("iOS 14 以上首次连接局域网会弹「本地网络」权限，拒绝后无法连接；到 设置 → 隐私与安全性 → 本地网络 里重新打开。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundColor(.secondary)
            Text(text).font(.footnote)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
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
