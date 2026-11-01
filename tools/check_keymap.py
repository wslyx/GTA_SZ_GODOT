#!/usr/bin/env python3
"""按键表一致性检查：帮助面板承诺的键 vs 代码真正处理的键。

为什么需要它：帮助页（`panels_ui.gd` 的 `HELP_SECTIONS`）是纯手写的字符串表，
没有任何东西保证它与 `main_game.gd` 里的 `match code:` 分支同步。实测就抓到过
「帮助里写着 K 显隐鼠标 / V 看车，代码里根本没有这两个键」这种悬空条目 ——
玩家按下去毫无反应，比没有帮助更糟。

用法：python tools/check_keymap.py [项目根目录]
退出码：0 = 一致；1 = 有悬空或漏写。
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

MAIN = os.path.join(ROOT, "scripts", "core", "main_game.gd")
PANELS = os.path.join(ROOT, "scripts", "ui", "panels_ui.gd")

# 中文/缩写 → Godot 键名（KEY_ 之后的部分）
ALIASES = {
    "空格": ["SPACE"],
    "回车": ["ENTER"],
    "SHIFT": ["SHIFT"],
    "ESC": ["ESCAPE"],
    "?": ["SLASH"],
    "PGUP": ["PAGEUP"],
    "PGDN": ["PAGEDOWN"],
    "方向键": ["UP", "DOWN", "LEFT", "RIGHT"],
}
# 只与鼠标/触控板有关、不对应 Key 的行
MOUSE_TOKENS = {"移动鼠标", "长按左键", "鼠标"}


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(text):
    """去掉行注释与字符串，避免把注释里提到的键（例如"不是 KEY_ONE"）算成已实现"""
    out = []
    for line in text.splitlines():
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        i = line.find("#")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


def handled_keys(text):
    """main_game 里出现过的所有 KEY_*（含 match 分支与 is_key_pressed 轮询）"""
    return {m.group(1) for m in re.finditer(r"\bKEY_([A-Z0-9_]+)\b", strip_comments(text))}


def documented_keys(text):
    """HELP_SECTIONS 里每行第一个元素（键标签）解析出来的键集合"""
    start = text.find("const HELP_SECTIONS")
    if start < 0:
        return set(), []
    end = text.find("]\n", text.find("}", text.rfind("]", start, text.find("var help_root"))))
    block = text[start:text.find("var help_root", start)]

    documented = set()
    rows = []
    for m in re.finditer(r'\[\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\]', block):
        label, desc = m.group(1), m.group(2)
        rows.append((label, desc))
        if label in MOUSE_TOKENS:
            continue
        if label in ALIASES:
            documented.update(ALIASES[label])
            continue
        # "W / S"、"W A S D"、"1 / 2 / 3"、"Q / E"
        for tok in re.split(r"[/\s]+", label):
            tok = tok.strip().upper()
            if not tok:
                continue
            if tok in ALIASES:
                documented.update(ALIASES[tok])
            elif re.fullmatch(r"[A-Z0-9]+", tok):
                documented.add(tok)
    return documented, rows


def main():
    main_text = read(MAIN)
    panel_text = read(PANELS)
    handled = handled_keys(main_text)
    documented, rows = documented_keys(panel_text)

    problems = []

    dangling = sorted(documented - handled)
    for k in dangling:
        problems.append("帮助里写了、代码没处理：%s" % k)

    # 只报"看起来该写进帮助"的漏写：字母/数字/功能键，排除纯移动键与开发键
    MOVEMENT = {"W", "A", "S", "D", "Q", "E", "X", "UP", "DOWN", "LEFT", "RIGHT",
                "SHIFT", "SPACE", "ENTER", "C", "F", "G", "T", "B"}
    DEV = {"F9"}
    missing = sorted(handled - documented - MOVEMENT - DEV)
    for k in missing:
        problems.append("代码处理了、帮助没写：%s" % k)

    print("按键表检查：帮助 %d 个键标签（%d 行），代码处理 %d 个键"
          % (len(documented), len(rows), len(handled)))
    if problems:
        print("发现 %d 项：" % len(problems))
        for p in problems:
            print("  " + p)
    else:
        print("一致：帮助与实现没有悬空条目。")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
