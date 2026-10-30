//
//  FullScreenTouchView.swift
//  TouchMapper iOS
//
//  全屏触控页：底层是能接 10 指多点触摸的 UIView，上面盖一层可选显示的贴纸提示。
//  对齐 Android 端 FullScreenTouchPanel + FullTouchToolbar 的行为：
//  贴纸只是位置提示，不触发触摸；实际触摸由手指在屏幕上的位置决定。
//

import SwiftUI

struct FullScreenTouchView: View {

    @ObservedObject var connection: TouchConnection
    @ObservedObject var session: TouchSession

    @Binding var stickers: [LayoutSticker]
    @Binding var isEditingStickers: Bool
    @Binding var isPresented: Bool

    @Binding var backgroundImage: UIImage?
    @Binding var backgroundOpacity: Double

    @State private var showAddPanel = false
    @State private var showPresetSheet = false
    @State private var showImagePicker = false
    @State private var pickedImage: UIImage?
    /// 非 nil 表示这次选图是替换某个键位的图标
    @State private var pendingIconTarget: UUID?
    /// true 表示这次选图一定当键位图标（点「图标」按钮进来的）
    @State private var wantsIconOnly = false
    /// 当前选中的贴纸 id，两个滑杆作用在它身上
    @State private var selectedStickerId: UUID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                // 触摸层必须铺满并且放在最底下；贴纸层只做视觉提示
                MultiTouchCaptureView(
                    onTouchBegan: { id, point in
                        guard !isEditingStickers else { return }
                        session.updateContentSize(proxy.size)
                        session.beginContact(id: id, at: point)
                        let p = session.normalized(point)
                        connection.send(phase: .down,
                                        x: Float(p.x), y: Float(p.y),
                                        contactId: id,
                                        screenWidth: session.pixelWidth,
                                        screenHeight: session.pixelHeight)
                    },
                    onTouchMoved: { id, point in
                        guard !isEditingStickers else { return }
                        session.moveContact(id: id, to: point)
                        let p = session.normalized(point)
                        connection.send(phase: .move,
                                        x: Float(p.x), y: Float(p.y),
                                        contactId: id,
                                        screenWidth: session.pixelWidth,
                                        screenHeight: session.pixelHeight)
                    },
                    onTouchEnded: { id, point in
                        guard !isEditingStickers else { return }
                        let p = session.normalized(point)
                        connection.send(phase: .up,
                                        x: Float(p.x), y: Float(p.y),
                                        contactId: id,
                                        screenWidth: session.pixelWidth,
                                        screenHeight: session.pixelHeight)
                        session.endContact(id: id)
                    },
                    onTouchCancelled: { id, point in
                        let p = session.normalized(point)
                        connection.send(phase: .cancel,
                                        x: Float(p.x), y: Float(p.y),
                                        contactId: id,
                                        screenWidth: session.pixelWidth,
                                        screenHeight: session.pixelHeight)
                        session.endContact(id: id)
                    },
                    onSizeChanged: { size in
                        session.updateContentSize(size)
                    }
                )
                .ignoresSafeArea()

                StickerLayer(
                    stickers: $stickers,
                    backgroundImage: $backgroundImage,
                    backgroundOpacity: $backgroundOpacity,
                    selectedId: $selectedStickerId,
                    isEditing: isEditingStickers
                )
                .ignoresSafeArea()

