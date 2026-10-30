//
//  StickerLayer.swift
//  TouchMapper iOS
//
//  贴纸层：拖动 / 缩放 / 改字 / 删除 + 背景图。
//
//  性能要点（上一版卡顿的原因）：
//    旧实现只有 DragGesture.onEnded 才真正改 state，onChanged 只做标记，
//    拖动过程中什么都没发生，抬手瞬间一次性跳位 → 视觉上就是"卡一下"。
//    现在 onChanged 每帧直接写 draft 位置，拖动全程跟手。
//
//  为什么不再用 @Binding 数组逐项绑定：
//    拖动时会同时触发父视图整棵重绘（每条 ForEach 的 Binding 都失效），
//    贴纸一多就掉帧。改为传值 + 闭包回写，只在抬手时回写一次。
//

import SwiftUI

struct StickerLayer: View {

    @Binding var stickers: [LayoutSticker]
    @Binding var backgroundImage: UIImage?
    @Binding var backgroundOpacity: Double

    /// 当前选中的贴纸，滑杆作用于它
    @Binding var selectedId: UUID?

    let isEditing: Bool

    @State private var draggingId: UUID?
    @State private var dragDraft: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shortSide = min(size.width, size.height)

            ZStack(alignment: .topLeading) {
                backgroundLayer(size: size)

                ForEach(stickers) { sticker in
                    StickerView(
                        sticker: sticker,
                        shortSide: shortSide,
                        isEditing: isEditing,
                        isSelected: selectedId == sticker.id,
                        position: position(for: sticker, container: size),
                        onDelete: { remove(sticker.id) },
                        onEditText: { editingTarget = sticker },
                        onSelect: { selectedId = sticker.id },
                        onDragChanged: { translation in handleDragChanged(translation, sticker, size) },
                        onDragEnded: { translation in handleDragEnded(translation, sticker, size) },
                        onMagnify: { delta in handleMagnify(delta, sticker) }
                    )
                    .zIndex(draggingId == sticker.id ? 10 : (selectedId == sticker.id ? 5 : 0))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(isEditing)
        .sheet(item: $editingTarget) { target in
            StickerTextEditor(sticker: target) { newText in
                updateText(newText, for: target.id)
                editingTarget = nil
            } onCancel: {
                editingTarget = nil
            }
        }
    }

    @State private var editingTarget: LayoutSticker?

    // MARK: - 背景

    /// 背景图直接铺满整层。注意这里别加 zIndex，否则会被同层贴纸压到下面。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if let image = backgroundImage, backgroundOpacity > 0.01 {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: max(size.width, 1), height: max(size.height, 1))
                .clipped()
                .opacity(backgroundOpacity)
                .allowsHitTesting(false)
                .zIndex(-1)
        }
    }

    // MARK: - 位置

    private func position(for sticker: LayoutSticker, container: CGSize) -> CGPoint {
        if draggingId == sticker.id, let draft = dragDraft {
            return CGPoint(x: draft.x * container.width, y: draft.y * container.height)
        }
        return CGPoint(x: sticker.centerX * container.width, y: sticker.centerY * container.height)
    }

    private func handleDragChanged(_ translation: CGSize, _ sticker: LayoutSticker, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        if draggingId != sticker.id {
            draggingId = sticker.id
        }

        let baseX = sticker.centerX
        let baseY = sticker.centerY
        let nx = min(max(baseX + Double(translation.width / size.width), 0.02), 0.98)
        let ny = min(max(baseY + Double(translation.height / size.height), 0.02), 0.98)
        dragDraft = CGPoint(x: nx, y: ny)
    }

    private func handleDragEnded(_ translation: CGSize, _ sticker: LayoutSticker, _ size: CGSize) {
        defer {
            draggingId = nil
            dragDraft = nil
        }
        guard size.width > 0, size.height > 0,
              let idx = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }

        let nx = min(max(sticker.centerX + Double(translation.width / size.width), 0.02), 0.98)
        let ny = min(max(sticker.centerY + Double(translation.height / size.height), 0.02), 0.98)
        stickers[idx].centerX = nx
        stickers[idx].centerY = ny
    }

    private func handleMagnify(_ delta: CGFloat, _ sticker: LayoutSticker) {
        guard let idx = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        // MagnificationGesture 给的是"相对手势起点的累计倍数"，用增量更稳
        let target = stickers[idx].diameterRatio * Double(delta)
        stickers[idx].diameterRatio = min(max(target, 0.05), 0.7)
    }

    private func updateText(_ text: String, for id: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].text = String(text.prefix(LayoutSticker.maxTextLength))
    }

    private func remove(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        if draggingId == id {
            draggingId = nil
            dragDraft = nil
        }
    }
}

