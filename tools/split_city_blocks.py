#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 monolithic buildings.glb 按 640m 区块切成独立 GLB，供 chunk_streamer.gd 流式加载。

设计
----
原版 GTA_SZ 把整座深圳（buildings.glb ≈ 266MB）一次性塞进场景；city_world._cull_chunks
只会切 node.visible —— 几何始终驻留显存。本工具按 buildings.glb 内的 `block_i_j` 命名
把楼体按区块拆成 data/city/blocks/<i>_<j>.glb，并产出 blocks-manifest.json。

  * 每个区块 GLB 只包含该区块的楼体 mesh（几何体已是世界坐标，加载即落位，无需偏移）。
  * 被地标替换掉的楼体 mesh（landmark-detail / landmark-candidates 的 replacedMeshPrefixes）
    会被排除，避免与地标重叠。
  * 索引/缓冲/BIN 全部重打包，未引用资源（被替换楼体的 accessor/bufferView）一并丢弃，
    新文件显著小于 monolithic。

运行（在 GTA_SZ_GODOT 目录下，需 pygltflib）：
    python tools/split_city_blocks.py
    python tools/split_city_blocks.py --src data/city/buildings.glb \
        --out data/city/blocks --manifest data/city/blocks-manifest.json

自测（不依赖真实资产，生成合成 GLB 验证切分算法）：
    python tools/split_city_blocks.py --selftest
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile

import numpy as np
from pygltflib import (GLTF2, Accessor, Attributes, Buffer, BufferView, Image,
                       Material, Mesh, Node, Primitive, Scene, Texture)

CHUNK_SIZE = 640.0
BLOCK_RE = re.compile(r"^block_(-?\d+)_(-?\d+)")
# 区块 mesh 名可能形如 block_i_j / block_i_j_0（被 Blender 追加序号），统一按前缀归类。

# glTF mesh.primitive.attributes 是 Attributes 对象（非 dict），用固定语义名遍历。
_ATTRIB_SEMANTICS = ("POSITION", "NORMAL", "TANGENT", "TEXCOORD_0", "TEXCOORD_1",
                     "TEXCOORD_2", "COLOR_0", "JOINTS_0", "WEIGHTS_0")

# accessor.componentType → 单分量字节数
_COMP_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
# accessor.type → 分量数
_TYPE_NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4,
               "MAT2": 4, "MAT3": 9, "MAT4": 16}


def _prim_accessor_items(prim: Primitive) -> list:
    """返回 [(语义, accessor索引)]，兼容 Attributes 对象与 dict 两种形态。"""
    attrs = prim.attributes
    if attrs is None:
        return []
    if isinstance(attrs, dict):
        return list(attrs.items())
    out = []
    for sem in _ATTRIB_SEMANTICS:
        ai = getattr(attrs, sem, None)
        if ai is not None:
            out.append((sem, ai))
    return out


# ---------------------------------------------------------------------------
# glTF 辅助
# ---------------------------------------------------------------------------

def _gltf_buffer_bytes(g: GLTF2) -> bytes:
    """取 GLB 二进制块（buildings.glb 是 GLB）。"""
    if getattr(g, "binary", None):
        return g.binary
    # 兜底：data: URI（合成自测用）
    buf = g.buffers[0]
    if buf.uri and buf.uri.startswith("data:"):
        import base64
        return base64.b64decode(buf.uri.split(",", 1)[1])
    raise RuntimeError("无法取得 GLB 二进制缓冲")


def _glb_bin_from_data(data: bytes) -> bytes:
    """从 GLB 字节流里取第一个 BIN 块。"""
    if data[:4] != b"glTF":
        raise RuntimeError("不是 GLB 字节流")
    off = 12  # 12 字节头
    total = len(data)
    while off + 8 <= total:
        clen = int.from_bytes(data[off:off + 4], "little")
        ctype = data[off + 4:off + 8]
        cstart = off + 8
        if ctype == b"BIN\x00":
            return data[cstart:cstart + clen]
        off = cstart + clen
        if clen % 4 != 0:  # 块按 4 字节对齐
            off += 4 - (clen % 4)
    raise RuntimeError("GLB 中找不到 BIN 块")


