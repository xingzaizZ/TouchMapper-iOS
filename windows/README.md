# TouchMapper · Windows 端（多显示器增强版）

原版 `虚拟多点触控.exe` 把坐标映射到**整块虚拟桌面**，多屏时会跨屏错位。
这个是重写版，**协议完全兼容**，可以替代原版，也可以和原版互换使用（手机端不用改）。

## 相对原版的改动

| 项 | 原版 | 本版 |
|---|---|---|
| 坐标映射 | `GetSystemMetrics(76..79)` 整块虚拟桌面 | 用户选中的那块显示器 |
| 显示器选择 | 无 | 界面上可选，带布局预览 |
| WebSocket | ASP.NET Core Kestrel | TcpListener 手写 RFC6455 |
| 端口绑定 | `http://+:17890/`，需 urlacl 或管理员 | 直接 `TcpListener`，普通权限即可 |
| 协议 | `ws://ip:17890/touch` + JSON | 完全相同 |
| 触摸注入 | `InjectTouchInput` | 相同 |

## 目录

```
windows/
├── TouchMapper.csproj
├── app.manifest
├── Program.cs                    入口，支持 --autostart / --port
├── Screens/ScreenTarget.cs       显示器枚举（EnumDisplayDevices）
├── Input/TouchInjector.cs        Win32 多点触控注入（按选中屏映射）
├── Network/TouchServer.cs        WebSocket 服务端（TcpListener 手写）
└── UI/MainForm.cs                主界面 + 显示器预览
```

## 编译

需要 .NET 8 SDK：

```powershell
cd windows
dotnet publish -c Release -r win-x64 --self-contained true -o publish
```

产物在 `publish/`，双击 `TouchMapper.exe` 即可。

> 注意：不要用 `PublishSingleFile=true`。
> 单文件模式启动时要把本体解压到 `%TEMP%\.net\`，
> 某些机器（临时目录权限受限、被安全软件拦截、或 TEMP 指向不可写盘）会直接崩：
>
> ```
> Failure processing application bundle.
> Failed to create directory [...] for extracting bundled files.
> ```
>
> 用文件夹形式发布最稳。

## 用法

1. 双击 `TouchMapper.exe`
2. 上方选「注入目标显示器」（预览图里会高亮你选的那块）
3. 点「启动服务」
4. 手机端连 `ws://<电脑IP>:17890/touch`

命令行：

```powershell
TouchMapper.exe --autostart              # 启动后自动开始监听
TouchMapper.exe --port 17890             # 指定端口
```

## 多显示器为什么需要这个

原版的计算：

```
px = -1920 + round(x * 3839)     // 副屏在左时
手机 x=0.2 → px = -1152          // 跑到副屏
```

本版的计算：

```csharp
var b = selectedScreen.Bounds;   // 比如主屏 L=0 W=1920
px = b.Left + round(x * (b.Width - 1));
// 手机 x=0.2 → px = 384，稳在主屏内
```

完整原理和排查对照见仓库根目录的 [多显示器说明.md](../多显示器说明.md)。
