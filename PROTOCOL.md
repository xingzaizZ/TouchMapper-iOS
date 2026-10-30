# TouchMapper 协议规范（逆向自 `虚拟多点触控.exe` + `虚拟多点触控板.apk`）

> 本文所有字段名、大小写、数值语义均来自反编译结果，与线上程序逐字一致。

## 1. 总体架构

```
[iOS/Android 手机]  --WebSocket(ws://)-->  [Windows: TouchMapper.exe]
                                                    |
                                                    v
                                          InjectTouchInput (Win32 多点触控)
```

- 手机把触摸坐标归一化后通过 WebSocket 发给电脑
- 电脑还原成 Windows 触摸事件（不是鼠标事件），注入到当前桌面
- 单向：手机 → 电脑。电脑不回复任何数据

## 2. 传输层

| 项 | 值 |
|---|---|
| 协议 | WebSocket（RFC 6455） |
| URL | `ws://<电脑IPv4>:17890/touch` |
| 端口 | `17890`，服务端 `ListenAnyIP` |
| 路径 | `/touch`（不是 `/`；非 WebSocket 请求返回 404） |
| 子协议 | 无 |
| 帧格式 | 文本帧（`WebSocketMessageType.Text`），UTF-8 |
| 连接数 | 只保留 1 个客户端；新连接会 `Abort()` 掉旧连接 |
| 心跳 | 服务端未配置 ping；客户端可自行发 ping，服务端不校验 |
| 消息大小 | 服务端读缓冲 4096 字节，支持分片累积 |

**Android 端超时配置**（OkHttp，供参考，iOS 不必照抄）：

```
pingInterval = 10s
connectTimeout = 5s
readTimeout = 0s（无限）
writeTimeout = 0s（无限）
```

## 3. 消息格式

每帧是一段 UTF-8 JSON 文本，`type` 字段区分模式：

- `"screen-touch"` → 全屏触控模式
- `"joystick"` → 摇杆模式

### 3.1 screen-touch 消息（全屏触控）