def _read_glb_bin(path: str) -> bytes:
    """pygltflib 某些版本加载 .glb 后既无 g.binary 也把 buffer.uri 置 None，
    导致 BIN 块没进内存。这里按 GLB 规范直接从文件读第一个 BIN 块。"""
    with open(path, "rb") as f:
        return _glb_bin_from_data(f.read())


def _gltf_to_bytes(g: GLTF2) -> bytes:
    """pygltflib 的 save_binary 只接受路径，这里落临时文件再读回字节。"""
    import os
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".glb")
    os.close(fd)
    try:
        g.save_binary(path)
        with open(path, "rb") as f:
            return f.read()
    finally:
        os.remove(path)


def _gltf_from_bytes(data: bytes) -> GLTF2:
    import os
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".glb")
    os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(data)
        return GLTF2().load(path)
    finally:
        os.remove(path)


def _node_local_matrix(node: Node) -> np.ndarray:
    if node.matrix:
        # glTF matrix 列主序 16 元素 -> 行主序 4x4
        return np.array(node.matrix, dtype=float).reshape(4, 4, order="F")
    t = np.eye(4)
    if node.translation:
        t[:3, 3] = node.translation
    r = np.eye(4)
    if node.rotation:
        x, y, z, w = node.rotation
        r = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0],
            [0, 0, 0, 1],
        ], dtype=float)
    s = np.eye(4)
    if node.scale:
        s[0, 0], s[1, 1], s[2, 2] = node.scale
    return t @ r @ s


def _world_matrices(g: GLTF2) -> list[np.ndarray]:
    """计算所有节点的世界矩阵（按 scenes 根遍历）。"""
    n = len(g.nodes)
    worlds = [np.eye(4) for _ in range(n)]
    roots = []
    if g.scenes:
        roots = list(g.scenes[g.scene if g.scene is not None else 0].nodes)
    else:
        roots = list(range(n))
    visited = [False] * n

    def walk(idx: int, parent: np.ndarray):
        if visited[idx]:
            return
        visited[idx] = True
        worlds[idx] = parent @ _node_local_matrix(g.nodes[idx])
        for c in (g.nodes[idx].children or []):
            walk(c, worlds[idx])

    for r in roots:
        walk(r, np.eye(4))
    return worlds


# ---------------------------------------------------------------------------
# 切分核心
# ---------------------------------------------------------------------------

