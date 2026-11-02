// 映射算法独立验证。把 KeyMapping.swift 里的几何部分复制一份，喂真实数值跑一遍。
// 在 Windows 上用 swift 直接执行：swift KeyMapCheck.swift

import Foundation

struct Pt { var x: Double; var y: Double }

let minRadiusRatio = 0.02
let maxRadiusRatio = 0.60
let hitTolerance = 1.35

func toUnit(_ p: Pt, aspect: Double) -> Pt {
    if aspect >= 1 { return Pt(x: p.x * aspect, y: p.y) }
    let inv = 1.0 / aspect
    return Pt(x: p.x, y: p.y * inv)
}

func fromUnit(_ p: Pt, aspect: Double) -> Pt {
    if aspect >= 1 { return Pt(x: p.x / aspect, y: p.y) }
    let inv = 1.0 / aspect
    return Pt(x: p.x, y: p.y / inv)
}

func hitDistance(center: Pt, radiusRatio: Double, point: Pt, aspect: Double) -> Double? {
    let p = toUnit(point, aspect: aspect)
    let c = toUnit(center, aspect: aspect)
    let r = radiusRatio * 0.5
    let dx = p.x - c.x, dy = p.y - c.y
    let d = (dx * dx + dy * dy).squareRoot()
    let limit = r * hitTolerance
    return d <= limit ? d / limit : nil
}

func joystickDelta(center: Pt, point: Pt, radiusRatio: Double, aspect: Double) -> Pt {
    let r = min(max(radiusRatio, minRadiusRatio), maxRadiusRatio)
    let c = toUnit(center, aspect: aspect)
    let p = toUnit(point, aspect: aspect)
    let dx = p.x - c.x, dy = p.y - c.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 1e-9, r > 1e-9 else { return center }
    let scale = len > r ? r / len : 1.0
    let out = Pt(x: c.x + dx * scale, y: c.y + dy * scale)
    let res = fromUnit(out, aspect: aspect)
    return Pt(x: min(max(res.x, 0), 1), y: min(max(res.y, 0), 1))
}

var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("  PASS  \(name)") }
    else { fail += 1; print("  FAIL  \(name)  \(detail)") }
}

let landscape = 2556.0 / 1179.0   // iPhone 横屏 aspect ≈ 2.168

print("== 1. 命中测试：圆心正中央 ==")
let c185 = Pt(x: 0.855, y: 0.815)   // 普攻按钮
check("正中命中", hitDistance(center: c185, radiusRatio: 0.185, point: c185, aspect: landscape) != nil)

print("\n== 2. 命中测试：边缘与容差 ==")
// 半径 0.185/2 = 0.0925 unit；容差后 0.1249 unit
let justInside = Pt(x: 0.855 + 0.10 / landscape, y: 0.815)
check("圆内命中", hitDistance(center: c185, radiusRatio: 0.185, point: justInside, aspect: landscape) != nil)
let wayOutside = Pt(x: 0.855 + 0.20 / landscape, y: 0.815)
check("圆外不命中", hitDistance(center: c185, radiusRatio: 0.185, point: wayOutside, aspect: landscape) == nil)

print("\n== 3. 命中是圆形不是椭圆（横屏关键）==")
// 横向偏移与纵向偏移等长时，命中结果应一致
let dxOnly = Pt(x: 0.855 + 0.09 / landscape, y: 0.815)
let dyOnly = Pt(x: 0.855, y: 0.815 + 0.09)
check("横纵等距同时命中",
      (hitDistance(center: c185, radiusRatio: 0.185, point: dxOnly, aspect: landscape) != nil) ==
      (hitDistance(center: c185, radiusRatio: 0.185, point: dyOnly, aspect: landscape) != nil))

print("\n== 4. 摇杆：圆心 ==")
let jc = Pt(x: 0.155, y: 0.72)
let atCenter = joystickDelta(center: jc, point: jc, radiusRatio: 0.115, aspect: landscape)
check("手指在圆心输出圆心", abs(atCenter.x - jc.x) < 1e-9 && abs(atCenter.y - jc.y) < 1e-9,
      "得到 \(atCenter)")

