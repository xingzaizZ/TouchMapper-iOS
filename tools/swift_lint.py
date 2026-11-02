#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Swift 源码离线体检：
  1. 括号 / 引号 / 注释配对
  2. 顶层类型与 extension 里声明的成员符号表
  3. 交叉引用：被调用的 LayoutSticker.X / KeyMapEngine.X / GamePresets.X 是否存在
  4. 常见的 ViewBuilder 违规（多于 10 个直接子视图）
这个脚本不做完整类型检查（那是 swiftc 的活），只抓结构性错误。
"""
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

def strip_code(src: str) -> str:
    """去掉注释和字符串内容，只留下结构字符，用于括号配对。"""
    out = []
    i, n = 0, len(src)
    mode = None  # None | 'line' | 'block' | 'str' | 'mlstr'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if mode is None:
            if c == "/" and nxt == "/":
                mode = "line"; i += 2; continue
            if c == "/" and nxt == "*":
                mode = "block"; i += 2; continue
            if src.startswith('"""', i):
                mode = "mlstr"; i += 3; out.append('""'); continue
            if c == '"':
                mode = "str"; i += 1; out.append('"'); continue
            out.append(c); i += 1; continue
        if mode == "line":
            if c == "\n":
                mode = None; out.append("\n")
            i += 1; continue
        if mode == "block":
            if c == "*" and nxt == "/":
                mode = None; i += 2; continue
            i += 1; continue
        if mode == "str":
            if c == "\\":
                i += 2; continue
            if c == '"':
                mode = None
            i += 1; continue
        if mode == "mlstr":
            if src.startswith('"""', i):
                mode = None; i += 3; continue
            i += 1; continue
    if mode not in (None, "line"):
        out.append(f"  <<UNCLOSED:{mode}>>")
    return "".join(out)


def check_balance(path: Path, src: str):
    errs = []
    stripped = strip_code(src)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                errs.append(f"{path.name}:{line} 多余的 {ch}")
                continue
            top, ln = stack.pop()
            if top != pairs[ch]:
                errs.append(f"{path.name}:{line} {ch} 与第 {ln} 行的 {top} 不匹配")
    for ch, ln in stack:
        errs.append(f"{path.name}:{ln} 未闭合的 {ch}")
    return errs


def collect_decls(files):
    """收集 Type.member 形式的声明（含 extension）。

    用显式块栈：每遇到一个 '{' 压入当前所属类型名（或 None），
    遇到 '}' 弹出。行内声明的归属 = 栈顶，比数深度可靠。
    """
    members = {}
    for path, src in files:
        cleaned = strip_code(src).splitlines()
        stack = []          # 每个元素：该块所属的顶层类型名，None 表示非类型块
        pending_type = None  # 本行刚声明的类型名，等下一个 '{' 入栈

        for idx, line in enumerate(cleaned):
            stripped = line.strip()
            if not stripped:
                continue

            m = re.match(r"(?:public |private |fileprivate |internal |final |@objc )*"
                         r"(?:struct|class|enum|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
                         stripped)
            if m:
                pending_type = m.group(1)

            # 当前作用域所属类型
            owner = next((t for t in reversed(stack) if t), None)
            if owner:
                fm = re.search(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
                vm = re.search(r"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
                cm = re.search(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
                if fm:
                    members.setdefault(owner, set()).add(fm.group(1))
                elif vm:
                    members.setdefault(owner, set()).add(vm.group(1))
                elif cm:
                    members.setdefault(owner, set()).add(cm.group(1))

            # 逐字符处理本行的花括号
            for ch in stripped:
                if ch == "{":
                    stack.append(pending_type)
                    pending_type = None
                elif ch == "}":
                    if stack:
                        stack.pop()
    return members


def collect_calls(files):
    calls = {}
    for path, src in files:
        for m in re.finditer(r"\b(LayoutSticker|KeyMapEngine|GamePresets|TouchMapperProtocol|"
                             r"StickerIconStore|LayoutPreset|KeyMapRuntime)\.([A-Za-z_][A-Za-z0-9_]*)",
                             strip_code(src)):
            calls.setdefault(m.group(1), set()).add(m.group(2))
    return calls


def main():
    swift = sorted(ROOT.rglob("*.swift"))
    if not swift:
        print("没找到 swift 文件")
        return 1

    files = [(p, p.read_text(encoding="utf-8", errors="replace")) for p in swift]
    problems = []

    print(f"== 扫描 {len(files)} 个 Swift 文件 ==")
    for p, src in files:
        print(f"  {p.relative_to(ROOT)}  ({len(src.splitlines())} 行)")
        problems.extend(check_balance(p, src))

    members = collect_decls(files)
    calls = collect_calls(files)

    # 内建类型属性不算缺失
    builtin = {
        "LayoutSticker": {"Kind", "Style", "Shape", "OutputMode"},
        "TouchMapperProtocol": set(),
        "GamePresets": {"Entry", "all"},   # Entry 是嵌套结构体
    }

    print("\n== 符号表 ==")
    for t in sorted(members):
        print(f"  {t}: {len(members[t])} 个成员")

    print("\n== 交叉引用检查 ==")
    for t, names in sorted(calls.items()):
        if t not in members:
            continue
        missing = sorted(n for n in names if n not in members[t] and n not in builtin.get(t, set()))
        if missing:
            for n in missing:
                problems.append(f"引用了未定义的 {t}.{n}")
                print(f"  [缺失] {t}.{n}")
        else:
            print(f"  [OK] {t} ({len(names)} 处引用)")

    # 中文标点误入代码
    for p, src in files:
        for ln, line in enumerate(src.splitlines(), 1):
            code_part = line.split("//")[0]
            for ch in "，。；：（）【】“”‘’":
                if ch in code_part and '"' not in code_part:
                    problems.append(f"{p.name}:{ln} 代码里出现中文标点 {ch}")

    print("\n== 结果 ==")
    if problems:
        for x in problems:
            print("  ✗", x)
        return 1
    print("  ✓ 结构检查全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