def _collect_references(g: GLTF2, node_indices: set[int], bin_bytes: bytes):
    """给定一批根节点，收集它们子树引用到的 accessor / material / texture / image，
    并返回重打包后的 (新glTF字段, 新BIN)。

    关键：buildings.glb 把全城楼体放在**极少数共享、且交织(interleaved)的大 bufferView**
    里（一个 bufferView 最多被 762 个 accessor 引用）。若按整块 bufferView 复制，
    会在每个区块里重复包含全城几何 → 体积膨胀 ~10 倍。因此这里**按 accessor 精确切片**
    （按 byteStride 去交织），只拷贝该楼真正用到的字节，从根本上消除膨胀。
    """
    import copy
    worlds = _world_matrices(g)
    # 1) 收集子树所有节点
    sub_nodes: set[int] = set()
    stack = list(node_indices)
    while stack:
        cur = stack.pop()
        if cur in sub_nodes:
            continue
        sub_nodes.add(cur)
        stack.extend(g.nodes[cur].children or [])

    mesh_accs = set()   # 顶点属性 / 索引 accessor（按精确字节切、去交织）
    sparse_bvs = set()  # sparse 引用的 bufferView（精确范围切）
    mats = set()
    texs = set()
    imgs = set()

    for ni in sub_nodes:
        node = g.nodes[ni]
        if node.mesh is not None:
            for prim in g.meshes[node.mesh].primitives:
                if prim.material is not None:
                    mats.add(prim.material)
                for _sem, ai in _prim_accessor_items(prim):
                    mesh_accs.add(ai)
                if prim.indices is not None:
                    mesh_accs.add(prim.indices)

    # sparse 引用的 bufferView
    for ai in list(mesh_accs):
        a = g.accessors[ai]
        if a.sparse:
            if a.sparse.indices and a.sparse.indices.bufferView is not None:
                sparse_bvs.add(a.sparse.indices.bufferView)
            if a.sparse.values and a.sparse.values.bufferView is not None:
                sparse_bvs.add(a.sparse.values.bufferView)

    # 材质 → 纹理 → 图像
    for mi in mats:
        m = g.materials[mi]
        txr = getattr(m, "pbrMetallicRoughness", None)
        slots = [
            txr.baseColorTexture if txr is not None else None,
            txr.metallicRoughnessTexture if txr is not None else None,
            m.normalTexture, m.occlusionTexture, m.emissiveTexture,
        ]
        for ref in slots:
            if ref is not None and getattr(ref, "index", None) is not None:
                texs.add(ref.index)
    for ti in texs:
        t = g.textures[ti]
        if t.source is not None:
            imgs.add(t.source)
    img_bvs = set()
    for ii in imgs:
        im = g.images[ii]
        if im.bufferView is not None:
            img_bvs.add(im.bufferView)

    # ---- 2) 重打包二进制 ----
    new_bin = bytearray()

    def _align():
        while len(new_bin) % 4 != 0:
            new_bin.append(0)

    # 2a) 顶点属性 / 索引：按 accessor 精确切片（去交织）
    acc_old_new: dict[int, int] = {}
    new_accs: list[Accessor] = []
    new_bvs: list[BufferView] = []
    for old in sorted(mesh_accs):
        a = g.accessors[old]
        bv = g.bufferViews[a.bufferView]
        comp = _COMP_SIZE.get(a.componentType, 4)
        ncomp = _TYPE_NCOMP.get(a.type, 1)
        elem = comp * ncomp
        base = bv.byteOffset + (a.byteOffset or 0)
        # glTF 2.0 里 byteStride 只在 bufferView 上（accessor 级是历史草案字段，这里兼容读取）
        stride = getattr(a, "byteStride", None) or bv.byteStride
        if stride and stride > elem:
            # 交织：元素的真实跨度是 (count-1)*stride + elem（不是 count*stride，
            # 否则最后一个元素会越界读到缓冲外）。用 numpy 索引一次性取出各行 elem 字节。
            span = (a.count - 1) * stride + elem
            arr = np.frombuffer(bin_bytes, dtype=np.uint8, count=span, offset=base)
            if a.count > 1:
                idx = (np.arange(a.count, dtype=np.int64)[:, None] * stride
                       + np.arange(elem, dtype=np.int64)[None, :]).ravel()
            else:
                idx = np.arange(elem, dtype=np.int64)
            data = arr[idx].tobytes()
        else:
            data = bin_bytes[base: base + a.count * elem]
        new_off = len(new_bin)
        new_bin.extend(data)
        _align()
        nbv = BufferView()
        nbv.buffer = 0
        nbv.byteOffset = new_off
        nbv.byteLength = len(data)
        nbv.target = bv.target
        new_bvs.append(nbv)
        na = Accessor()
        for f in ("componentType", "count", "type", "normalized", "min", "max", "name"):
            setattr(na, f, getattr(a, f))
        na.bufferView = len(new_bvs) - 1
        na.byteOffset = 0
        if a.sparse:
            na.sparse = copy.deepcopy(a.sparse)
        acc_old_new[old] = len(new_accs)
        new_accs.append(na)

    # 2b) sparse 的 bufferView：精确范围切
    sparse_bv_old_new: dict[int, int] = {}
    for old in sorted(sparse_bvs):
        bv = g.bufferViews[old]
        data = bin_bytes[bv.byteOffset: bv.byteOffset + bv.byteLength]
        new_off = len(new_bin)
        new_bin.extend(data)
        _align()
        nbv = BufferView()
        nbv.buffer = 0
        nbv.byteOffset = new_off
        nbv.byteLength = len(data)
        nbv.target = bv.target
        sparse_bv_old_new[old] = len(new_bvs)
        new_bvs.append(nbv)

    # 2c) 图像 bufferView：精确范围切
    img_bv_old_new: dict[int, int] = {}
    for old in sorted(img_bvs):
        bv = g.bufferViews[old]
        data = bin_bytes[bv.byteOffset: bv.byteOffset + bv.byteLength]
        new_off = len(new_bin)
        new_bin.extend(data)
        _align()
        nbv = BufferView()
        nbv.buffer = 0
        nbv.byteOffset = new_off
        nbv.byteLength = len(data)
        nbv.target = bv.target
        img_bv_old_new[old] = len(new_bvs)
        new_bvs.append(nbv)

    # 重映射 sparse 的 bufferView
    for na in new_accs:
        if na.sparse:
            if na.sparse.indices:
                na.sparse.indices.bufferView = sparse_bv_old_new.get(na.sparse.indices.bufferView)
            if na.sparse.values:
                na.sparse.values.bufferView = sparse_bv_old_new.get(na.sparse.values.bufferView)

    # ---- 3) 图像 / 纹理 / 材质（同块内去重；修正纹理索引）----
    # 顺序很重要：材质引用纹理、纹理引用图像，故先建图像、再纹理、最后材质。
    img_old_new: dict[int, int] = {}
    new_imgs: list[Image] = []
    for old in sorted(imgs):
        im = g.images[old]
        nimg = Image()
        nimg.name = im.name
        nimg.mimeType = im.mimeType
        if im.bufferView is not None:
            nimg.bufferView = img_bv_old_new.get(im.bufferView)
        elif im.uri:
            nimg.uri = im.uri
        new_imgs.append(nimg)
        img_old_new[old] = len(new_imgs) - 1

    tex_old_new: dict[int, int] = {}
    new_texs: list[Texture] = []
    for old in sorted(texs):
        t = g.textures[old]
        nt = Texture()
        nt.name = t.name
        nt.sampler = t.sampler
        nt.source = img_old_new.get(t.source) if t.source is not None else None
        new_texs.append(nt)
        tex_old_new[old] = len(new_texs) - 1

    def _remap_texref(ref):
        if ref is None:
            return None
        ti = copy.copy(ref)
        ti.index = tex_old_new.get(ref.index, ref.index)
        return ti

    mat_old_new: dict[int, int] = {}
    new_mats: list[Material] = []
    for old in sorted(mats):
        m = g.materials[old]
        nm = copy.copy(m)
        pr = getattr(m, "pbrMetallicRoughness", None)
        if pr is not None:
            npr = copy.copy(pr)
            if pr.baseColorTexture is not None:
                npr.baseColorTexture = _remap_texref(pr.baseColorTexture)
            if pr.metallicRoughnessTexture is not None:
                npr.metallicRoughnessTexture = _remap_texref(pr.metallicRoughnessTexture)
            nm.pbrMetallicRoughness = npr
        if m.normalTexture is not None:
            nm.normalTexture = _remap_texref(m.normalTexture)
        if m.occlusionTexture is not None:
            nm.occlusionTexture = _remap_texref(m.occlusionTexture)
        if m.emissiveTexture is not None:
            nm.emissiveTexture = _remap_texref(m.emissiveTexture)
        new_mats.append(nm)
        mat_old_new[old] = len(new_mats) - 1

    # ---- 4) 克隆 mesh / primitive ----
    mesh_old_new: dict[int, int] = {}
    new_meshes: list[Mesh] = []
    for ni in sub_nodes:
        node = g.nodes[ni]
        if node.mesh is not None and node.mesh not in mesh_old_new:
            old = node.mesh
            m = g.meshes[old]
            nm = Mesh()
            nm.name = m.name
            nm.extras = m.extras
            for prim in m.primitives:
                nprim = Primitive()
                nattr = Attributes()
                for sem, ai in _prim_accessor_items(prim):
                    setattr(nattr, sem, acc_old_new[ai])
                nprim.attributes = nattr
                nprim.indices = acc_old_new.get(prim.indices) if prim.indices is not None else None
                nprim.material = mat_old_new.get(prim.material) if prim.material is not None else None
                nprim.mode = prim.mode
                nprim.targets = prim.targets
                nprim.extras = prim.extras
                nm.primitives.append(nprim)
            mesh_old_new[old] = len(new_meshes)
            new_meshes.append(nm)

    # ---- 5) 克隆节点（只保留子树内节点，children 重映射）----
    node_old_new: dict[int, int] = {}
    new_nodes: list[Node] = []
    for ni in sub_nodes:
        on = g.nodes[ni]
        nn = Node()
        nn.name = on.name
        nn.mesh = mesh_old_new.get(on.mesh) if on.mesh is not None else None
        nn.children = [node_old_new[c] for c in (on.children or []) if c in sub_nodes]
        nn.camera = on.camera
        nn.extras = on.extras
        # 局部变换清零：世界矩阵已写到根节点 matrix
        nn.translation = None
        nn.rotation = None
        nn.scale = None
        nn.matrix = None
        node_old_new[ni] = len(new_nodes)
        new_nodes.append(nn)

    # ---- 6) 给每个"区块根节点"写入世界矩阵 ----
    top_nodes = [ni for ni in node_indices if ni in sub_nodes]
    new_root_indices = []
    for ni in top_nodes:
        nn = new_nodes[node_old_new[ni]]
        nn.matrix = _world_matrices_to_column_major(worlds[ni])
        new_root_indices.append(node_old_new[ni])

    return new_nodes, new_meshes, new_accs, new_bvs, new_mats, new_texs, new_imgs, \
        bytes(new_bin), new_root_indices


