#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""roads.glb 按材质合批（性能优化方案 §2.10 道路部分）。

背景（tools/_perf.gd tree 模式实测）
--------------------------------
roads.glb 实例化为 765 个 MeshInstance3D，只有 5 种材质
（asphalt / pavement / roadline / steel / lamp），765 个 draw call 占全场
1665 个 surface 的 46%，是全场景最大 draw call 来源；且流式模式下道路
整根常驻、无按格剔除 —— 按材质合并成 5 个网格零剔除损失，纯赚。

做法
----
复用 split_city_blocks.py 的 GLB 工具链（numpy 向量化，秒级完成）：
把每个 primitive 的 POSITION/NORMAL/TEXCOORD_0/COLOR_0/indices 读出，
应用节点世界矩阵后按材质拼接，产出 data/city/roads_merged.glb
（5 个 mesh × 1 primitive，节点名 roads_merged_<材质>，几何已烘焙世界坐标）。

节点名仍满足 ground_field 的 GROUND_MESH_RE "roads_" 前缀；不再匹配
roads_i_j 分块正则 → 回退剔除路径里道路整组可见（与流式模式现状一致）。

运行时配套：city_world._plan_roads 优先加载 roads_merged.glb，文件不存在
自动回退 roads.glb（烘焙产物可删，不锁死）。

运行（在 GTA_SZ_GODOT 目录下，需 pygltflib + numpy）：
    python tools/merge_roads.py
