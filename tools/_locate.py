"""在小地图路网里反查"截图是在哪拍的"。
思路：把参照小地图的亮线做成距离场，再对每个候选（位置+朝向）按原版小地图的
投影（含透视压扁）重画局部路网，取「重画像素到参照亮线的平均距离」做 Chamfer 匹配。
"""
import json, math, sys
import numpy as np
from PIL import Image, ImageDraw

CITY = r"D:/CodePro/game_ws/GTA_SZ_GODOT/data/city/city.json"
REF = r"C:/Users/YIYAY/.workbuddy/clipboard-images/clipboard-2026-09-24T01-44-14-501Z-0d7b4f25.jpg"

def build_ref():
    ref = Image.open(REF).convert("RGB")
    mm = ref.crop((25, 829, 271, 1075)).resize((320, 320), Image.LANCZOS)
    a = np.asarray(mm).astype(np.float32) / 255.0
    lum = a[...,0]*.2126 + a[...,1]*.7152 + a[...,2]*.0722
    cy, cx = np.mgrid[0:320, 0:320]
    inside = ((cx-160.0)**2 + (cy-160.0)**2) < 150**2
    mask = (lum > 0.45) & inside
    mask &= ~(((cx-160.0)**2 + (cy-208.0)**2) < 24**2)   # 去掉玩家箭头
    dt = np.where(mask, 0.0, 1e6)
    for y in range(320):
        for x in range(320):
            v = dt[y,x]
            if y: v = min(v, dt[y-1,x]+1)
            if x: v = min(v, dt[y,x-1]+1)
            if y and x: v = min(v, dt[y-1,x-1]+1.414)
            dt[y,x] = v
    for y in range(319,-1,-1):
        for x in range(319,-1,-1):
            v = dt[y,x]
            if y<319: v = min(v, dt[y+1,x]+1)
            if x<319: v = min(v, dt[y,x+1]+1)
            if y<319 and x<319: v = min(v, dt[y+1,x+1]+1.414)
            dt[y,x] = v
    return mask, dt, inside

def main():
    mask, dt, inside = build_ref()
    d = json.load(open(CITY, encoding='utf-8'))
    CELL = 150.0
    segs = []; grid = {}
    for road in d["roads"]:
        if road["kind"] not in ("trunk","primary","motorway","secondary"): continue
        pts = road["points"]; mj = road["kind"] != "secondary"
        for k in range(len(pts)-1):
            ax,az = pts[k]; bx,bz = pts[k+1]
            i = len(segs); segs.append((ax,az,bx,bz,mj))
            for gx in range(int(min(ax,bx)//CELL), int(max(ax,bx)//CELL)+1):
                for gz in range(int(min(az,bz)//CELL), int(max(az,bz)//CELL)+1):
                    grid.setdefault((gx,gz), []).append(i)
    print("主干道段 %d 条" % len(segs), flush=True)
    TILT = 0.40; C = math.cos(TILT); S = math.sin(TILT)
    def render(px, pz, yaw, k):
        ca, sa = math.cos(-yaw), math.sin(-yaw)
        im = Image.new("L",(320,320),0); dr = ImageDraw.Draw(im)
        R = 900.0/k + 60
        for gx in range(int((px-R)//CELL), int((px+R)//CELL)+1):
            for gz in range(int((pz-R)//CELL), int((pz+R)//CELL)+1):
                for i in grid.get((gx,gz), ()):
                    ax,az,bx,bz,mj = segs[i]
                    out = []
                    for (x,z) in ((ax,az),(bx,bz)):
                        mx, my = (x-px)*k, -(z-pz)*k
                        lx = mx*ca - my*sa; ly = mx*sa + my*ca
                        pxx = 512.0+lx; pyy = 740.0+ly
                        q = pyy-740.0
                        den = 1.0 - q*S/480.0
                        if abs(den) < 1e-4: out = None; break
                        out.append((160.0 + (pxx-512.0)/den, q*C/den + 208.0))
                    if out: dr.line(out, fill=255, width=4 if mj else 2)
        return (np.asarray(im) > 0) & inside
    best = []
    for road in d["roads"]:
        if road["kind"] not in ("trunk","primary","motorway"): continue
        pts = road["points"]; acc = 0.0
        for k in range(len(pts)-1):
            ax,az = pts[k]; bx,bz = pts[k+1]
            L = math.hypot(bx-ax, bz-az); yaw = math.atan2(bx-ax, bz-az)
            n = max(1, int(L/60))
            for t in range(n):
                f = t/n; x = ax+(bx-ax)*f; z = az+(bz-az)*f
                for kk in (0.30, 0.38, 0.50):
                    m = render(x, z, yaw, kk)
                    if m.sum() < 60: continue
                    sc = float(dt[m].mean())
                    best.append((sc, x, z, yaw, kk, acc+L*f))
            acc += L
    best.sort()
    print("最佳匹配（得分 = 重画路网像素到参照亮线的平均距离，越小越好）：")
    for sc,x,z,yw,kk,al in best[:10]:
        print("  %6.2f px  坐标(%9.1f,%9.1f)  yaw %7.2f°  scale %.2f  里程 %5.0f" %
              (sc,x,z,math.degrees(yw),kk,al))
    sp = d["spawn"]
    print("\n当前出生点 (%9.1f,%9.1f) yaw %.2f°" % (sp["x"], sp["z"], math.degrees(sp["yaw"])))
    sc0 = min(float(dt[render(sp["x"],sp["z"],sp["yaw"],0.38)].mean()) if render(sp["x"],sp["z"],sp["yaw"],0.38).sum()>60 else 1e9 for _ in (0,))
    print("出生点自身得分 %.2f px" % sc0)
    w = best[0]
    print("最佳匹配与出生点相距 %.0f 数据单位 = %.0f 真实米" %
          (math.hypot(w[1]-sp["x"], w[2]-sp["z"]), math.hypot(w[1]-sp["x"], w[2]-sp["z"])/0.6))

main()