// MARK: - 单个贴纸

private struct StickerView: View {

    let sticker: LayoutSticker
    let shortSide: CGFloat
    let isEditing: Bool
    let isSelected: Bool
    let position: CGPoint

    let onDelete: () -> Void
    let onEditText: () -> Void
    let onSelect: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void

    @State private var lastMagnify: CGFloat = 1

    private var diameter: CGFloat {
        max(22, shortSide * CGFloat(sticker.diameterRatio))
    }

    private var cornerRadius: CGFloat {
        sticker.shape == .circle ? diameter / 2 : diameter * 0.16
    }

    /// 外形裁剪路径：圆形用 Circle，方形用圆角矩形
    @ViewBuilder
    private var shapePath: some View {
        if sticker.shape == .circle {
            Circle().strokeBorder(
                color.opacity(isSelected ? 1.0 : 0.85),
                lineWidth: isSelected ? 2.5 : 1.5
            )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    color.opacity(isSelected ? 1.0 : 0.85),
                    lineWidth: isSelected ? 2.5 : 1.5
                )
        }
    }

    @ViewBuilder
    private var shapeFill: some View {
        if sticker.shape == .circle {
            Circle().fill(color.opacity(0.22))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.opacity(0.22))
        }
    }

    /// 图标按形状裁剪（iOS 15 没有 AnyShape，用分支实现）
    @ViewBuilder
    private func iconImage(_ image: UIImage) -> some View {
        if sticker.shape == .circle {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    var body: some View {
        ZStack {
            // 键位本体：只负责显示与拖动
            ZStack {
                if sticker.style == .icon, let icon = StickerIconStore.load(sticker.iconFileName) {
                    // 图标键位：图片按形状裁剪，外圈描边保证在亮背景上也看得清
                    iconImage(icon)
                        .overlay(shapePath)
                } else {
                    shapeFill
                        .frame(width: diameter, height: diameter)
                        .overlay(shapePath)

                    Text(sticker.text)
                        .font(.system(size: max(9, diameter * 0.2), weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                        .frame(width: diameter * 0.85)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
        }
        // 关键：外框要留出删除徽标溢出的那部分，否则按钮在 frame 之外收不到点击
        .frame(width: diameter + badgeSize, height: diameter + badgeSize)
        .opacity(sticker.opacity)
        .position(position)
        .allowsHitTesting(isEditing)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                deleteBadge
                    .offset(x: 4, y: -4)
            }
        }
    }

    private let badgeSize: CGFloat = 30

    private var deleteBadge: some View {
        Button(action: onDelete) {
            Circle()
                .fill(Color.red)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                )
                // 扩大命中区，手指略微偏一点也能点到
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .frame(width: badgeSize, height: badgeSize)
        .contentShape(Rectangle())
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEditing else { return }
                // 手指几乎没动就是点击，交给 tap 处理，避免误拖
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 6 { return }
                onSelect()
                onDragChanged(value.translation)
            }
            .onEnded { value in
                guard isEditing else { return }
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 6 {
                    // 轻点 = 选中（供滑杆调整），同时进入改字
                    onSelect()
                    onEditText()
                } else {
                    onDragEnded(value.translation)
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isEditing else { return }
                let delta = value / lastMagnify
                lastMagnify = value
                onMagnify(delta)
            }
            .onEnded { _ in
                lastMagnify = 1
            }
    }

    private var color: Color {
        switch sticker.kind {
        case .joystick: return .cyan
        case .skill:    return .orange
        case .attack:   return .red
        case .button:   return .green
        }
    }
}

// MARK: - 改文字

private struct StickerTextEditor: View {
    let sticker: LayoutSticker
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(sticker: LayoutSticker, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.sticker = sticker
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: sticker.text)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("按钮文字（最多 \(LayoutSticker.maxTextLength) 个字符）")) {
                    TextField("文字", text: $text)
                }
            }
            .navigationTitle("修改文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(String(text.prefix(LayoutSticker.maxTextLength))) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