def _world_matrices_to_column_major(m: np.ndarray) -> list[float]:
    return m.reshape(16, order="F").tolist()


def split_gltf(g: GLTF2, replaced_prefixes: list[str], chunk_size: float = CHUNK_SIZE,
                bin_bytes: bytes = None):
    """返回 [(i, j, worldX, worldZ, glb_bytes)]，不含被替换楼体。"""
    if bin_bytes is None:
        bin_bytes = _gltf_buffer_bytes(g)
    worlds = _world_matrices(g)
    replaced = replaced_prefixes or []

    buckets: dict[tuple[int, int], set[int]] = {}
    for ni, node in enumerate(g.nodes):
        if node.name is None:
            continue
        if any(node.name.startswith(p) for p in replaced):
            continue
        m = BLOCK_RE.match(node.name)
        if not m:
            continue
        i, j = int(m.group(1)), int(m.group(2))
        buckets.setdefault((i, j), set()).add(ni)

    out = []
    for (i, j), node_set in sorted(buckets.items()):
        (new_nodes, new_meshes, new_accs, new_bvs, new_mats,
         new_texs, new_imgs, new_bin, roots) = _collect_references(g, node_set, bin_bytes)
        ng = GLTF2()
        ng.scenes = [Scene(nodes=roots)]
        ng.scene = 0
        ng.nodes = new_nodes
        ng.meshes = new_meshes
        ng.accessors = new_accs
        ng.bufferViews = new_bvs
        ng.materials = new_mats
        ng.textures = new_texs
        ng.images = new_imgs
        # 采样器：texture.sampler 沿用原始索引，必须把原 samplers 一并带上，
        # 否则 Godot 导入时报 "Index sampler = 0 is out of bounds"（区块内无 sampler）。
        ng.samplers = (list(g.samplers) if g.samplers else None)
        import base64
        ng.buffers = [Buffer(
            byteLength=len(new_bin),
            uri="data:application/octet-stream;base64," + base64.b64encode(new_bin).decode("ascii"))]
        ng.asset = g.asset if g.asset else None
        ng.extensionsUsed = g.extensionsUsed
        ng.extensionsRequired = g.extensionsRequired
        # 写 GLB 二进制
        glb = _gltf_to_bytes(ng)
        world_x = (i + 0.5) * chunk_size
        world_z = (j + 0.5) * chunk_size
        out.append((i, j, world_x, world_z, glb))
    return out


