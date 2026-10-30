# TouchMapper iOS — 用 iPhone 玩电脑上的手游

把 `虚拟多点触控.exe` 的 Android 客户端重写成 iOS 版，**协议完全兼容原版电脑端**，不用换电脑程序。

## 这是什么

压缩包 `电脑模拟器玩手游辅助.zip` 里有两样东西：

| 文件 | 说明 |
|---|---|
| `虚拟多点触控.exe` | Windows 端，.NET 8 单文件，开 Kestrel WebSocket 服务监听 `17890`，收到坐标后调 `InjectTouchInput` 注入多点触控 |
| `虚拟多点触控板.apk` | Android 端，Kotlin + Compose，采触摸 → 归一化 → 发 JSON |

本项目是把 **APK 换成 IPA**，电脑端原样用。

## 目录

```
.
├── PROTOCOL.md              # 逆向出来的完整协议（字段、时序、坐标系、注入细节）
├── ios/                     # iOS 工程
│   ├── TouchMapper.xcodeproj
│   ├── TouchMapper/
│   │   ├── Sources/         # 10 个 Swift 文件
│   │   ├── Info.plist
│   │   └── Assets.xcassets
│   └── README.md            # iOS 端细节
└── .github/workflows/
    └── build-ipa.yml        # GitHub Actions 打出未签名 IPA
```

## 三步出货

```bash
# 1. 建仓库并推上去
git init
git add .
git commit -m "TouchMapper iOS: 逆向协议 + Swift 实现 + CI 打 IPA"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

2. 仓库 → **Actions** → **Build IPA** → **Run workflow**
3. 跑完下载 artifact `TouchMapper-unsigned-ipa`，用 Sideloadly / AltStore 重签装到手机

## 协议一句话版

```
ws://<电脑IPv4>:17890/touch

{"type":"screen-touch","phase":"down|move|up|cancel",
 "x":0.0~1.0,"y":0.0~1.0,"sequence":n,
 "contactId":0~9,"screenWidth":px,"screenHeight":px}
```

细节看 [PROTOCOL.md](PROTOCOL.md)。

## 和原版的一致性

| 能力 | Android 原版 | iOS 版 |
|---|---|---|
| WebSocket + JSON 协议 | ✅ | ✅ 逐字段一致 |
| 10 点触控 | ✅ | ✅ |
| 坐标归一化映射到 Windows 虚拟桌面 | ✅ | ✅ |
| move 节流 + 积压丢弃 | ✅ | ✅ 60Hz |
| down/up/cancel 不丢 | ✅ | ✅ |
| 贴纸布局（拖动/缩放/改字/删除） | ✅ | ✅ |
| 布局预设保存/应用/重命名/删除 | ✅ | ✅ |
| 断线重连 | ✅ | ✅ 2 秒 |
| 摇杆模式 | 有（已废弃） | 不实现 |

## 已知限制（继承自原设计）

- 坐标是**整个 Windows 虚拟桌面**拉伸映射，不是窗口级映射。多显示器或游戏非全屏时位置会偏
- 是否响应取决于目标游戏/模拟器认不认 `InjectTouchInput` 注入的触摸
- 必须在同一局域网，且 Windows 防火墙放行 17890 专用网络
