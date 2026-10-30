//
//  JoystickPad.swift
//  TouchMapper iOS
//
//  摇杆控件。视觉与 Android 版一致：半透明大圆底座 + 带黑边的蓝色实心摇杆头 + 中心到摇杆头的连线。
//  拖动时摇杆头被限制在底座圆周内，输出 (x, y) ∈ [0,1]，0.5 为正中心。
//

import SwiftUI

struct JoystickPad: View {

    /// 输出的归一化位置，0.5 是正中心
    @Binding var position: CGPoint

    /// 是否处于拖动中
    @Binding var isDragging: Bool

    /// 是否可操作（未连接电脑时置 false，只做视觉预览）
    var isEnabled: Bool = true

    /// 底座直径占可视区域短边的比例
    var padRatio: CGFloat = 0.62

    /// 回调：相位 + 归一化坐标
    var onChange: (JoystickPacket.Phase, CGPoint) -> Void

    @State private var knobOffset: CGSize = .zero

    private let knobRatio: CGFloat = 0.34

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let padDiameter = side * padRatio
            let padRadius = padDiameter / 2
            let knobDiameter = padDiameter * knobRatio
            let knobRadius = knobDiameter / 2
            let maxTravel = padRadius - knobRadius

            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                // 底座
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.16, green: 0.22, blue: 0.36),
                                Color(red: 0.10, green: 0.14, blue: 0.24)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: padRadius
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(
                            Color(red: 0.36, green: 0.50, blue: 0.78).opacity(0.85),
                            lineWidth: 1.5
                        )
                    )
                    .frame(width: padDiameter, height: padDiameter)
                    .position(center)

                // 中心到摇杆头的连线
                if isDragging {
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: CGPoint(
                            x: center.x + knobOffset.width,
                            y: center.y + knobOffset.height
                        ))
                    }
                    .stroke(Color(red: 0.55, green: 0.70, blue: 0.95).opacity(0.55), lineWidth: 2)
                }

                // 摇杆头
                Circle()
                    .fill(Color(red: 0.36, green: 0.55, blue: 0.98))
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.85), lineWidth: knobDiameter * 0.14)
                    )
                    .frame(width: knobDiameter, height: knobDiameter)
                    .position(x: center.x + knobOffset.width,
                              y: center.y + knobOffset.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onChange(.down, normalized(center: center, travel: maxTravel, point: center))
                        }
                        let delta = CGSize(width: value.location.x - center.x,
                                           height: value.location.y - center.y)
                        let clamped = clamp(delta: delta, maxTravel: maxTravel)
                        knobOffset = clamped
                        let moved = normalized(center: center, travel: maxTravel, point: CGPoint(
                            x: center.x + clamped.width,
                            y: center.y + clamped.height
                        ))
                        position = moved
                        onChange(.move, moved)
                    }
                    .onEnded { _ in
                        guard isEnabled else {
                            knobOffset = .zero
                            return
                        }
                        isDragging = false
                        position = CGPoint(x: 0.5, y: 0.5)
                        withAnimation(.easeOut(duration: 0.12)) {
                            knobOffset = .zero
                        }
                        onChange(.up, CGPoint(x: 0.5, y: 0.5))
                    }
            )
        }
        .opacity(isEnabled ? 1.0 : 0.75)
    }

    // MARK: - 数学

    private func clamp(delta: CGSize, maxTravel: CGFloat) -> CGSize {
        guard maxTravel > 0 else { return .zero }
        let length = sqrt(delta.width * delta.width + delta.height * delta.height)
        if length <= maxTravel { return delta }
        let scale = maxTravel / length
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    private func normalized(center: CGPoint, travel: CGFloat, point: CGPoint) -> CGPoint {
        guard travel > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let nx = 0.5 + Double((point.x - center.x) / travel) * 0.5
        let ny = 0.5 + Double((point.y - center.y) / travel) * 0.5
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }
}
