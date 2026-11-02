# TouchMapper iOS — 用 iPhone 玩电脑上的手游

把 `虚拟多点触控.exe` 的 Android 客户端重写成 iOS 版，**协议完全兼容原版电脑端**，不用换电脑程序。

---

## 本版重点：按键映射（王者荣耀适配）

### 原版为什么不行为什么

原版全屏触控是「手指在哪，电脑端的点就在哪」。屏幕上那些圆圈（技能、攻击、摇杆）**只是画上去的提示**，点它和点旁边空地没区别。

而电脑端跑的是模拟器里的游戏，技能圈位置由游戏 UI 决定。你按自己画的按钮，电脑端收到的是那个位置的坐标 —— 两边对不上，所以技能放空、摇杆推不动。

### 现在的做法

手指落到某个按钮上时，发出的**不是手指坐标，而是这个按钮绑定的坐标**：

| 模式 | 行为 | 适用 |
|---|---|---|
| 点击 | 按下即在按钮中心打点，抬起即松开 | 技能、普攻、召唤师技能、回城 |
| 摇杆 | 以按钮中心为圆心，手指位移换算成半径内偏移，超出截断到圆周 | 移动摇杆、指向类技能 |

摇杆走 10 触点通道，**移动和放技能可以同时按**（原版 joystick 通道只能单触点，且电脑端必须先锁定中心，撑不住实战操作）。

### 三步上手

1. iPhone 和电脑同一个 Wi-Fi，电脑端启动 `虚拟多点触控.exe`；
2. 手机上填电脑 IPv4 → 连接 → 选「全屏触控」→ 进入全屏；
3. 进「键位」模式，点顶部 **王者键位** → 选「王者荣耀 · 横屏」，布局直接铺好。

回「浏览」模式，横屏握持就能玩。

### 对不准的校准法

按钮坐标是相对游戏画面的比例，不同分辨率/模拟器比例会有偏差：

1. 截一张电脑端游戏画面，传到手机；
2. 全屏页 →「背景」→ 导入截图 → 点「铺满」盖住整屏；
3. 回「键位」，把圆圈拖到截图里对应的技能圈上；
4. 点「预设」→ 存成自己的名字，以后一键切回。

选中按钮后，面板第二行是它的映射参数：

- **点击 / 摇杆** —— 切换落点模式
- **半径** —— 摇杆推程，横屏一般 10~14（显示值 ÷ 100）
- **连发** —— 按住时按固定间隔重复打点，可调 0.05~0.50 秒
- **参与** —— 关掉后这个按钮只是视觉参考，手指落上去按原坐标透传

顶部工具栏还有「映射开 / 映射关」总开关，关掉退回原版纯透传。

---

## 这是什么

| 文件 | 说明 |
|---|---|
| `虚拟多点触控.exe` | Windows 端，.NET 8，Kestrel WebSocket 监听 `17890`，调 `InjectTouchInput` 注入多点触控 |
| 本项目 | 把 Android APK 换成 iOS IPA，电脑端原样用 |

## 目录

```
.
├── PROTOCOL.md              # 逆向出来的完整协议（字段、时序、坐标系、注入细节）
├── ios/                     # iOS 工程
│   ├── TouchMapper.xcodeproj
│   └── TouchMapper/
│       ├── Sources/
│       │   ├── TouchMapperApp.swift
│       │   ├── Models/
│       │   │   ├── LayoutSticker.swift    # 按钮模型（含映射字段）
│       │   │   ├── KeyMapping.swift       # 映射引擎 ★
│       │   │   └── GamePresets.swift      # 王者荣耀键位 ★
│       │   ├── Protocol/TouchPacket.swift
│       │   ├── Networking/TouchConnection.swift
│       │   ├── Touch/                     # 多点采集与触点归一化
│       │   └── Views/                     # 连接页、全屏页、按钮层、预设
│       ├── Info.plist
│       └── Assets.xcassets
├── windows/                 # 电脑端 C# 源码
├── tools/
│   ├── swift_lint.py        # 括号/符号/交叉引用自检
│   ├── verify_mapping.py    # 映射算法数值验证（24 项）
│   └── KeyMapCheck.swift    # 同上的 Swift 版
└── .github/workflows/
    └── build-ipa.yml        # 自动打 IPA + 发 Release
```

## 打包 IPA

### 方式一：未签名包（最省事）

1. Actions → `Build IPA` → `Run workflow`；
2. `sign_mode` = `unsigned`，`create_release` = `true`；
3. 跑完去 **Releases** 下 `.ipa`，或 Artifacts 里的 `TouchMapper-ipa`；
4. 用 **Sideloadly** / **AltStore** / **爱思助手** 导入安装（填自己的 Apple ID 自签）。

未签名包不能双击直装 —— iOS 强制要求任何来源的 IPA 都必须用某个 Apple ID 或企业证书签一遍。这一步在手机端做，CI 替代不了。

### 方式二：ad-hoc 签名（需开发者账号）

在仓库 Settings → Secrets 里加：

| Secret | 内容 |
|---|---|
| `IOS_DIST_CERT_P12` | 发布证书 `.p12` 的 base64 |
| `IOS_DIST_CERT_PASSWORD` | `.p12` 密码 |
| `IOS_ADHOC_PROVISION` | ad-hoc 描述文件的 base64 |
| `IOS_KEYCHAIN_PASSWORD` | 随便设，给临时钥匙串用 |

描述文件里必须已包含目标设备 UDID。然后 `sign_mode` 选 `adhoc`。

```bash
base64 -i cert.p12 -o cert.b64
base64 -i adHoc.mobileprovision -o profile.b64
```

## 本地自检

```bash
python tools/swift_lint.py .          # 结构检查
python tools/verify_mapping.py        # 映射算法 24 项验证
xcrun swiftc -parse ios/TouchMapper/Sources/Views/FullScreenTouchView.swift
```

## 常见问题

| 现象 | 处理 |
|---|---|
| 连不上 | 不同 Wi-Fi；Windows 防火墙拦了专用网络 17890 |
| 连上没反应 | 模拟器不接 `InjectTouchInput`；换真机模式或换模拟器 |
| 点按钮没反应 | 「映射开」是否亮着；按钮的「参与」是否被关 |
| 技能位置偏 | 用截图对齐法重摆 |
| 摇杆推不动 | 摇杆半径或按钮直径太小，都调大 |
| 触点粘住 | 切后台/退出会补发 cancel；仍粘住就断开重连 |
| 多显示器错位 | 读 [多显示器说明.md](多显示器说明.md) |