"""
from __future__ import annotations

import argparse
import copy
import os
import sys

import numpy as np
from pygltflib import (GLTF2, Accessor, Attributes, Buffer, BufferView, Image,
                       Material, Mesh, Node, Primitive, Scene, Texture)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from split_city_blocks import (  # noqa: E402
    _gltf_buffer_bytes, _gltf_to_bytes, _prim_accessor_items, _read_glb_bin,
    _world_matrices, _COMP_SIZE, _TYPE_NCOMP,
)

SRC = os.path.join("data", "city", "roads.glb")
DST = os.path.join("data", "city", "roads_merged.glb")


def _read_accessor(g: GLTF2, bin_bytes: bytes, ai: int) -> np.ndarray:
    """按 accessor 读出 (count, ncomp) float/int 数组（处理交织）。"""
    a = g.accessors[ai]
    bv = g.bufferViews[a.bufferView]
    comp = _COMP_SIZE.get(a.componentType, 4)
    ncomp = _TYPE_NCOMP.get(a.type, 1)
    elem = comp * ncomp
    base = bv.byteOffset + (a.byteOffset or 0)
    stride = getattr(a, "byteStride", None) or bv.byteStride
    dtype = {5120: np.int8, 5121: np.uint8, 5122: np.int16,
             5123: np.uint16, 5125: np.uint32, 5126: np.float32}[a.componentType]
    if stride and stride > elem:
        span = (a.count - 1) * stride + elem
        arr = np.frombuffer(bin_bytes, dtype=np.uint8, count=span, offset=base)
        idx = (np.arange(a.count, dtype=np.int64)[:, None] * stride
               + np.arange(elem, dtype=np.int64)[None, :]).ravel()
        raw = arr[idx]
    else:
        raw = np.frombuffer(bin_bytes, dtype=np.uint8,
                            count=a.count * elem, offset=base)
    return raw.view(dtype).reshape(a.count, ncomp).astype(np.float64 if
        a.componentType == 5126 else np.int64)


def merge(g: GLTF2, bin_bytes: bytes):
    worlds = _world_matrices(g)

    # 1) 找出场景里带 mesh 的节点（全部是 roads_*）
    roots = list(g.scenes[g.scene if g.scene is not None else 0].nodes)
    mesh_nodes = []
    stack = list(roots)
    seen = set()
    while stack:
        ni = stack.pop()
        if ni in seen:
            continue
        seen.add(ni)
        n = g.nodes[ni]
        if n.mesh is not None:
            mesh_nodes.append(ni)
        stack.extend(n.children or [])

    # 2) 按材质累加几何（numpy 向量化）
    groups: dict[int, dict] = {}
    tri_total = 0
    for ni in mesh_nodes:
        M = worlds[ni]
        R = M[:3, :3]
        Rt_inv = np.linalg.inv(R).T          # 法线矩阵（假设无剪切）
        mesh = g.meshes[g.nodes[ni].mesh]
        for prim in mesh.primitives:
            if prim.mode is not None and prim.mode != 4:
                print(f"[merge-roads] ⚠ 跳过非 TRIANGLES primitive（mode={prim.mode}）")
                continue
            mat = prim.material if prim.material is not None else -1
            gp = groups.setdefault(mat, {
                "pos": [], "nrm": [], "uv": [], "col": [], "idx": [],
                "all_uv": True, "all_col": True, "all_nrm": True})
            pos = _read_accessor(g, bin_bytes, prim.attributes.POSITION)
            idx = _read_accessor(g, bin_bytes, prim.indices).ravel().astype(np.int64)
            base = sum(p.shape[0] for p in gp["pos"])
            gp["pos"].append(pos @ R.T + M[:3, 3])
            if prim.attributes.NORMAL is not None:
                nrm = _read_accessor(g, bin_bytes, prim.attributes.NORMAL)
                gp["nrm"].append(nrm @ Rt_inv.T)
                lens = np.linalg.norm(gp["nrm"][-1], axis=1, keepdims=True)
                lens[lens == 0] = 1.0
                gp["nrm"][-1] = gp["nrm"][-1] / lens
            else:
                gp["all_nrm"] = False
            uv_sem = prim.attributes.TEXCOORD_0
            if uv_sem is not None:
                gp["uv"].append(_read_accessor(g, bin_bytes, uv_sem))
            else:
                gp["all_uv"] = False
            col_sem = prim.attributes.COLOR_0
            if col_sem is not None:
                c = _read_accessor(g, bin_bytes, col_sem)
                if c.shape[1] == 3:   # RGB → RGBA
                    c = np.hstack([c, np.ones((c.shape[0], 1))])
                gp["col"].append(c)
            else:
                gp["all_col"] = False
            gp["idx"].append(idx + base)
            tri_total += idx.size // 3

    # 3) 组装新 glTF
    new_bin = bytearray()

    def _align():
        while len(new_bin) % 4 != 0:
            new_bin.append(0)

    def _push(data: bytes) -> tuple[int, int]:
        off = len(new_bin)
        new_bin.extend(data)
        _align()
        return off, len(data)

    new_accs: list[Accessor] = []
    new_bvs: list[BufferView] = []

    def _add_accessor(arr: np.ndarray, comp_type: int, vtype: str,
                      target: int = 34962) -> int:
        data = arr.astype({5120: np.int8, 5121: np.uint8, 5122: np.int16,
                           5123: np.uint16, 5125: np.uint32,
                           5126: np.float32}[comp_type]).tobytes()
        off, ln = _push(data)
        bv = BufferView()
        bv.buffer = 0
        bv.byteOffset = off
        bv.byteLength = ln
        bv.target = target
        new_bvs.append(bv)
        a = Accessor()
        a.bufferView = len(new_bvs) - 1
        a.componentType = comp_type
        a.count = len(arr)
        a.type = vtype
        if vtype == "VEC3" and comp_type == 5126:
            a.min = arr.min(axis=0).tolist()
            a.max = arr.max(axis=0).tolist()
        new_accs.append(a)
        return len(new_accs) - 1

    # 材质与贴图（每个材质组对应源材质，纹理引用重映射）
    mat_keys = sorted(groups.keys())
    new_mats: list[Material] = []
    new_texs: list[Texture] = []
    new_imgs: list[Image] = []
    mat_old_new: dict[int, int] = {}
    tex_old_new: dict[int, int] = {}
    img_seen: dict[int, int] = {}

    def _copy_image(old_img: int) -> int:
        if old_img in img_seen:
            return img_seen[old_img]
        im = g.images[old_img]
        nimg = Image()
        nimg.name = im.name
        nimg.mimeType = im.mimeType
        if im.bufferView is not None:
            bv = g.bufferViews[im.bufferView]
            data = bin_bytes[bv.byteOffset: bv.byteOffset + bv.byteLength]
            off, ln = _push(data)
            nbv = BufferView()
            nbv.buffer = 0
            nbv.byteOffset = off
            nbv.byteLength = ln
            new_bvs.append(nbv)
            nimg.bufferView = len(new_bvs) - 1
        else:
            nimg.uri = im.uri
        new_imgs.append(nimg)
        img_seen[old_img] = len(new_imgs) - 1
        return img_seen[old_img]

    def _remap_texref(ref):
        if ref is None:
            return None
        old_ti = ref.index
        if old_ti not in tex_old_new:
            t = g.textures[old_ti]
            nt = Texture()
            nt.name = t.name
            nt.sampler = t.sampler
            nt.source = _copy_image(t.source) if t.source is not None else None
            new_texs.append(nt)
            tex_old_new[old_ti] = len(new_texs) - 1
        ti = copy.copy(ref)
        ti.index = tex_old_new[old_ti]
        return ti

    new_meshes: list[Mesh] = []
    new_nodes: list[Node] = []
    report = []
    for mk in mat_keys:
        gp = groups[mk]
        pos = np.vstack(gp["pos"])
        mat_name = g.materials[mk].name if mk >= 0 and g.materials[mk].name else f"mat{mk}"
        prim = Primitive()
        prim.mode = 4
        nattr = Attributes()
        nattr.POSITION = _add_accessor(pos, 5126, "VEC3")
        if gp["all_nrm"] and gp["nrm"]:
            nattr.NORMAL = _add_accessor(np.vstack(gp["nrm"]), 5126, "VEC3")
        if gp["all_uv"] and gp["uv"]:
            nattr.TEXCOORD_0 = _add_accessor(np.vstack(gp["uv"]), 5126, "VEC2")
        if gp["all_col"] and gp["col"]:
            nattr.COLOR_0 = _add_accessor(np.vstack(gp["col"]), 5126, "VEC4")
        prim.attributes = nattr
        prim.indices = _add_accessor(
            np.concatenate(gp["idx"]), 5125, "SCALAR", target=34963)
        if mk >= 0:
            nm = copy.copy(g.materials[mk])
            pr = getattr(g.materials[mk], "pbrMetallicRoughness", None)
            if pr is not None:
                npr = copy.copy(pr)
                if pr.baseColorTexture is not None:
                    npr.baseColorTexture = _remap_texref(pr.baseColorTexture)
                if pr.metallicRoughnessTexture is not None:
                    npr.metallicRoughnessTexture = _remap_texref(
                        pr.metallicRoughnessTexture)
                nm.pbrMetallicRoughness = npr
            if g.materials[mk].normalTexture is not None:
                nm.normalTexture = _remap_texref(g.materials[mk].normalTexture)
            if g.materials[mk].occlusionTexture is not None:
                nm.occlusionTexture = _remap_texref(g.materials[mk].occlusionTexture)
            if g.materials[mk].emissiveTexture is not None:
                nm.emissiveTexture = _remap_texref(g.materials[mk].emissiveTexture)
            new_mats.append(nm)
            prim.material = len(new_mats) - 1
            mat_old_new[mk] = prim.material
        else:
            prim.material = None
        m = Mesh()
        m.name = f"roads_merged_{mat_name}"
        m.primitives.append(prim)
        new_meshes.append(m)
        node = Node()
        node.name = m.name
        node.mesh = len(new_meshes) - 1
        new_nodes.append(node)
        report.append(f"{node.name}: {pos.shape[0]} 顶点 / "
                      f"{sum(len(i) for i in gp['idx']) // 3} 三角")

    # 4) 收尾：场景 / buffer / 保存（pygltflib save_binary 自动打 GLB 容器）
    scene = Scene()
    scene.nodes = list(range(len(new_nodes)))
    out = GLTF2()
    out.scene = 0
    out.scenes = [scene]
    out.nodes = new_nodes
    out.meshes = new_meshes
    out.materials = new_mats
    out.textures = new_texs
    out.images = new_imgs
    out.samplers = g.samplers if g.samplers else []
    out.accessors = new_accs
    out.bufferViews = new_bvs
    out.buffers = [Buffer()]
    out.buffers[0].byteLength = len(new_bin)
    # pygltflib 的 save_binary 从 binary_blob 取 buffer 数据（buffer.uri 留空）
    out.set_binary_blob(bytes(new_bin))
    data = _gltf_to_bytes(out)
    with open(DST, "wb") as f:
        f.write(data)
    print(f"[merge-roads] 完成：{len(mesh_nodes)} 节点 / {tri_total // 1000}k 三角 → "
          f"{len(new_meshes)} 合并网格，输出 {DST}（{len(data) // 1024 // 1024}MB）")
    for r in report:
        print(f"[merge-roads]   {r}")


def main() -> None:
    global DST
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--dst", default=DST)
    args = ap.parse_args()
    DST = args.dst
    g = GLTF2().load(args.src)
    try:
        bin_bytes = _gltf_buffer_bytes(g)
    except RuntimeError:
        bin_bytes = _read_glb_bin(args.src)
    merge(g, bin_bytes)


if __name__ == "__main__":
    main()
