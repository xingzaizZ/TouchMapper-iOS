//
//  StickerLayer.swift
//  TouchMapper iOS
//
//  贴纸层：拖动 / 缩放 / 改字 / 删除。对应 Android 端 StickerLayer.kt。
//  贴纸位置与尺寸都用父容器的实际尺寸换算，不用 UIScreen —— 全屏页可能带安全区，
//  用屏幕尺寸会让贴纸和手指位置错开。
//

import SwiftUI

struct StickerLayer: View {

    @Binding var stickers: [LayoutSticker]
    let isEditing: Bool

    @State private var draggingId: UUID?
    @State private var dragStartCenter: CGPoint = .zero
    @State private var editingSticker: LayoutSticker?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shortSide = min(size.width, size.height)

            ZStack(alignment: .topLeading) {
                ForEach($stickers) { $sticker in
                    StickerView(
                        sticker: $sticker,
                        shortSide: shortSide,
                        isEditing: isEditing,
                        onDelete: { remove(sticker.id) },
                        onEditText: { editingSticker = sticker },
                        onDragBegan: {
                            draggingId = sticker.id
                            dragStartCenter = CGPoint(x: sticker.centerX, y: sticker.centerY)
                        },
                        onDragEnded: { translation in
                            applyDrag(translation: translation, id: sticker.id, containerSize: size)
                        },
                        onMagnify: { scale in
                            let ratio = sticker.diameterRatio * Double(scale)
                            sticker.diameterRatio = min(max(ratio, 0.05), 0.7)
                        }
                    )
                    .position(
                        x: CGFloat(sticker.centerX) * size.width,
                        y: CGFloat(sticker.centerY) * size.height
                    )
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(isEditing)
        .sheet(item: $editingSticker) { item in
            StickerTextEditor(sticker: item) { newText in
                updateText(newText, for: item.id)
                editingSticker = nil
            } onCancel: {
                editingSticker = nil
            }
        }
    }

    private func updateText(_ text: String, for id: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].text = String(text.prefix(LayoutSticker.maxTextLength))
    }

    private func remove(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        if draggingId == id { draggingId = nil }
    }

    private func applyDrag(translation: CGSize, id: UUID, containerSize: CGSize) {
        defer { draggingId = nil }
        guard let idx = stickers.firstIndex(where: { $0.id == id }),
              containerSize.width > 0, containerSize.height > 0 else { return }

        let newX = dragStartCenter.x + Double(translation.width / containerSize.width)
        let newY = dragStartCenter.y + Double(translation.height / containerSize.height)

        stickers[idx].centerX = min(max(newX, 0.03), 0.97)
        stickers[idx].centerY = min(max(newY, 0.03), 0.97)
    }
}

private struct StickerView: View {

    @Binding var sticker: LayoutSticker
    let shortSide: CGFloat
    let isEditing: Bool

    let onDelete: () -> Void
    let onEditText: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void

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
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .frame(width: diameter * 0.85)

            if isEditing {
                Circle()
                    .fill(Color.red)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .contentShape(Circle())
                    .onTapGesture(perform: onDelete)
                    .offset(x: diameter / 2 - 6, y: -diameter / 2 + 6)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            TapGesture()
                .onEnded {
                    guard isEditing else { return }
                    onEditText()
                }
                .exclusively(before:
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in onDragBegan() }
                        .onEnded { value in onDragEnded(value.translation) }
                )
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in onMagnify(value) }
        )
        .allowsHitTesting(isEditing)
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
                        .onChange(of: text) { newValue in
                            if newValue.count > LayoutSticker.maxTextLength {
                                text = String(newValue.prefix(LayoutSticker.maxTextLength))
                            }
                        }
                }
            }
            .navigationTitle("修改文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(text) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
