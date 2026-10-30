//
//  PresetSheet.swift
//  TouchMapper iOS
//
//  布局预设管理：保存当前布局 / 应用 / 重命名 / 删除。
//  对应 Android 端 LayoutPresetManager。数据存在 UserDefaults。
//

import SwiftUI

@MainActor
final class PresetStore: ObservableObject {

    @Published private(set) var presets: [LayoutPreset] = []

    private let key = "touchmapper.presets"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LayoutPreset].self, from: data) else {
            presets = []
            return
        }
        presets = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func save(name: String, stickers: [LayoutSticker]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "预设 \(presets.count + 1)" : trimmed

        if let idx = presets.firstIndex(where: { $0.name == finalName }) {
            presets[idx].stickers = stickers
            presets[idx].updatedAt = Date()
        } else {
            presets.append(LayoutPreset(name: finalName, stickers: stickers))
        }
        presets.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func rename(_ preset: LayoutPreset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx].name = trimmed
        presets[idx].updatedAt = Date()
        persist()
    }

    func delete(_ preset: LayoutPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }
}

struct PresetSheet: View {

    @Binding var stickers: [LayoutSticker]
    @StateObject private var store = PresetStore()

    @Environment(\.presentationMode) private var presentationMode

    @State private var newName: String = ""
    @State private var renaming: LayoutPreset?
    @State private var renameText: String = ""

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("保存当前布局")) {
                    HStack {
                        TextField("预设名称", text: $newName)
                        Button("保存") {
                            store.save(name: newName, stickers: stickers)
                            newName = ""
                        }
                        .disabled(stickers.isEmpty)
                    }
                }

                Section(header: Text("已保存的预设")) {
                    if store.presets.isEmpty {
                        Text("还没有预设。先摆好按钮布局，再保存一套。")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(store.presets) { preset in
                        presetRow(preset)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.delete(store.presets[index])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("布局预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $renaming) { target in
                RenameSheet(name: renameText) { finalName in
                    store.rename(target, to: finalName)
                    renaming = nil
                } onCancel: {
                    renaming = nil
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func presetRow(_ preset: LayoutPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(preset.name).font(.headline)
                Spacer()
                Button("应用") {
                    stickers = preset.stickers
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("\(preset.stickers.count) 个按钮")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                renameText = preset.name
                renaming = preset
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.delete(preset)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct RenameSheet: View {

    let name: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(name: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.name = name
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: name)
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("预设名称", text: $text)
            }
            .navigationTitle("重命名预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
