"""对比原版截图与 Godot 复刻截图的像素颜色，输出可直接用于调参的报告。

用法：
    python tools/compare_shots.py <原版图> <复刻图> [更多复刻图...]
"""
import sys
import numpy as np
from PIL import Image


def load(path):
    img = Image.open(path).convert("RGB")
    return np.asarray(img).astype(np.float32) / 255.0, img.size


def hexs(c):
    return "#%02x%02x%02x" % tuple(int(round(v * 255)) for v in c)


def band_mean(a, x0, x1, y0, y1):
    return a[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)


def stats(a):
    lum = a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722
    return {
        "mean_lum": float(lum.mean()),
        "over_0.9": float((lum > 0.90).mean()),
        "over_0.95": float((lum > 0.95).mean()),
        "dark_0.1": float((lum < 0.10).mean()),
        "mean_rgb": a.reshape(-1, 3).mean(axis=0),
        "sat": float((a.max(axis=2) - a.min(axis=2)).mean()),
    }


# 天空中央列（避开建筑与文字），按 y band 取均值
SKY_COL = (505, 575)
SKY_BANDS = [(0, 30), (30, 70), (70, 110), (110, 150), (150, 190),
             (190, 230), (230, 270), (270, 305)]

# 区域采样点 (名称, x0, x1, y0, y1)
REGIONS = [
    ("路面-近处中央", 480, 600, 470, 520),
    ("路面-中距左", 300, 380, 430, 450),
    ("路面-远距中央", 500, 580, 430, 445),
    ("左侧人行道", 150, 250, 480, 520),
    ("左侧路缘/绿化", 60, 130, 430, 470),
    ("右侧路缘/绿化", 950, 1040, 430, 470),
    ("左侧树冠", 40, 140, 300, 400),
    ("右侧树冠", 700, 860, 260, 330),
    ("左侧建筑", 300, 360, 60, 160),
    ("右侧建筑", 800, 900, 60, 200),
    ("中央车尾", 450, 630, 440, 520),
    ("左侧远景地平", 0, 120, 355, 375),
]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    ref, rsize = load(sys.argv[1])
    print("=" * 78)
    print("原版：%s  %dx%d" % (sys.argv[1], rsize[0], rsize[1]))
    s = stats(ref)
    print("  平均亮度 %.3f | >0.90 %.1f%% | >0.95 %.1f%% | <0.10 %.1f%% | 平均饱和 %.3f | 均值 %s"
          % (s["mean_lum"], s["over_0.9"] * 100, s["over_0.95"] * 100,
             s["dark_0.1"] * 100, s["sat"], hexs(s["mean_rgb"])))

    others = []
    for p in sys.argv[2:]:
        a, sz = load(p)
        others.append((p, a, sz))
        st = stats(a)
        print("复刻：%s  %dx%d" % (p, sz[0], sz[1]))
        print("  平均亮度 %.3f | >0.90 %.1f%% | >0.95 %.1f%% | <0.10 %.1f%% | 平均饱和 %.3f | 均值 %s"
              % (st["mean_lum"], st["over_0.9"] * 100, st["over_0.95"] * 100,
                 st["dark_0.1"] * 100, st["sat"], hexs(st["mean_rgb"])))

    print("\n" + "=" * 78)
    print("一、天空中央列（x %d-%d）逐段均值" % SKY_COL)
    hdr = "%-12s %-9s" % ("y 区间", "原版")
    for p, _, _ in others:
        hdr += " %-9s" % ("复刻 " + p.split("\\")[-1][:7])
    print(hdr)
    for (y0, y1) in SKY_BANDS:
        line = "%-12s %-9s" % ("%d-%d" % (y0, y1), hexs(band_mean(ref, SKY_COL[0], SKY_COL[1], y0, y1)))
        for _, a, _ in others:
            line += " %-9s" % hexs(band_mean(a, SKY_COL[0], SKY_COL[1], y0, y1))
        print(line)

    print("\n" + "=" * 78)
    print("二、区域均值")
    hdr = "%-18s %-9s" % ("区域", "原版")
    for p, _, _ in others:
        hdr += " %-9s" % "复刻"
    print(hdr)
    for (name, x0, x1, y0, y1) in REGIONS:
        line = "%-18s %-9s" % (name, hexs(band_mean(ref, x0, x1, y0, y1)))
        for _, a, _ in others:
            line += " %-9s" % hexs(band_mean(a, x0, x1, y0, y1))
        print(line)

    print("\n" + "=" * 78)
    print("三、天空球着色器应有的解析值（原版 szSky，p 为单位方向）")
    print("%-10s %-28s %-28s" % ("p.y", "远离太阳(west=0)", "朝向太阳(west=1)"))
    for py in [0.90, 0.70, 0.50, 0.30, 0.15, 0.05, 0.0, -0.05]:
        h = smoothstep(-0.05, 0.72, py)
        away = mixc((0.42, 0.24, 0.35), (0.047, 0.12, 0.25), h)
        tosun = mixc((0.94, 0.32, 0.115), (0.047, 0.12, 0.25), h)
        print("%-10.2f %-28s %-28s" % (py, hexs(away), hexs(tosun)))
    return 0


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def mixc(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


if __name__ == "__main__":
    sys.exit(main())
