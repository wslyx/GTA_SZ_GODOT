#!/usr/bin/env python3
"""体检 GTA_SZ_GODOT/data 下的所有 GLB，确认没有 Godot 会拒绝的扩展。

背景：Godot 4 不支持 EXT_meshopt_compression / KHR_mesh_quantization /
KHR_draco_mesh_compression / KHR_texture_transform。只要出现在
extensionsRequired 里，Godot 会**直接拒绝导入**（.import 里 valid=false，
模型静默回退成占位盒）。本脚本用 tools/convert_glb.mjs 转换后跑一遍复核。

用法：python tools/verify_glb.py [data目录]
"""
import glob
import json
import os
import struct
import sys

BLOCKING = {
    "EXT_meshopt_compression",
    "KHR_mesh_quantization",
    "KHR_draco_mesh_compression",
    "KHR_texture_transform",
}

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"
)


def read_json_chunk(path):
    """读出 GLB 的 JSON chunk。GLB 头 12 字节，chunk 头 8 字节。"""
    with open(path, "rb") as f:
        head = f.read(12)
        if head[:4] != b"glTF":
            return None
        clen, _ = struct.unpack("<II", f.read(8))
        return json.loads(f.read(clen).decode("utf-8"))


files = sorted(glob.glob(os.path.join(root, "**", "*.glb"), recursive=True))
blocked = []
read_errors = []
ext_hist = {}

for p in files:
    rel = os.path.relpath(p, root)
    try:
        d = read_json_chunk(p)
    except Exception as e:  # noqa: BLE001
        read_errors.append((rel, str(e)[:80]))
        continue
    if d is None:
        read_errors.append((rel, "not a GLB (magic != glTF)"))
        continue
    req = list(d.get("extensionsRequired") or [])
    used = list(d.get("extensionsUsed") or [])
    key = tuple(sorted(set(req)))
    ext_hist.setdefault(key, 0)
    ext_hist[key] += 1
    bad = [e for e in req if e in BLOCKING]
    if bad:
        blocked.append((rel, ",".join(bad)))
    for e in used:
        if e in BLOCKING:
            blocked.append((rel + " (used only)", e))

print("扫描目录: %s" % root)
print("GLB 文件数: %d\n" % len(files))

print("extensionsRequired 组合分布：")
for k, v in sorted(ext_hist.items(), key=lambda kv: -kv[1]):
    print("  %4d 个文件  required=%s" % (v, list(k)))

print()
if blocked:
    print("!! 仍被 Godot 拒绝的文件（%d）：" % len(blocked))
    for rel, e in blocked:
        print("   %-60s %s" % (rel, e))
else:
    print("OK：没有任何文件把 Godot 不支持的扩展写进 extensionsRequired。")

if read_errors:
    print()
    print("读取失败（%d）：" % len(read_errors))
    for rel, e in read_errors:
        print("   %-60s %s" % (rel, e))

sys.exit(1 if blocked or read_errors else 0)
