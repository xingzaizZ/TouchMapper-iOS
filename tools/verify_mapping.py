#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
映射算法验证：用与 KeyMapping.swift 逐行对应的 Python 实现跑真实数值。
Swift 侧几何逻辑是纯函数，两边公式一致时结论等价。
"""
import math
import sys

MIN_R = 0.02
MAX_R = 0.60
TOL = 1.35

def to_unit(p, aspect):
    x, y = p
    if aspect >= 1:
        return (x * aspect, y)
    return (x, y / aspect)

def from_unit(p, aspect):
    x, y = p
    if aspect >= 1:
        return (x / aspect, y)
    return (x, y * aspect)

def hit_score(center, radius_ratio, point, aspect):
    p = to_unit(point, aspect)
    c = to_unit(center, aspect)
    r = radius_ratio * 0.5
    dx, dy = p[0] - c[0], p[1] - c[1]
    d = math.hypot(dx, dy)
    limit = r * TOL
    if limit <= 0:
        return None
    return d / limit if d <= limit else None

def joystick_delta(center, point, radius_ratio, aspect):
    r = min(max(radius_ratio, MIN_R), MAX_R)
    c = to_unit(center, aspect)
    p = to_unit(point, aspect)
    dx, dy = p[0] - c[0], p[1] - c[1]
    length = math.hypot(dx, dy)
    if length <= 1e-9 or r <= 1e-9:
        return center
    scale = r / length if length > r else 1.0
    out = from_unit((c[0] + dx * scale, c[1] + dy * scale), aspect)
    return (min(max(out[0], 0), 1), min(max(out[1], 0), 1))

passed = failed = 0
def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")

LAND = 2556.0 / 1179.0   # 横屏 aspect
PORT = 1179.0 / 2556.0

print("== 1. 命中：圆心 / 边缘 / 圆外 ==")
atk = (0.855, 0.815)
check("圆心命中", hit_score(atk, 0.185, atk, LAND) is not None)
check("圆内命中", hit_score(atk, 0.185, (0.855 + 0.10 / LAND, 0.815), LAND) is not None)
check("圆外不命中", hit_score(atk, 0.185, (0.855 + 0.20 / LAND, 0.815), LAND) is None)

print("\n== 2. 横屏下判定是圆不是椭圆 ==")
same_x = hit_score(atk, 0.185, (0.855 + 0.09 / LAND, 0.815), LAND)
same_y = hit_score(atk, 0.185, (0.855, 0.815 + 0.09), LAND)
check("横纵等距结果一致", (same_x is None) == (same_y is None),
      f"x={same_x} y={same_y}")

print("\n== 3. 摇杆：圆心归位 ==")
js = (0.155, 0.72)
at_c = joystick_delta(js, js, 0.115, LAND)
check("圆心输出圆心", abs(at_c[0] - js[0]) < 1e-9 and abs(at_c[1] - js[1]) < 1e-9, str(at_c))

print("\n== 4. 摇杆：半径内按真实位移 ==")
half = joystick_delta(js, (js[0] + 0.05 / LAND, js[1]), 0.115, LAND)
expect = js[0] + 0.05 / LAND
check("半径内线性", abs(half[0] - expect) < 1e-6, f"{half[0]} vs {expect}")

print("\n== 5. 摇杆：超半径截断 ==")
far = joystick_delta(js, (js[0] + 0.50 / LAND, js[1]), 0.115, LAND)
off = (far[0] - js[0]) * LAND
check("截断到半径 0.115", abs(off - 0.115) < 1e-6, f"偏移 {off}")

print("\n== 6. 摇杆：斜向 ==")
d = joystick_delta(js, (js[0] + 0.30 / LAND, js[1] + 0.30), 0.115, LAND)
ux = (d[0] - js[0]) * LAND
uy = d[1] - js[1]
check("斜向长度=半径", abs(math.hypot(ux, uy) - 0.115) < 1e-6, f"{math.hypot(ux,uy)}")
check("斜向方向保持 45°", abs(ux - uy) < 1e-6, f"ux={ux} uy={uy}")

print("\n== 7. 输出恒在 0..1 ==")
ok = True
for p in [(0, 0), (1, 1), (-5, 9), (2, -3), (0.5, 0.5)]:
    r = joystick_delta(js, p, 0.115, LAND)
    if not (0 <= r[0] <= 1 and 0 <= r[1] <= 1):
        ok = False
        print(f"    越界 {p} -> {r}")
check("全部钳制在范围内", ok)

print("\n== 8. 竖屏也正常 ==")
# 竖屏 aspect<1：y 方向 1 个归一化单位 = 1/aspect 个短边单位
# 半径 0.10 unit，推到 0.5 个归一化 y（= 0.5/ PORT unit）必然超半径，应截断到 0.10
pc = (0.5, 0.8)
po = joystick_delta(pc, (0.5, 0.99), 0.10, PORT)
offset_unit = (po[1] - pc[1]) / PORT
check("竖屏超半径截断到 0.10 unit", abs(offset_unit - 0.10) < 1e-6, f"偏移 {offset_unit:.6f} unit")

# 竖屏半径内也应线性
po_in = joystick_delta(pc, (0.5, 0.8 + 0.03 * PORT), 0.10, PORT)
offset_in = (po_in[1] - pc[1]) / PORT
check("竖屏半径内线性", abs(offset_in - 0.03) < 1e-6, f"偏移 {offset_in:.6f} unit")

print("\n== 9. 王者预设坐标合法性 ==")
keys = [
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
for name, x, y, diam in keys:
    inb = 0 <= x <= 1 and 0 <= y <= 1
    # 圆心 ± 半径换算到 x 轴（横屏 x 覆盖 aspect 个短边）
    half_w = (diam / 2) / LAND
    onscreen = (x - half_w) >= -0.01 and (x + half_w) <= 1.01
    check(f"{name} 合法", inb and onscreen, f"x={x} y={y} halfw={half_w:.4f}")

print("\n== 10. 预设按钮不重叠 ==")
overlaps = []
for i in range(len(keys)):
    for j in range(i + 1, len(keys)):
        a, b = keys[i], keys[j]
        pa = to_unit((a[1], a[2]), LAND)
        pb = to_unit((b[1], b[2]), LAND)
        dist = math.hypot(pa[0] - pb[0], pa[1] - pb[1])
        if dist < (a[3] + b[3]) / 2:
            overlaps.append(f"{a[0]}<->{b[0]} d={dist:.3f} need={(a[3]+b[3])/2:.3f}")
for o in overlaps:
    print("    重叠:", o)
check("无重叠", len(overlaps) == 0)

print("\n== 11. 命中优先级：小键不被大圆吃掉 ==")
# 技能1 圆心附近放一个大摇杆，检查命中分数
score_small = hit_score((0.700, 0.795), 0.135, (0.700, 0.795), LAND)
score_big = hit_score((0.700, 0.700), 0.40, (0.700, 0.795), LAND)
check("小键自己在正中的分数为 0", score_small is not None and score_small < 1e-9)
if score_big is not None:
    check("大圆边缘分数更高(更差)，小键胜出", score_small < score_big,
          f"small={score_small} big={score_big}")

print("\n" + "=" * 30)
print(f"通过 {passed} / 失败 {failed}")
sys.exit(0 if failed == 0 else 1)
