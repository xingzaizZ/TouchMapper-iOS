//
//  FullScreenTouchView.swift
//  TouchMapper iOS
//
//  全屏触控页。三种模式：
//    · 浏览      —— 手指触摸直接发到电脑
//    · 键位编辑  —— 只操作贴纸，触摸不发送
//    · 背景编辑  —— 只调背景的透明度/横向/纵向缩放，贴纸不响应
//  分开做是为了避免两套滑杆 + 手势同时抢事件、同时触发重绘导致卡死。
//

import SwiftUI

struct FullScreenTouchView: View {

    @ObservedObject var connection: TouchConnection
    @ObservedObject var session: TouchSession

    @Binding var stickers: [LayoutSticker]
    @Binding var isEditingStickers: Bool
    @Binding var isPresented: Bool

    /// 背景参数（独立发布源，避免滑杆拖动导致整页重绘卡死）
    @ObservedObject var background: BackgroundModel

    /// 当前编辑目标
    enum EditTarget: String, CaseIterable {
        case browse
        case stickers
        case background

        var displayName: String {
            switch self {
            case .browse:     return "浏览"
            case .stickers:   return "键位"
            case .background: return "背景"
            }
        }

        var icon: String {
            switch self {
            case .browse:     return "hand.point.up.left"
            case .stickers:   return "square.grid.3x3"
            case .background: return "photo"
            }
        }
    }

    @State private var editTarget: EditTarget = .browse

    @State private var showAddPanel = false
    @State private var showPresetSheet = false
    @State private var showImagePicker = false
    @State private var pickedImage: UIImage?
    @State private var pendingIconTarget: UUID?
    @State private var wantsIconOnly = false
    @State private var selectedStickerId: UUID?

    /// sheet 关闭动画期间锁住，避免连续 present 卡死
    @State private var isSheetClosing = false

