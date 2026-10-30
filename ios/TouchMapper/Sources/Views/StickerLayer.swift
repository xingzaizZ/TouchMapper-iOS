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
                        position: position(for: sticker, container: size),
                        onDelete: { remove(sticker.id) },
                        onEditText: { editingTarget = sticker },
                        onDragChanged: { translation in handleDragChanged(translation, sticker, size) },
                        onDragEnded: { translation in handleDragEnded(translation, sticker, size) },
                        onMagnify: { delta in handleMagnify(delta, sticker) }
                    )
                    .zIndex(draggingId == sticker.id ? 10 : 0)
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

    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if let image = backgroundImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(backgroundOpacity)
                .allowsHitTesting(false)
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
    let position: CGPoint

    let onDelete: () -> Void
    let onEditText: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void

    @State private var lastMagnify: CGFloat = 1

    private var diameter: CGFloat {
        max(28, shortSide * CGFloat(sticker.diameterRatio))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .overlay(
                    Circle().strokeBorder(color.opacity(0.85), lineWidth: 1.5)
                )

            Text(sticker.text)
                .font(.system(size: max(10, diameter * 0.2), weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .frame(width: diameter * 0.85)

            if isEditing {
                deleteBadge
            }
        }
        .frame(width: diameter, height: diameter)
        .position(position)
        .contentShape(Circle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .allowsHitTesting(isEditing)
    }

    private var deleteBadge: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            )
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded(onDelete))
            .offset(x: diameter / 2 - 6, y: -diameter / 2 + 6)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEditing else { return }
                // 手指几乎没动就是点击，交给 tap 处理，避免误拖
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 6 { return }
                onDragChanged(value.translation)
            }
            .onEnded { value in
                guard isEditing else { return }
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 6 {
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