def load_replaced_prefixes(data_dir: str) -> list[str]:
    prefixes: list[str] = []
    for fn in ("landmark-detail.json", "landmark-candidates.json"):
        p = os.path.join(data_dir, fn)
        if not os.path.exists(p):
            continue
        try:
            d = json.load(open(p, "r", encoding="utf-8"))
        except Exception:
            continue
        for pre in d.get("replacedMeshPrefixes", []):
            prefixes.append(str(pre))
    return prefixes


# ---------------------------------------------------------------------------
# CLI / 自测
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="把 buildings.glb 按区块切成流式 GLB")
    ap.add_argument("--src", default=None, help="buildings.glb 路径")
    ap.add_argument("--out", default=None, help="输出目录（区块 GLB）")
    ap.add_argument("--manifest", default=None, help="blocks-manifest.json 路径")
    ap.add_argument("--selftest", action="store_true", help="运行合成数据自测")
    args = ap.parse_args()

    if args.selftest:
        return _run_selftest()

    here = os.path.dirname(os.path.abspath(__file__))
    project = os.path.dirname(here)  # GTA_SZ_GODOT
    src = args.src or os.path.join(project, "data", "city", "buildings.glb")
    out = args.out or os.path.join(project, "data", "city", "blocks")
    manifest = args.manifest or os.path.join(project, "data", "city", "blocks-manifest.json")

    if not os.path.exists(src):
        sys.exit("[split_city_blocks] 找不到 %s（先导出 buildings.glb，或用 --src 指定）" % src)

    data_dir = os.path.dirname(src)
    replaced = load_replaced_prefixes(data_dir)
    print("[split_city_blocks] 被地标替换的前缀 %d 个" % len(replaced))

    g = GLTF2().load(src)
    bin_bytes = _read_glb_bin(src)
    chunks = split_gltf(g, replaced, CHUNK_SIZE, bin_bytes)
    os.makedirs(out, exist_ok=True)
    for (i, j, wx, wz, glb) in chunks:
        with open(os.path.join(out, "%d_%d.glb" % (i, j)), "wb") as f:
            f.write(glb)
    manifest_d = {
        "chunkSize": CHUNK_SIZE,
        "generatedBy": "split_city_blocks.py",
        "note": "x/z 为数据坐标(east,north)；chunk_streamer 用焦点数据坐标算距离，"
                "GLB 几何体已是世界坐标，加载即落位。",
        "blocks": [
            {"i": i, "j": j, "x": wx, "z": wz,
             "file": "res://data/city/blocks/%d_%d.glb" % (i, j)}
            for (i, j, wx, wz, _) in chunks
        ],
    }
    with open(manifest, "w", encoding="utf-8") as f:
        json.dump(manifest_d, f, ensure_ascii=False, indent=2)
    total = sum(len(glb) for *_, glb in chunks)
    print("[split_city_blocks] 切出 %d 个区块，合计 %.1f MB -> %s"
          % (len(chunks), total / 1e6, out))
    print("[split_city_blocks] manifest -> %s" % manifest)