```json
{
  "type": "screen-touch",
  "phase": "down",
  "x": 0.3521,
  "y": 0.7714,
  "sequence": 1234,
  "contactId": 0,
  "screenWidth": 1179,
  "screenHeight": 2556
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 固定 `"screen-touch"` |
| `phase` | string | `"down"` / `"move"` / `"up"` / `"cancel"`，**小写**；服务端会 `ToLowerInvariant()` 归一，但建议直接发小写 |
| `x` | float | **归一化横坐标**，取值 `0.0 ~ 1.0`，相对手机内容区宽度 |
| `y` | float | **归一化纵坐标**，取值 `0.0 ~ 1.0`，相对手机内容区高度 |
| `sequence` | int64 | 单调递增序号，每发一包 +1（服务端只用于透传/调试，不校验） |
| `contactId` | int | 触点 ID，**同一根手指必须保持一致**；服务端按它区分触点 |
| `screenWidth` | int | 手机内容区宽度（px），服务端**不参与坐标计算**，仅记录 |
| `screenHeight` | int | 手机内容区高度（px），同上 |

> 服务端使用 `JsonSerializerDefaults.Web`，即 **PropertyNameCaseInsensitive = true**，且默认 camelCase。
> 因此 `screenWidth` / `ScreenWidth` / `screenwidth` 都能识别，但请统一用上面的写法。

### 3.2 坐标换算（服务端）
服务端拿到 `x, y ∈ [0,1]` 后：

```
px = deskLeft + round(clamp(x, 0, 1) * (deskWidth  - 1))
py = deskTop  + round(clamp(y, 0, 1) * (deskHeight - 1))
```

`deskLeft/Top/Width/Height` 是 **Windows 虚拟桌面（所有显示器合并）** 的边界。

推论（很关键）：

1. 手机画面比例和电脑桌面比例**不一致时不会自动适配**，只会拉满拉伸。
2. 电脑有双屏时，整块虚拟桌面都算进去，游戏窗口只占其中一部分，于是按满屏点触位置会偏。
3. **游戏/模拟器开全屏**，且手机与电脑**画面方向一致**，映射最准。

### 3.3 contactId 语义

- 手指按下：新 `contactId`，`phase = "down"`
- 手指移动：同一 `contactId`，`phase = "move"`
- 手指抬起：同一 `contactId`，`phase = "up"`
- 系统打断（来电、切后台）：对该 `contactId` 发 `phase = "cancel"`

服务端行为：

- 同一个 `contactId` 重复 `down`：先把旧触点释放（`UP|CANCELED`），再新建
- 最多 **10 个触点**，超过直接丢弃并记错
- 收到 `move` / `up` / `cancel` 但 `contactId` 不存在：静默忽略
- 收到 `up` / `cancel` 后从触点表移除；触点表空了就停心跳

### 3.3.1 joystick 消息（摇杆模式）

```json
{
  "type": "joystick",
  "phase": "move",
  "x": 0.5,
  "y": 0.5,
  "sequence": 88,
  "contactId": 0
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 固定 `"joystick"` |
| `phase` | string | `"down"` / `"move"` / `"up"` / `"cancel"` |
| `x` | float | **相对摇杆中心的归一化偏移**，`0.5` = 正中心，范围 `0~1` |
| `y` | float | 同上，纵轴 |
| `sequence` | int64 | 单调递增 |
| `contactId` | int | 摇杆恒为 `0`（单触点） |

**坐标语义和 screen-touch 完全不同**，服务端换算（`TouchInjector.CalculatePosition`）：

```
dx = (clamp(x,0,1) - 0.5) * 2 * radius
dy = (clamp(y,0,1) - 0.5) * 2 * radius
len = sqrt(dx² + dy²)
if len > radius:            # 超出底座就截断到圆周
    dx = dx / len * radius
    dy = dy / len * radius
px = clamp(centerX + dx, 桌面左边, 桌面右边)
py = clamp(centerY + dy, 桌面上边, 桌面下边)
```

- `centerX/centerY/radius` 由**电脑端**决定：界面上「定位中心」把十字拖到游戏左摇杆位置，再点「锁定并开始控制」
- `radius` 电脑端 clamp 到 `20~160` 像素，默认 `86`
- `pointerId` 恒为 `0`，`touchMask = 0x5`，压力 `512`，触点矩形 ±2px

**关键行为（反编译 `JoystickMapping.Apply` 得到）**：

1. 电脑端**未锁定**时，任何摇杆包都被直接丢弃（`Ignored`），不会注入
2. `down` 时服务端先注入一个 `(0.5, 0.5)` 的按下，再补一帧真实位置
3. `move` 来的时候如果还没有活动触点，会被忽略（日志「尚无有效按下触点，请松手后重试」）
4. `down` 时如果有旧触点还在，先 `cancel` 掉旧的
5. 摇杆**没有 50ms 心跳**，松手后必须补一帧 `up`/`cancel`，否则电脑端触点会一直按着
6. 电脑端收到任意一包摇杆，会顺带 `fullScreenInjector.ReleaseAll()`；反之收到全屏触控会 `mapping.Release()`。**两种模式互斥，不能同时按**

### 3.4 电脑端注入细节（iOS 端无需实现，供理解）

- API：`InitializeTouchInjection(10, TOUCH_FEEDBACK_DEFAULT)` + `InjectTouchInput`
- 指针类型 `PT_TOUCH = 2`，`pointerId = slot`（0~9 的逻辑槽位）
- `touchMask = 0x5`（`TOUCH_MASK_CONTACTAREA | TOUCH_MASK_PRESSURE`）
- 触点矩形：以 `(x, y)` 为中心 ±2px
- 压力：`512`
- 按下标志：`POINTER_FLAG_DOWN(0x10000) | INCONTACT(0x4) | INRANGE(0x2)` = `0x10006`
- 移动标志：`POINTER_FLAG_UPDATE(0x20000) | INCONTACT | INRANGE` = `0x20006`
- 抬起标志：`POINTER_FLAG_UP(0x40000) | INCONTACT | INRANGE`；cancel 再加 `CANCELED(0x8000)`
- **心跳 50ms**：只要有触点在，就每 50ms 重发一遍 `UPDATE` 帧，否则 Windows 会判定触点失效

## 4. 时序与压力

Android 端实测（说明文件与日志字符串）：

- 触摸采样统计：`总包 / 移动包 / 事件间隔均值 / 最大间隔 / 最小间隔 / 丢弃移动`
- 移动事件有**合并丢弃机制**：发送队列积压超过阈值时，**丢弃 move 包**（保 down/up）
- `MAX_MOVE_QUEUE_BYTES` 限流，超过即重置连接（日志「发送队列过载，已重置连接」）

iOS 端建议：

- `down` / `up` / `cancel` **必须立即发**，不可丢
- `move` 允许 60Hz 节流 + 队列积压时丢弃最新
- 单帧 JSON 约 130 字节，局域网上毫无压力

## 5. 连接握手（最小可用验证脚本）

```python
# 连上原版 TouchMapper.exe 做冒烟测试
import asyncio, json, websockets

async def main():
    async with websockets.connect("ws://192.168.1.23:17890/touch") as ws:
        seq = 0
        def pkt(phase, x, y, cid):
            nonlocal seq; seq += 1
            return json.dumps({"type":"screen-touch","phase":phase,"x":x,"y":y,
                               "sequence":seq,"contactId":cid,
                               "screenWidth":1179,"screenHeight":2556})
        await ws.send(pkt("down", 0.5, 0.5, 0))   # 按住屏幕正中
        await asyncio.sleep(0.2)
        await ws.send(pkt("up",   0.5, 0.5, 0))   # 抬起

asyncio.run(main())
```

桌面正中会出现一次标准触摸点击。

## 6. 常见失败原因

| 现象 | 原因 |
|---|---|
| 连不上 | 电脑和手机不在同一 Wi-Fi；Windows 防火墙拦了专用网络的 17890 |
| 连上但无反应 | 游戏/模拟器不接收 `InjectTouchInput` 注入的触摸 |
| 位置偏 | 游戏没全屏；手机与电脑方向不一致；多显示器；虚拟桌面边界不等于游戏窗口 |
| 只响应第一根手指 | 客户端复用了同一个 `contactId`，或忘了发 `down` 就发 `move` |
| 触点"粘住" | 客户端发 `up` 失败；补发 `cancel` 可释放，服务端关窗时也会 `ReleaseAll()` |

## 7. 字段名速查（给编码用）

```
type          "screen-touch"
phase         "down" | "move" | "up" | "cancel"
x             float  0..1
y             float  0..1
sequence      long   自增
contactId     int    每指一个
screenWidth   int    手机宽
screenHeight  int    手机高
```

**端口 17890，路径 /touch，全小写，驼峰字段名。**
