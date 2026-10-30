//
//  StickerLayer.swift
//  TouchMapper iOS
//
//  贴纸层：拖动 / 缩放 / 改字 / 删除 + 背景图。
//
//  性能设计（这是修卡死的关键）：
//    拖动全程不碰父视图的 @State / @Binding。
//    每个贴纸自己用 @GestureState 记录实时位移，手势结束时才回写一次坐标。
//    父层的 stickers 数组在整个拖动过程中一次都不变，也就不会触发 ForEach 重建，
//    不会掉帧，更不会把主线程卡住。
//

import SwiftUI

struct StickerLayer: View {

    @Binding var stickers: [LayoutSticker]
    @Binding var backgroundImage: UIImage?
    @Binding var backgroundOpacity: Double
    @Binding var backgroundScale: Double
    /// 背景图偏移，单位是屏幕宽/高的比例，-0.5 ~ 0.5
    @Binding var backgroundOffsetX: Double
    @Binding var backgroundOffsetY: Double

    /// 当前选中的贴纸，滑杆作用于它
    @Binding var selectedId: UUID?

    let isEditing: Bool

    @State private var editingTarget: LayoutSticker?

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
                        containerSize: size,
                        onDelete: { remove(sticker.id) },
                        onEditText: { editingTarget = sticker },
                        onSelect: { selectedId = sticker.id },
                        onCommitDrag: { newX, newY in commitPosition(newX, newY, id: sticker.id) },
                        onCommitSize: { newRatio in commitSize(newRatio, id: sticker.id) }
                    )
                    .zIndex(selectedId == sticker.id ? 5 : 0)
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

    // MARK: - 背景

    /// 背景图按「完整适配屏幕」显示：
    /// · 等比缩放到能完整放进屏幕（fit），不裁切、不放大到溢出
    /// · 四周留黑边，保证你在图上量的位置和实际映射一致
    /// · 若图片比屏幕小很多，允许放大到刚好贴合，避免缩在中间看不清
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if let image = backgroundImage, backgroundOpacity > 0.01,
           size.width > 0, size.height > 0 {
            let fitted = fittedSize(for: image.size, in: size)
            ZStack {
                // 透明底：只让图片自身占位，四周留空不遮住下面的触摸层
                Color.clear

                Image(uiImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .opacity(backgroundOpacity)
                    // 上下左右自定义偏移，按屏幕宽高比例换算
                    .offset(x: CGFloat(backgroundOffsetX) * size.width,
                            y: CGFloat(backgroundOffsetY) * size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .allowsHitTesting(false)
            .zIndex(-1)
        }
    }

    /// 等比缩放：完整放进容器，再乘用户设的缩放系数
    private func fittedSize(for imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return container
        }
        let fit = min(container.width / imageSize.width,
                      container.height / imageSize.height)
        let scale = fit * CGFloat(backgroundScale)
        return CGSize(width: imageSize.width * scale,
                      height: imageSize.height * scale)
    }

    // MARK: - 回写

    private func commitPosition(_ x: Double, _ y: Double, id: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].centerX = min(max(x, 0.02), 0.98)
        stickers[idx].centerY = min(max(y, 0.02), 0.98)
    }

    private func commitSize(_ ratio: Double, id: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].diameterRatio = min(max(ratio,
                                              LayoutSticker.diameterRange.lowerBound),
                                          LayoutSticker.diameterRange.upperBound)
    }

    private func updateText(_ text: String, for id: UUID) {
        guard let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].text = String(text.prefix(LayoutSticker.maxTextLength))
    }

    private func remove(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        if selectedId == id { selectedId = nil }
    }
}

// MARK: - 单个贴纸

private struct StickerView: View {

    let sticker: LayoutSticker
    let shortSide: CGFloat
    let isEditing: Bool
    let isSelected: Bool
    let containerSize: CGSize

    let onDelete: () -> Void
    let onEditText: () -> Void
    let onSelect: () -> Void
    let onCommitDrag: (Double, Double) -> Void
    let onCommitSize: (Double) -> Void