def _run_selftest():
    """验证切分算法，重点是**交织(interleaved)缓冲按 accessor 去交织**：
    合成数据的 POSITION 与 NORMAL 共用一个 byteStride 缓冲（真实 buildings.glb 正是如此），
    切出的区块必须只含各自 POSITION 的紧凑字节，且不含交织进去的 NORMAL。"""
    print("[selftest] 生成合成 GLB ...")
    g, verts0, verts1 = _make_synthetic()
    chunks = split_gltf(g, [], CHUNK_SIZE)
    assert len(chunks) == 2, "期望 2 个区块，实际 %d" % len(chunks)

    expect = {0: verts0, 1: verts1}
    for (i, j, wx, wz, glb) in chunks:
        ng = _gltf_from_bytes(glb)
        assert ng.scenes, "区块 %d_%d 无 scene" % (i, j)
        root = ng.nodes[ng.scenes[0].nodes[0]]
        assert root.mesh is not None, "区块 %d_%d 根无 mesh" % (i, j)
        prim = ng.meshes[root.mesh].primitives[0]
        pos = getattr(prim.attributes, "POSITION", None)
        assert pos is not None, "区块 %d_%d 缺 POSITION" % (i, j)
        na = ng.accessors[pos]
        assert na.count == 3, "顶点数应为 3"
        # 新 POSITION 必须紧凑（去交织）：byteLength == count*12，且无 byteStride
        nbv = ng.bufferViews[na.bufferView]
        assert nbv.byteLength == 3 * 12, \
            "POSITION 缓冲应紧凑为 36 字节，实际 %d（去交织失败？）" % nbv.byteLength
        assert not getattr(nbv, "byteStride", None), "去交织后不应再有 byteStride"
        # 内容正确：等于该区块原始 POSITION（不含 NORMAL）
        binb = _glb_bin_from_data(glb)
        got = np.frombuffer(binb[nbv.byteOffset:nbv.byteOffset + nbv.byteLength],
                            dtype=np.float32).reshape(-1, 3)
        assert np.allclose(got, expect[i]), \
            "区块 %d_%d POSITION 内容不符：\n%s\n%s" % (i, j, got, expect[i])
        assert ng.buffers[0].byteLength > 0
    # manifest 坐标
    (i0, j0, wx, wz, _) = chunks[0]
    assert abs(wx - (i0 + 0.5) * CHUNK_SIZE) < 1e-6
    print("[selftest] OK：切出 %d 区块，交织缓冲去交织 / 节点 / 网格 / 缓冲校验通过" % len(chunks))
    return 0


