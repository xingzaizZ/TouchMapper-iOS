//
//  GamePresets.swift
//  TouchMapper iOS
//
//  内置游戏键位。目前是王者荣耀一套横屏布局。
//
//  坐标怎么来的（重要，决定你用起来偏不偏）：
//    下面所有 centerX / centerY 都是「电脑端游戏画面里的相对位置」，
//    不是照抄手机端 UI 尺寸。因为手机全屏触控页铺满的是你手机的整块屏幕，
//    而电脑端游戏是另一块画面，两者比例不同。
//
//  最省事的对齐方法：
//    1. 电脑上把模拟器/游戏开全屏、横屏，保证和手机横屏方向一致；
//    2. 手机全屏页里点「背景」→「导入图片」，把游戏截图铺上去；
//    3. 进「键位」模式，逐个微调这个预设里的圆点，对准截图里的技能圈；
//    4. 存成自己的预设，以后一键切回来。
//
//  centerX 从左往右 0→1，centerY 从上往下 0→1。
//

import Foundation
import CoreGraphics

enum GamePresets {

    /// 一套内置预设
    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let stickers: [LayoutSticker]
    }

    // MARK: - 王者荣耀 · 横屏（三技能英雄）

    /// 王者荣耀标准横屏键位。
    /// 右手区：普攻（大圆）+ 三个技能 + 回城/恢复/召唤师技能；
    /// 左手区：移动摇杆（拖动摇杆模式）。
    static var honorOfKings: [LayoutSticker] {
        var list: [LayoutSticker] = []

        // ── 左手：移动摇杆 ──────────────────────────────
        // 圆不算大，半径单独给到 0.11，手指往里一放就能推。
        list.append(LayoutSticker(kind: .joystick,
                                  text: "移动",
                                  centerX: 0.155,
                                  centerY: 0.72,
                                  diameterRatio: 0.30,
                                  mode: .joystick,
                                  radiusRatio: 0.115,
                                  isMapped: true))

        // ── 右手：普攻 ──────────────────────────────────
        // 王者普攻是点按，不是按住，所以用点击模式、不连发。
        list.append(LayoutSticker(kind: .attack,
                                  text: "普攻",
                                  centerX: 0.855,
                                  centerY: 0.815,
                                  diameterRatio: 0.185,
                                  mode: .point))

        // ── 右手：三个技能 ──────────────────────────────
        // 技能1 离普攻最近，技能2 在外圈，技能3（大招）最靠上。
        list.append(LayoutSticker(kind: .skill,
                                  text: "技能1",
                                  centerX: 0.700,
                                  centerY: 0.795,
                                  diameterRatio: 0.135,
                                  mode: .point))

        list.append(LayoutSticker(kind: .skill,
                                  text: "技能2",
                                  centerX: 0.780,
                                  centerY: 0.640,
                                  diameterRatio: 0.135,
                                  mode: .point))

        list.append(LayoutSticker(kind: .skill,
                                  text: "技能3",
                                  centerX: 0.695,
                                  centerY: 0.520,
                                  diameterRatio: 0.145,
                                  mode: .point))

        // ── 右手：召唤师技能 ────────────────────────────
        list.append(LayoutSticker(kind: .button,
                                  text: "召唤",
                                  centerX: 0.900,
                                  centerY: 0.620,
                                  diameterRatio: 0.095,
                                  mode: .point))

        // ── 右手：回城 / 恢复 ───────────────────────────
        // 这两个在右上/中上，实际会随游戏 UI 浮动，建议对完截图再微调。
        list.append(LayoutSticker(kind: .button,
                                  text: "回城",
                                  centerX: 0.790,
                                  centerY: 0.180,
                                  diameterRatio: 0.075,
                                  mode: .point))

        list.append(LayoutSticker(kind: .button,
                                  text: "恢复",
                                  centerX: 0.890,
                                  centerY: 0.180,
                                  diameterRatio: 0.075,
                                  mode: .point))

        // ── 右下：装备主动（默认关闭映射） ───────────────
        // 只有出了主动装备才用得上，默认 isMapped = false，不干扰走位。
        list.append(LayoutSticker(kind: .button,
                                  text: "装备",
                                  centerX: 0.955,
                                  centerY: 0.830,
                                  diameterRatio: 0.075,
                                  mode: .point,
                                  isMapped: false))

        return list
    }

    // MARK: - 王者荣耀 · 连招版

    /// 把技能改成「按住连发」，适合需要持续按技能的角色/场景。
    static var honorOfKingsBurst: [LayoutSticker] {
        honorOfKings.map { sticker in
            var copy = sticker
            if sticker.kind == .attack {
                copy.burstEnabled = true
                copy.burstInterval = 0.18
            }
            return copy
        }
    }

    // MARK: - 预设清单

    static var all: [Entry] {
        [
            Entry(id: "honor-of-kings",
                  title: "王者荣耀 · 横屏",
                  subtitle: "普攻 + 三技能 + 召唤师技能 + 移动摇杆",
                  stickers: honorOfKings),
            Entry(id: "honor-of-kings-burst",
                  title: "王者荣耀 · 普攻连发",
                  subtitle: "在横屏方案上把普攻改成按住连发",
                  stickers: honorOfKingsBurst)
        ]
    }
}
