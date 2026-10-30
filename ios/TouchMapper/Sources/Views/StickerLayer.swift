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

    /// 背景参数走独立发布源，只在背景层订阅，拖动滑杆不影响贴纸
    @ObservedObject var background: BackgroundModel

    /// 当前选中的贴纸，滑杆作用于它
    @Binding var selectedId: UUID?

    let isEditing: Bool

    @State private var editingTarget: LayoutSticker?
    /// 正在关闭上一个 sheet 期间，禁止再次弹出（否则会连续 present 导致卡死）
    @State private var isEditorClosing = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shortSide = min(size.width, size.height)

            ZStack(alignment: .topLeading) {
                if size.width > 0, size.height > 0 {
                    BackgroundLayer(model: background, containerSize: size)
                        .zIndex(-1)
                }

                ForEach(stickers) { sticker in
                    StickerView(
                        sticker: sticker,
                        shortSide: shortSide,
                        isEditing: isEditing,
                        isSelected: selectedId == sticker.id,
                        containerSize: size,
                        onDelete: { remove(sticker.id) },
                        onEditText: { openEditor(for: sticker) },
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
        .sheet(item: $editingTarget, onDismiss: {
            isEditorClosing = false
        }) { target in
            StickerTextEditor(sticker: target) { newText in
                updateText(newText, for: target.id)
                closeEditor()
            } onCancel: {
                closeEditor()
            }
        }
    }

    /// 统一关闭入口：先标记为关闭中，等 onDismiss 回调后再解锁
    private func closeEditor() {
        isEditorClosing = true
        editingTarget = nil
    }

    /// 打开改字面板；关闭动画期间忽略重复请求
    private func openEditor(for sticker: LayoutSticker) {
        guard !isEditorClosing, editingTarget == nil else { return }
        editingTarget = sticker
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

// MARK: - 背景层

/// 独立的背景渲染视图，只订阅 BackgroundModel。
/// 滑杆每帧改的是 model，只有这个视图会重绘，父视图和贴纸完全不受影响。
private struct BackgroundLayer: View {

    @ObservedObject var model: BackgroundModel
    let containerSize: CGSize

    var body: some View {
        Group {
            if let image = model.image, model.opacity > 0.01,
               image.size.width > 0, image.size.height > 0 {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: targetSize(for: image.size).width,
                           height: targetSize(for: image.size).height)
                    .opacity(model.opacity)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .allowsHitTesting(false)
        // 关掉隐式动画，滑杆拖动时不参与动画插值，省一大截开销
        .transaction { $0.animation = nil }
    }

    /// 基准等比适配后再按 X / Y 独立放大（可非等比拉伸）
    private func targetSize(for imageSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(containerSize.width / imageSize.width,
                      containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * fit * CGFloat(model.scaleX),
                      height: imageSize.height * fit * CGFloat(model.scaleY))
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
                // 只挂一个手势，内部区分"点"和"拖"。
                // 之前 tap 与 drag 同时挂，长按会同时触发两者，sheet 被反复打开/关闭 → 卡死。
                .gesture(isEditing ? dragGesture : nil)
                .simultaneousGesture(isEditing ? pinchGesture : nil)

            if isEditing {
                deleteButton
                    .offset(x: deleteBadgeSize * 0.34, y: -deleteBadgeSize * 0.34)
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
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                // 只更新本地 GestureState，不触碰父层 @Binding，拖动全程零重绘
                state = value.translation
            }
            .onChanged { value in
                // 超过阈值才算拖动
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved > 6, !isSelected { onSelect() }
            }
            .onEnded { value in
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved > 6 {
                    guard containerSize.width > 0, containerSize.height > 0 else { return }
                    let nx = sticker.centerX + Double(value.translation.width / containerSize.width)
                    let ny = sticker.centerY + Double(value.translation.height / containerSize.height)
                    onCommitDrag(nx, ny)
                } else {
                    // 位移很小 = 轻点：选中并打开改字
                    onSelect()
                    onEditText()
                }
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
