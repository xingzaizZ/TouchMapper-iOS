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

    /// 映射运行时：浏览模式下决定「手指落在哪个按钮 → 发哪个坐标」
    @StateObject private var keyMap = KeyMapRuntime()

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

    /// 是否启用按键映射（关掉就是原版「手指到哪就点哪」的透传）
    @State private var mappingEnabled = true

    /// 连发计时器：每个触点一条
    @State private var burstTasks: [Int: Task<Void, Never>] = [:]

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
                        handleBegan(id: id, point: point, size: proxy.size)
                    },
                    onTouchMoved: { id, point in
                        guard isSendingTouch else { return }
                        session.moveContact(id: id, to: point)
                        handleMoved(id: id, point: point, size: proxy.size)
                    },
                    onTouchEnded: { id, point in
                        guard isSendingTouch else { return }
                        handleEnded(id: id, point: point, size: proxy.size)
                    },
                    onTouchCancelled: { id, point in
                        handleCancelled(id: id, point: point, size: proxy.size)
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
                    isEditing: editTarget == .stickers,
                    activeIds: keyMap.activeStickerIds
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
            mappingEnabled = UserDefaults.standard.object(forKey: "touchmapper.mappingEnabled") as? Bool ?? true
        }
        .onDisappear {
            stopAllBurst()
            releaseTouches()
        }
        .onChange(of: mappingEnabled) { newValue in
            UserDefaults.standard.set(newValue, forKey: "touchmapper.mappingEnabled")
            if !newValue { releaseTouches() }
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

    // MARK: - 触摸处理

    /// 按「落点模式」发一帧。mappingEnabled 关掉就是原版透传。
    private func emit(phase: ScreenTouchPacket.Phase,
                      normalized: CGPoint,
                      contactId: Int) {
        connection.send(phase: phase,
                        x: Float(normalized.x),
                        y: Float(normalized.y),
                        contactId: contactId,
                        screenWidth: session.pixelWidth,
                        screenHeight: session.pixelHeight)
    }

    private func handleBegan(id: Int, point: CGPoint, size: CGSize) {
        session.beginContact(id: id, at: point)

        guard mappingEnabled else {
            // 关闭映射：手指在哪就点哪
            emit(phase: .down, normalized: session.normalized(point), contactId: id)
            return
        }

        guard let contact = keyMap.begin(contactId: id,
                                         point: point,
                                         size: size,
                                         stickers: stickers) else {
            // 没落在任何按钮上：仍然透传，方便临时点游戏里的其它 UI
            emit(phase: .down, normalized: session.normalized(point), contactId: id)
            return
        }

        // 落在按钮上：发按钮锚点
        emit(phase: .down, normalized: contact.anchor, contactId: id)

        // 连发：按住期间按固定间隔重复打点
        if let sticker = stickers.first(where: { $0.id == contact.stickerId }),
           sticker.burstEnabled {
            startBurst(contactId: id, sticker: sticker)
        }
    }

    private func handleMoved(id: Int, point: CGPoint, size: CGSize) {
        guard mappingEnabled else {
            emit(phase: .move, normalized: session.normalized(point), contactId: id)
            return
        }

        guard let target = keyMap.move(contactId: id, point: point, size: size) else {
            // 这个触点不在映射里（起始就透传的），继续按原坐标走
            emit(phase: .move, normalized: session.normalized(point), contactId: id)
            return
        }

        emit(phase: .move, normalized: target, contactId: id)
    }

    private func handleEnded(id: Int, point: CGPoint, size: CGSize) {
        stopBurst(contactId: id)

        if mappingEnabled, let target = keyMap.end(contactId: id) {
            emit(phase: .up, normalized: target, contactId: id)
        } else {
            emit(phase: .up, normalized: session.normalized(point), contactId: id)
        }
        session.endContact(id: id)
    }

    private func handleCancelled(id: Int, point: CGPoint, size: CGSize) {
        stopBurst(contactId: id)

        if let target = keyMap.cancel(contactId: id) {
            emit(phase: .cancel, normalized: target, contactId: id)
        } else {
            emit(phase: .cancel, normalized: session.normalized(point), contactId: id)
        }
        session.endContact(id: id)
    }

    // MARK: - 连发

    /// 每个触点一条连发任务，互不干扰
    private func startBurst(contactId: Int, sticker: LayoutSticker) {
        stopBurst(contactId: contactId)
        let interval = sticker.burstInterval
        guard interval >= LayoutSticker.burstIntervalRange.lowerBound else { return }

        let anchor = CGPoint(x: sticker.centerX, y: sticker.centerY)
        // 只捕获一条发送闭包，不把整个 View 结构体带进 Task，
        // 否则并发上下文会拿到一份 @State 快照，判断「手指是否还按着」会失真。
        let sender = emit
        burstTasks[contactId] = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                sender(.down, anchor, contactId)
                sender(.up, anchor, contactId)
            }
        }
    }

    private func stopBurst(contactId: Int) {
        burstTasks[contactId]?.cancel()
        burstTasks.removeValue(forKey: contactId)
    }

    private func stopAllBurst() {
        for task in burstTasks.values { task.cancel() }
        burstTasks.removeAll()
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

            // 映射总开关：关掉就退回原版「手指在哪点哪」
            Button {
                mappingEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: mappingEnabled ? "hand.tap.fill" : "hand.tap")
                        .font(.system(size: 11))
                    Text(mappingEnabled ? "映射开" : "映射关")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(mappingEnabled
                              ? Color(red: 0.30, green: 0.72, blue: 0.44).opacity(0.85)
                              : Color.white.opacity(0.16))
                )
                .foregroundStyle(Color.white)
            }

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

                // 一键套用王者荣耀键位
                Menu {
                    ForEach(GamePresets.all) { entry in
                        Button(entry.title) {
                            applyGamePreset(entry)
                        }
                    }
                } label: {
                    panelLabel("王者键位", icon: "gamecontroller.fill", active: false)
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
                // 第一行：外形与大小
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
                    .frame(maxWidth: 110)

                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Slider(value: Binding(
                        get: { selected.opacity },
                        set: { updateSelectedOpacity($0) }
                    ), in: LayoutSticker.opacityRange)
                    .frame(maxWidth: 100)

                    Button {
                        selectedStickerId = nil
                    } label: {
                        Text("取消")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    Spacer()
                }

                // 第二行：映射参数（这才是决定游戏里点得准不准的地方）
                mappingRow(for: selected)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10))
                    Text("轻点一个键位，即可调它的大小、透明度与映射方式")
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

    // MARK: - 映射参数行

    /// 选中键位的映射参数：点击/摇杆、摇杆半径、连发、是否参与映射
    @ViewBuilder
    private func mappingRow(for sticker: LayoutSticker) -> some View {
        // 横屏下控件多，放横向滚动里，窄屏也不会被挤扁
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            Text("映射")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))

            // 点击 / 摇杆
            HStack(spacing: 0) {
                ForEach(LayoutSticker.OutputMode.allCases, id: \.self) { mode in
                    Button {
                        updateSelectedMode(mode)
                    } label: {
                        Text(mode.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(sticker.mode == mode
                                          ? Color(red: 0.42, green: 0.60, blue: 0.98)
                                          : Color.clear)
                            )
                            .foregroundStyle(sticker.mode == mode
                                             ? Color.white
                                             : Color.white.opacity(0.6))
                    }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )

            // 摇杆半径（只有摇杆模式有意义）
            if sticker.mode == .joystick {
                Text("半径")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.65))
                Slider(value: Binding(
                    get: { sticker.radiusRatio },
                    set: { updateSelectedRadius($0) }
                ), in: LayoutSticker.radiusRange)
                .frame(maxWidth: 110)
                Text("\(Int(sticker.radiusRatio * 100))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 22, alignment: .trailing)
            }

            // 连发
            Button {
                toggleSelectedBurst()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: sticker.burstEnabled ? "repeat.circle.fill" : "repeat")
                        .font(.system(size: 11))
                    Text("连发")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sticker.burstEnabled
                              ? Color(red: 0.93, green: 0.55, blue: 0.20).opacity(0.9)
                              : Color.white.opacity(0.12))
                )
                .foregroundStyle(Color.white)
            }

            if sticker.burstEnabled {
                Slider(value: Binding(
                    get: { sticker.burstInterval },
                    set: { updateSelectedBurstInterval($0) }
                ), in: LayoutSticker.burstIntervalRange)
                .frame(maxWidth: 90)
                Text(String(format: "%.2fs", sticker.burstInterval))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 38, alignment: .trailing)
            }

            // 是否参与映射
            Button {
                toggleSelectedMapped()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: sticker.isMapped ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                    Text("参与")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .foregroundStyle(sticker.isMapped ? Color.green : Color.white.opacity(0.65))
            }
            }
        }
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

    // MARK: - 映射参数更新

    private func updateSelectedMode(_ mode: LayoutSticker.OutputMode) {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].mode = mode
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateSelectedRadius(_ value: Double) {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].radiusRatio = min(max(value, LayoutSticker.radiusRange.lowerBound),
                                        LayoutSticker.radiusRange.upperBound)
    }

    private func toggleSelectedBurst() {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].burstEnabled.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateSelectedBurstInterval(_ value: Double) {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].burstInterval = min(max(value, LayoutSticker.burstIntervalRange.lowerBound),
                                          LayoutSticker.burstIntervalRange.upperBound)
    }

    private func toggleSelectedMapped() {
        guard let id = selectedStickerId,
              let idx = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[idx].isMapped.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 应用内置游戏预设
    private func applyGamePreset(_ entry: GamePresets.Entry) {
        stickers = entry.stickers
        selectedStickerId = nil
        showAddPanel = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showPresetSheet = false
        isSheetClosing = false
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
        stopAllBurst()
        let ids = Set(session.contacts.keys)
        connection.releaseAll(contactIds: ids,
                              screenWidth: session.pixelWidth,
                              screenHeight: session.pixelHeight)
        session.reset()
        keyMap.reset()
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