def _make_synthetic():
    """两个独立 block 节点（block_0_0 / block_1_0），POSITION 与 NORMAL **共用一个
    byteStride=24 的交织 bufferView**（复刻 buildings.glb 的真实布局），验证：
    节点提取、世界矩阵、按 accessor 去交织、manifest 坐标。
    返回 (gltf, verts0, verts1)。"""
    verts0 = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
    verts1 = np.array([[0, 0, 10], [1, 0, 10], [0, 1, 10]], dtype=np.float32)
    normals = np.array([[0, 0, 1]] * 3, dtype=np.float32)

    def interleave(pos):
        # 每顶点 [px,py,pz, nx,ny,nz]，共 24 字节；3 顶点 = 72 字节
        v = np.hstack([pos, normals]).astype(np.float32)
        return v.tobytes()

    d0 = interleave(verts0)
    d1 = interleave(verts1)
    blob = bytearray()
    off0 = 0
    blob.extend(d0)
    off1 = len(blob)
    blob.extend(d1)

    g = GLTF2()
    import base64
    g.buffers = [Buffer(
        byteLength=len(blob),
        uri="data:application/octet-stream;base64," + base64.b64encode(bytes(blob)).decode("ascii"))]
    # 两个交织 bufferView：stride=24，覆盖 POSITION(off 0) + NORMAL(off 12)
    g.bufferViews = [
        BufferView(buffer=0, byteOffset=off0, byteLength=len(d0), byteStride=24, target=34962),
        BufferView(buffer=0, byteOffset=off1, byteLength=len(d1), byteStride=24, target=34962),
    ]
    g.accessors = [
        Accessor(bufferView=0, byteOffset=0, componentType=5126, count=3, type="VEC3"),   # POSITION 0
        Accessor(bufferView=0, byteOffset=12, componentType=5126, count=3, type="VEC3"),   # NORMAL 0
        Accessor(bufferView=1, byteOffset=0, componentType=5126, count=3, type="VEC3"),   # POSITION 1
        Accessor(bufferView=1, byteOffset=12, componentType=5126, count=3, type="VEC3"),   # NORMAL 1
    ]
    g.materials = [Material(name="b")]
    g.meshes = [
        Mesh(name="block_0_0", primitives=[Primitive(
            attributes=Attributes(POSITION=0, NORMAL=1), material=0, mode=4)]),
        Mesh(name="block_1_0", primitives=[Primitive(
            attributes=Attributes(POSITION=2, NORMAL=3), material=0, mode=4)]),
    ]
    g.nodes = [
        Node(name="block_0_0", mesh=0),
        Node(name="block_1_0", mesh=1),
    ]
    g.scenes = [Scene(nodes=[0, 1])]
    g.scene = 0
    g.asset = {"version": "2.0"}
    # 直接返回：缓冲以 data: URI 挂在 buffer.uri 上（_gltf_buffer_bytes 可解码）。
    return g, verts0, verts1


if __name__ == "__main__":
    sys.exit(main())