    /// 拖动中的实时位移（手势结束自动归零，不进父状态）
    @GestureState private var dragTranslation: CGSize = .zero
    /// 捏合中的缩放倍数
    @GestureState private var pinchScale: CGFloat = 1

    private var baseDiameter: CGFloat {
        max(22, shortSide * CGFloat(sticker.diameterRatio))
    }

    private var diameter: CGFloat {
        max(22, baseDiameter * pinchScale)
    }

    private var cornerRadius: CGFloat {
        sticker.shape == .circle ? diameter / 2 : diameter * 0.16
    }

    private var currentPosition: CGPoint {
        CGPoint(x: CGFloat(sticker.centerX) * containerSize.width + dragTranslation.width,
                y: CGFloat(sticker.centerY) * containerSize.height + dragTranslation.height)
    }

    var body: some View {
        // 用 ZStack 明确分层：手势层在下铺满，徽标在上且只在自己的小圆里吃事件。
        // 之前把 Button 塞进 .overlay 盖在 .gesture 之上，Button 会把整个贴纸区域的
        // 触摸全吃掉，导致点不中贴纸、拖不动、改不了字。
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
                .gesture(isEditing ? dragGesture : nil)
                .simultaneousGesture(isEditing ? pinchGesture : nil)
                // 轻点 = 选中 + 改字
                .onTapGesture {
                    guard isEditing else { return }
                    onSelect()
                    onEditText()
                }

            if isEditing {
                deleteButton
                    .offset(x: deleteBadgeSize * 0.34, y: -deleteBadgeSize * 0.34)
                    // 只让红叉本身吃事件，不扩大成整块矩形
                    .zIndex(2)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(sticker.opacity)
        .position(currentPosition)
        .allowsHitTesting(isEditing)
    }

    private var deleteBadgeSize: CGFloat { 24 }

    @ViewBuilder
    private var content: some View {
        if sticker.style == .icon, let icon = StickerIconStore.load(sticker.iconFileName) {
            iconImage(icon)
                .overlay(shapeStroke)
        } else {
            shapeFill
                .frame(width: diameter, height: diameter)
                .overlay(shapeStroke)

            Text(sticker.text)
                .font(.system(size: max(9, diameter * 0.2), weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .frame(width: diameter * 0.85)
        }
    }

    /// 图标按形状裁剪（iOS 15 无 AnyShape，用分支实现）
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

    // MARK: - 形状

    @ViewBuilder
    private var shapeFill: some View {
        if sticker.shape == .circle {
            Circle().fill(color.opacity(0.22))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.opacity(0.22))
        }
    }

    @ViewBuilder
    private var shapeStroke: some View {
        if sticker.shape == .circle {
            Circle().strokeBorder(color.opacity(isSelected ? 1.0 : 0.85),
                                  lineWidth: isSelected ? 2.5 : 1.5)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(isSelected ? 1.0 : 0.85),
                              lineWidth: isSelected ? 2.5 : 1.5)
        }
    }

    // MARK: - 删除

    private var deleteButton: some View {
        Button(action: onDelete) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.26, blue: 0.21))
                    .frame(width: deleteBadgeSize, height: deleteBadgeSize)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
                    )
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white)
            }
            // 命中区比视觉大一圈，好点
            .contentShape(Circle().inset(by: -12))
        }
        .buttonStyle(.borderless)
    }

    // MARK: - 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in
                // 只更新本地 GestureState，不触碰父层 @Binding，拖动全程零重绘
                state = value.translation
            }
            .onChanged { _ in
                if !isSelected { onSelect() }
            }
            .onEnded { value in
                guard containerSize.width > 0, containerSize.height > 0 else { return }
                let nx = sticker.centerX + Double(value.translation.width / containerSize.width)
                let ny = sticker.centerY + Double(value.translation.height / containerSize.height)
                onCommitDrag(nx, ny)
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                onCommitSize(sticker.diameterRatio * Double(value))
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
