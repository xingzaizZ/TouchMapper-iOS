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

    @State private var showAddMenu = false
    @State private var showPresetSheet = false

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

                StickerLayer(stickers: $stickers, isEditing: isEditingStickers)
                    .ignoresSafeArea()

                VStack {
                    toolbar
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
        .actionSheet(isPresented: $showAddMenu) {
            ActionSheet(
                title: Text("添加按钮"),
                buttons: addMenuButtons()
            )
        }
    }

    private func addMenuButtons() -> [ActionSheet.Button] {
        var buttons: [ActionSheet.Button] = LayoutSticker.Kind.allCases.map { kind in
            ActionSheet.Button.default(Text(kind.displayName)) {
                addSticker(kind)
            }
        }
        buttons.append(.cancel(Text("取消")))
        return buttons
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
                .foregroundColor(.white)
            }

            statusBadge

            Spacer()

            if isEditingStickers {
                Button {
                    showAddMenu = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                }

                Button {
                    showPresetSheet = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundColor(.white)
                }
            }

            Toggle(isOn: $isEditingStickers) {
                Text("编辑按钮").font(.caption)
            }
            .fixedSize()

            Text(isEditingStickers ? "编辑中" : "只读")
                .font(.caption)
                .foregroundColor(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .foregroundColor(.white)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connection.status.isConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(connection.status.isConnected ? "已连接" : "未连接")
                .font(.caption)
                .foregroundColor(Color.white.opacity(0.85))
        }
    }

    // MARK: - 动作

    private func addSticker(_ kind: LayoutSticker.Kind) {
        let offset = Double(stickers.count % 5) * 0.06
        let sticker = LayoutSticker(kind: kind,
                                    centerX: 0.28 + offset,
                                    centerY: 0.72 - offset)
        stickers.append(sticker)
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