    /// 只有浏览模式才发触摸
    private var isSendingTouch: Bool { editTarget == .browse }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                MultiTouchCaptureView(
                    onTouchBegan: { id, point in
                        guard isSendingTouch else { return }
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
                        guard isSendingTouch else { return }
                        session.moveContact(id: id, to: point)
                        let p = session.normalized(point)
                        connection.send(phase: .move,
                                        x: Float(p.x), y: Float(p.y),
                                        contactId: id,
                                        screenWidth: session.pixelWidth,
                                        screenHeight: session.pixelHeight)
                    },
                    onTouchEnded: { id, point in
                        guard isSendingTouch else { return }
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

                // 背景层独立挂在最下面，不经过 StickerLayer 的视图树，
                // 调背景滑杆时不会带着贴纸一起重算。
                BackgroundView(model: background)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                StickerLayer(
                    stickers: $stickers,
                    selectedId: $selectedStickerId,
                    isEditing: editTarget == .stickers
                )
                .ignoresSafeArea()

                VStack(spacing: 8) {
                    toolbar
                    if editTarget == .stickers {
                        stickerPanel
                    }
                    if editTarget == .background {
                        backgroundPanel
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            syncExternalEditFlag()
        }
        .onDisappear {
            releaseTouches()
        }
        .sheet(isPresented: $showPresetSheet, onDismiss: {
            isSheetClosing = false
        }) {
            PresetSheet(stickers: $stickers)
        }
        .sheet(isPresented: $showImagePicker, onDismiss: {
            isSheetClosing = false
        }) {
            ImagePicker(
                image: $pickedImage,
                onPicked: {
                    if pendingIconTarget != nil || wantsIconOnly {
                        applyPickedImageAsIcon()
                        wantsIconOnly = false
                        pickedImage = nil
                    } else {
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

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
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

            modeSegment
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .foregroundStyle(Color.white)
    }

    /// 浏览 / 键位 / 背景 三段式切换
    private var modeSegment: some View {
        HStack(spacing: 0) {
            ForEach(EditTarget.allCases, id: \.self) { target in
                Button {
                    switchTo(target)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: target.icon)
                            .font(.system(size: 11))
                        Text(target.displayName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(editTarget == target
                                  ? Color(red: 0.42, green: 0.60, blue: 0.98)
                                  : Color.clear)
                    )
                    .foregroundStyle(editTarget == target ? Color.white : Color.white.opacity(0.75))
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connection.status.isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(connection.status.isConnected ? "已连接" : "未连接")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.85))
        }
    }

    // MARK: - 键位面板

    private var stickerPanel: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    pendingIconTarget = nil
                    wantsIconOnly = false
                    openImagePicker()
                } label: {
                    panelLabel("导入图片", icon: "photo.on.rectangle",
                               active: background.image != nil)
                }

                Button {
                    openPresetSheet()
                } label: {
                    panelLabel("预设", icon: "square.grid.2x2", active: false)
                }

                if showAddPanel {
                    ForEach(LayoutSticker.Kind.allCases, id: \.self) { kind in
                        Button {
                            addSticker(kind, style: .text)
                        } label: {
                            Text(kind.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(kind.tint.opacity(0.6)))
                        }
                    }

                    Button {
                        pendingIconTarget = nil
                        wantsIconOnly = true
                        openImagePicker()
                    } label: {
                        Text("图标")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.purple.opacity(0.65)))
                    }

                    Button {
                        showAddPanel = false
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                } else {
                    Button {
                        showAddPanel = true
                    } label: {
                        panelLabel("添加键位", icon: "plus.circle.fill", active: false)
                    }
                }

                Spacer()
            }

            if let selected = selectedSticker {
                HStack(spacing: 9) {
                    Text(selected.style == .icon ? "图标" : selected.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected.kind.tint)
                        .frame(width: 42, alignment: .leading)
                        .lineLimit(1)

                    Button {
                        pendingIconTarget = selected.id
                        wantsIconOnly = true
                        openImagePicker()
                    } label: {
                        Image(systemName: "photo.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Button {
                        toggleSelectedStyle()
                    } label: {
                        Image(systemName: selected.style == .icon ? "textformat" : "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Button {
                        toggleSelectedShape()
                    } label: {
                        Image(systemName: selected.shape == .circle ? "circle" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: Binding(
                        get: { selected.diameterRatio },
                        set: { updateSelectedDiameter($0) }
                    ), in: LayoutSticker.diameterRange)
                    .frame(maxWidth: 120)

                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: Binding(
                        get: { selected.opacity },
                        set: { updateSelectedOpacity($0) }
                    ), in: LayoutSticker.opacityRange)
                    .frame(maxWidth: 120)

                    Button {
                        selectedStickerId = nil
                    } label: {
                        Text("取消")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    Spacer()
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10))
                    Text("轻点一个键位，即可调它的大小和透明度")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }

    // MARK: - 背景面板（独立，不和键位同时出现）

    private var backgroundPanel: some View {
        VStack(spacing: 7) {
            if background.image == nil {
                HStack(spacing: 8) {
                    Button {
                        pendingIconTarget = nil
                        wantsIconOnly = false
                        openImagePicker()
                    } label: {
                        panelLabel("选择背景图", icon: "photo.badge.plus", active: false)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: $background.opacity, in: 0.05...1.0)
                        .frame(maxWidth: 110)
                    Text("\(Int(background.opacity * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 32, alignment: .trailing)

                    Text("横向")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: $background.scaleX, in: 0.3...3.0)
                        .frame(maxWidth: 110)
                    Text("\(Int(background.scaleX * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 36, alignment: .trailing)

                    Text("纵向")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: $background.scaleY, in: 0.3...3.0)
                        .frame(maxWidth: 110)
                    Text("\(Int(background.scaleY * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 36, alignment: .trailing)

                    Button {
                        resetBackgroundTransform()
                    } label: {
                        Text("适配")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Button {
                        fillBackgroundToScreen()
                    } label: {
                        Text("铺满")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    Button {
                        background.setImage(nil)
                    } label: {
                        Text("移除")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }

    private func panelLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(active ? Color.green : Color.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.4)))
    }

    // MARK: - 模式切换

    /// 统一的图片选择入口，关闭动画期间忽略
    private func openImagePicker() {
        guard !isSheetClosing, !showImagePicker else { return }
        isSheetClosing = true
        showImagePicker = true
    }

    /// 统一的预设面板入口
    private func openPresetSheet() {
        guard !isSheetClosing, !showPresetSheet else { return }
        isSheetClosing = true
        showPresetSheet = true
    }

    private func switchTo(_ target: EditTarget) {
        guard target != editTarget else { return }

        if editTarget == .stickers {
            selectedStickerId = nil
            showAddPanel = false
        }

        if target != .browse {
            releaseTouches()
        }

        editTarget = target
        isEditingStickers = (target == .stickers)
    }

    private func syncExternalEditFlag() {
        if isEditingStickers, editTarget == .browse {
            editTarget = .stickers
        }
    }

    // MARK: - 选中贴纸

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

    // MARK: - 添加键位

    private func addSticker(_ kind: LayoutSticker.Kind, style: LayoutSticker.Style = .text) {
        let index = stickers.count
        let column = index % 4
        let row = (index / 4) % 3
        let sticker = LayoutSticker(kind: kind,
                                    centerX: 0.30 + Double(column) * 0.13,
                                    centerY: 0.70 - Double(row) * 0.11,
                                    style: style)
        stickers.append(sticker)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - 图片用途

    private func applyPickedImageAsBackground() {
        guard let image = pickedImage else { return }
        background.setImage(image)
        pickedImage = nil
        if background.opacity < 0.2 {
            background.opacity = 0.5
        }
        editTarget = .background
        isEditingStickers = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

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

    private func toggleSelectedShape() {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].shape = stickers[idx].shape == .circle ? .square : .circle
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func toggleSelectedStyle() {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }

        if stickers[idx].style == .icon {
            stickers[idx].style = .text
        } else if let fileName = stickers[idx].iconFileName, !fileName.isEmpty {
            stickers[idx].style = .icon
        } else {
            pendingIconTarget = id
            wantsIconOnly = true
            openImagePicker()
        }
    }

    // MARK: - 背景变换

    private func resetBackgroundTransform() {
        background.resetToFit()
    }

    private func fillBackgroundToScreen() {
        background.fillToScreen(UIScreen.main.bounds.size)
    }

    // MARK: - 退出

    private func exitFullScreen() {
        releaseTouches()
        isPresented = false
    }

    private func releaseTouches() {
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