                VStack(spacing: 8) {
                    toolbar
                    if isEditingStickers {
                        addPanel
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
        .statusBarHidden(true)
        .onDisappear {
            releaseEverything()
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetSheet(stickers: $stickers)
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(
                image: $pickedImage,
                onPicked: {
                    // 用「图标」按钮进来的，直接当键位图标，不再问用途
                    if pendingIconTarget != nil || wantsIconOnly {
                        applyPickedImageAsIcon()
                        wantsIconOnly = false
                        pickedImage = nil
                    } else {
                        // 选完背景图：直接生效，别再弹二次确认（sheet 关闭动画期间弹 dialog 会吞点击）
                        applyPickedImageAsBackground()
                    }
                },
                onCancelled: {
                    pendingIconTarget = nil
                    wantsIconOnly = false
                    pickedImage = nil
                }
            )
        }
    }

    // MARK: - 添加面板（内嵌，不用 actionSheet，sheet 弹着时 actionSheet 会失效）

    private var addPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if showAddPanel {
                    ForEach(LayoutSticker.Kind.allCases, id: \.self) { kind in
                        Button {
                            addSticker(kind, style: .text)
                        } label: {
                            Text(kind.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule().fill(kind.tint.opacity(0.55))
                                )
                        }
                    }

                    // 图标键位：选图后询问用途，这里直接进入选图并标记为图标
                    Button {
                        pendingIconTarget = nil
                        wantsIconOnly = true
                        showImagePicker = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "photo.circle.fill")
                            Text("图标")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.purple.opacity(0.6)))
                    }

                    Button {
                        showAddPanel = false
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(9)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                } else {
                    Button {
                        showAddPanel = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text("添加按键")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                }
                Spacer()
            }

            if backgroundImage != nil {
                HStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.8))

                    Slider(value: $backgroundOpacity, in: 0.05...1.0)
                        .frame(maxWidth: 200)

                    Text("\(Int(backgroundOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 38, alignment: .trailing)

                    Button {
                        backgroundImage = nil
                    } label: {
                        Text("移除")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }

                    Spacer()
                }
            }

            // 选中贴纸后出现：大小 / 不透明度 两条滑杆 + 换图标 / 切回文字
            if let selected = selectedSticker {
                HStack(spacing: 10) {
                    Text(selected.style == .icon ? "图标" : selected.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected.kind.tint)
                        .frame(width: 44, alignment: .leading)
                        .lineLimit(1)

                    Button {
                        // 选中某个键位后再导图，直接替换它的图标
                        pendingIconTarget = selected.id
                        wantsIconOnly = true
                        showImagePicker = true
                    } label: {
                        Image(systemName: "photo.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Button {
                        toggleSelectedStyle()
                    } label: {
                        Image(systemName: selected.style == .icon ? "textformat" : "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    // 圆形 / 方形 切换
                    Button {
                        toggleSelectedShape()
                    } label: {
                        Image(systemName: selected.shape == .circle ? "circle" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Slider(value: Binding(
                        get: { selected.diameterRatio },
                        set: { newValue in updateSelectedDiameter(newValue) }
                    ), in: LayoutSticker.diameterRange)
                    .frame(maxWidth: 140)

                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Slider(value: Binding(
                        get: { selected.opacity },
                        set: { newValue in updateSelectedOpacity(newValue) }
                    ), in: LayoutSticker.opacityRange)
                    .frame(maxWidth: 140)

                    Button {
                        selectedStickerId = nil
                    } label: {
                        Text("取消选中")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    Spacer()
                }
            } else if isEditingStickers {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 11))
                    Text("轻点一个按键，即可用滑杆调它的大小和透明度")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                exitFullScreen()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("退出")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.5)))
                .foregroundStyle(Color.white)
            }

            statusBadge

            Spacer()

            if isEditingStickers {
                Button {
                    // 工具栏这颗按钮：选完图后由用户决定当背景还是当键位图标
                    pendingIconTarget = nil
                    wantsIconOnly = false
                    showImagePicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(backgroundImage == nil ? Color.white : Color.green)
                }

                Button {
                    showPresetSheet = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundStyle(Color.white)
                }
            }

            Toggle(isOn: $isEditingStickers) {
                Text("编辑").font(.caption)
            }
            .fixedSize()

            Text(isEditingStickers ? "编辑中" : "只读")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .foregroundStyle(Color.white)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connection.status.isConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(connection.status.isConnected ? "已连接" : "未连接")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.85))
        }
    }

    // MARK: - 动作

    /// 当前选中的贴纸（滑杆作用对象）
    private var selectedSticker: LayoutSticker? {
        guard let id = selectedStickerId else { return nil }
        return stickers.first { $0.id == id }
    }

    private func updateSelectedDiameter(_ value: Double) {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].diameterRatio = min(max(value, LayoutSticker.diameterRange.lowerBound),
                                          LayoutSticker.diameterRange.upperBound)
    }

    private func updateSelectedOpacity(_ value: Double) {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].opacity = min(max(value, LayoutSticker.opacityRange.lowerBound),
                                    LayoutSticker.opacityRange.upperBound)
    }

    private func addSticker(_ kind: LayoutSticker.Kind, style: LayoutSticker.Style = .text) {
        // 新贴纸放在画布中偏下的位置，按已有数量错开，避免完全重叠
        let index = stickers.count
        let column = index % 4
        let row = (index / 4) % 3
        let sticker = LayoutSticker(kind: kind,
                                    centerX: 0.30 + Double(column) * 0.13,
                                    centerY: 0.70 - Double(row) * 0.11,
                                    style: style)
        stickers.append(sticker)
        // 强反馈，确认真的加上了
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 选完图当背景：立刻生效
    private func applyPickedImageAsBackground() {
        guard let image = pickedImage else { return }
        backgroundImage = image
        pickedImage = nil
        // 背景刚设置时给一个能看见的透明度，避免用户以为没生效
        if backgroundOpacity < 0.2 {
            backgroundOpacity = 0.5
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 选完图后：替换指定键位的图标；没有目标就新建一个图标键位
    private func applyPickedImageAsIcon() {
        guard let image = pickedImage else { return }
        defer { pickedImage = nil }

        if let targetId = pendingIconTarget,
           let idx = stickers.firstIndex(where: { $0.id == targetId }) {
            let fileName = StickerIconStore.save(image, id: targetId)
            stickers[idx].iconFileName = fileName
            stickers[idx].style = .icon
            selectedStickerId = targetId
            pendingIconTarget = nil
            return
        }

        // 没有指定目标：新建一个图标键位
        let newId = UUID()
        let fileName = StickerIconStore.save(image, id: newId)
        let index = stickers.count
        let column = index % 4
        let row = (index / 4) % 3
        var sticker = LayoutSticker(kind: .button,
                                    centerX: 0.30 + Double(column) * 0.13,
                                    centerY: 0.70 - Double(row) * 0.11,
                                    style: .icon,
                                    iconFileName: fileName)
        sticker.id = newId
        stickers.append(sticker)
        selectedStickerId = newId
        pendingIconTarget = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 圆形 ↔ 方形 切换
    private func toggleSelectedShape() {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].shape = stickers[idx].shape == .circle ? .square : .circle
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 图标键位 ↔ 文字键位 切换
    private func toggleSelectedStyle() {        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }

        if stickers[idx].style == .icon {
            stickers[idx].style = .text
        } else if let fileName = stickers[idx].iconFileName {
            stickers[idx].style = .icon
        } else {
            // 还没有图标，进入选图流程
            pendingIconTarget = id
            showImagePicker = true
        }
    }

    private func exitFullScreen() {
        releaseEverything()
        isPresented = false
    }

    private func releaseEverything() {
        let ids = Set(session.contacts.keys)
        connection.releaseAll(contactIds: ids,
                              screenWidth: session.pixelWidth,
                              screenHeight: session.pixelHeight)
        session.reset()
    }
}

extension LayoutSticker.Kind {
    var tint: Color {
        switch self {
        case .joystick: return .cyan
        case .skill:    return .orange
        case .attack:   return .red
        case .button:   return .green
        }
    }
}

// MARK: - 相册选图

struct ImagePicker: UIViewControllerRepresentable {

    @Binding var image: UIImage?
    var onPicked: (() -> Void)?
    var onCancelled: (() -> Void)?
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let picked = info[.originalImage] as? UIImage {
                parent.image = picked
            }
            parent.presentationMode.wrappedValue.dismiss()
            parent.onPicked?()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
            parent.onCancelled?()
        }
    }
}