print("\n== 5. 摇杆：半径内线性 ==")
// 半径 0.115 unit；推到 0.05 unit 应输出 0.05
let half = joystickDelta(center: jc, point: Pt(x: jc.x + 0.05 / landscape, y: jc.y),
                         radiusRatio: 0.115, aspect: landscape)
let expectX = jc.x + 0.05 / landscape
check("半径内按真实位移", abs(half.x - expectX) < 1e-6, "得到 \(half.x), 期望 \(expectX)")

print("\n== 6. 摇杆：超半径截断到圆周 ==")
let far = joystickDelta(center: jc, point: Pt(x: jc.x + 0.50 / landscape, y: jc.y),
                        radiusRatio: 0.115, aspect: landscape)
let offsetUnit = (far.x - jc.x) * landscape
check("超出被截断到半径", abs(offsetUnit - 0.115) < 1e-6, "偏移 \(offsetUnit) unit")

print("\n== 7. 摇杆：斜向截断保持方向 ==")
let diag = joystickDelta(center: jc,
                         point: Pt(x: jc.x + 0.30 / landscape, y: jc.y + 0.30),
                         radiusRatio: 0.115, aspect: landscape)
let ux = (diag.x - jc.x) * landscape
let uy = (diag.y - jc.y)
let length = (ux * ux + uy * uy).squareRoot()
check("斜向长度等于半径", abs(length - 0.115) < 1e-6, "长度 \(length)")
check("斜向 45 度保持", abs(ux - uy) < 1e-6, "ux=\(ux) uy=\(uy)")

print("\n== 8. 输出永远在 0..1 ==")
for p in [Pt(x: 0, y: 0), Pt(x: 1, y: 1), Pt(x: -5, y: 9), Pt(x: 2, y: -3)] {
    let r = joystickDelta(center: jc, point: p, radiusRatio: 0.115, aspect: landscape)
    check("钳制 \(p)", r.x >= 0 && r.x <= 1 && r.y >= 0 && r.y <= 1, "得到 \(r)")
}

print("\n== 9. 竖屏 aspect 也应正常 ==")
let portrait = 1179.0 / 2556.0
let pCenter = Pt(x: 0.5, y: 0.8)
let pOut = joystickDelta(center: pCenter, point: Pt(x: 0.5, y: 0.9),
                         radiusRatio: 0.10, aspect: portrait)
let pOffset = pOut.y - pCenter.y
check("竖屏截断到 0.10 unit", abs(pOffset - 0.10) < 1e-6, "偏移 \(pOffset)")

print("\n== 10. 王者预设坐标全部合法 ==")
let keys: [(String, Double, Double, Double)] = [
    ("移动", 0.155, 0.72, 0.30),
    ("普攻", 0.855, 0.815, 0.185),
    ("技能1", 0.700, 0.795, 0.135),
    ("技能2", 0.780, 0.640, 0.135),
    ("技能3", 0.695, 0.520, 0.145),
    ("召唤", 0.900, 0.620, 0.095),
    ("回城", 0.790, 0.180, 0.075),
    ("恢复", 0.890, 0.180, 0.075),
    ("装备", 0.955, 0.830, 0.075),
]
for (name, x, y, d) in keys {
    let inBounds = x >= 0 && x <= 1 && y >= 0 && y <= 1
    let onScreen = (x - d / 2 / landscape) >= -0.01 && (x + d / 2 / landscape) <= 1.01
    check("\(name) 坐标合法", inBounds && onScreen, "x=\(x) y=\(y)")
}

print("\n== 11. 预设按钮互不重叠（半径和 < 圆心距）==")
var overlaps = 0
for i in 0..<keys.count {
    for j in (i + 1)..<keys.count {
        let a = keys[i], b = keys[j]
        let ax = toUnit(Pt(x: a.1, y: a.2), aspect: landscape)
        let bx = toUnit(Pt(x: b.1, y: b.2), aspect: landscape)
        let dist = ((ax.x - bx.x) * (ax.x - bx.x) + (ax.y - bx.y) * (ax.y - bx.y)).squareRoot()
        if dist < (a.3 + b.3) / 2 {
            overlaps += 1
            print("    重叠: \(a.0) <-> \(b.0) 距离 \(String(format: "%.3f", dist))")
        }
    }
}
check("无重叠", overlaps == 0, "\(overlaps) 处重叠")

print("\n========================")
print("通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
