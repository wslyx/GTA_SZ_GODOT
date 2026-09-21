import glob, os, re

root = r"D:\CodePro\game_ws\GTA_SZ_GODOT\scripts"
changed = []

def load(p):
    return open(p, "r", encoding="utf-8").read()

def save(p, s):
    open(p, "w", encoding="utf-8", newline="\n").write(s)

# ---------------------------------------------------------------
# 1) MeshInstance3D.new() + .multimesh=  →  MultiMeshInstance3D.new()
#    （multimesh 属性在 MultiMeshInstance3D 上，MeshInstance3D 没有）
# ---------------------------------------------------------------
for p in sorted(glob.glob(os.path.join(root, "**", "*.gd"), recursive=True)):
    src = load(p)
    lines = src.splitlines()
    out = list(lines)
    hits = 0
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)var\s+(\w+)\s*:=\s*MeshInstance3D\.new\(\)\s*$", line)
        if not m:
            continue
        indent, name = m.group(1), m.group(2)
        # 往下看 8 行内是否有 name.multimesh =
        window = "\n".join(lines[i:i + 9])
        if re.search(r"\b%s\.multimesh\s*=" % re.escape(name), window):
            out[i] = ("%svar %s := MultiMeshInstance3D.new()" % (indent, name))
            hits += 1
    if hits:
        save(p, "\n".join(out) + "\n")
        changed.append("%s  multimesh 节点 ×%d" % (os.path.relpath(p, root).replace("\\", "/"), hits))

# ---------------------------------------------------------------
# 2) PanoramaSkyMaterial.rotation 是 float，不是 Vector3
# ---------------------------------------------------------------
p = os.path.join(root, "world", "sky_system.gd")
s = load(p)
old = 'pano.rotation = Vector3(0.0, float(HDR_ROTATION.get(m, 0.0)), 0.0)'
new = ('# PanoramaSkyMaterial.rotation 是 **float**（绕 Y 的弧度），不是 Vector3\n'
       '\tpano.rotation = float(HDR_ROTATION.get(m, 0.0))')
if old in s:
    s = s.replace(old, new)
    save(p, s)
    changed.append("sky_system.gd  pano.rotation → float")

# ---------------------------------------------------------------
# 3) world.spawn_pos 不存在，应为 CityData.spawn_pos
# ---------------------------------------------------------------
for f in ["world/pedestrian_system.gd", "world/traffic_system.gd"]:
    p = os.path.join(root, f)
    s = load(p)
    if "world.spawn_pos" in s:
        s = s.replace("world.spawn_pos", "CityData.spawn_pos")
        save(p, s)
        changed.append("%s  world.spawn_pos → CityData.spawn_pos" % f)

# ---------------------------------------------------------------
# 4) SystemFont 没有 font_size 属性
# ---------------------------------------------------------------
for f in ["ui/map_ui.gd", "ui/panels_ui.gd"]:
    p = os.path.join(root, f)
    s = load(p)
    n = len(re.findall(r"^\s*sf\.font_size\s*=\s*size\s*$", s, re.M))
    if n:
        s = re.sub(r"^(\s*)sf\.font_size\s*=\s*size\s*$",
                   r"\1# SystemFont 没有 font_size 属性（那是 Label 的主题字号），删掉\n"
                   r"\1# 由 add_theme_font_size_override / Label3D.font_size 控制",
                   s, flags=re.M)
        save(p, s)
        changed.append("%s  移除 sf.font_size ×%d" % (f, n))

# ---------------------------------------------------------------
# 5) SurfaceTool.generate_tangents() 需要 UV，程序化网格没有 → 移除
# ---------------------------------------------------------------
p = os.path.join(root, "utils", "geom_util.gd")
s = load(p)
n = len(re.findall(r"^\s*st\.generate_tangents\(\)\s*$", s, re.M))
if n:
    s = re.sub(r"^(\s*)st\.generate_tangents\(\)\s*$",
               r"\1# 不调用 generate_tangents()：程序化网格没有 UV，会报\n"
               r"\1# \"UVs are required to generate tangents\"；这几个网格也不需要切线",
               s, flags=re.M)
    save(p, s)
    changed.append("geom_util.gd  移除 generate_tangents ×%d" % n)

# ---------------------------------------------------------------
# 6) land 是 [ [ ring, ... ], ... ]（陆地分组），比 coast 多一层
# ---------------------------------------------------------------
p = os.path.join(root, "core", "city_data.gd")
s = load(p)
old = 'land_rings = city.get("land", [])\n\tcoast_rings = city.get("coast", [])'
new = ('land_rings = _flatten_ring_groups(city.get("land", []))\n'
       '\tcoast_rings = city.get("coast", [])')
if old in s:
    helper = (
        "\n\n"
        "## 把「陆地分组」拍平成环列表。\n"
        "## city.json 里 `land` 的结构是 `[ [ ring, ... ], ... ]`（陆地分组，每组含若干环），\n"
        "## 而 `coast` 是 `[ ring, ... ]`。不拍平的话，碰撞里的\n"
        "## `if ring.size() >= 3` 会把「分组」当成环判掉（分组只有 1 个元素），\n"
        "## 结果就是陆地环为 0 —— 所有点都不在陆地上，一开车就被判阻挡。\n"
        "static func _flatten_ring_groups(groups: Array) -> Array:\n"
        "\tvar out: Array = []\n"
        "\tfor g in groups:\n"
        "\t\tif g is Array and g.size() > 0 and g[0] is Array \\\n"
        "\t\t\t\tand g[0].size() > 0 and g[0][0] is Array:\n"
        "\t\t\tout.append_array(g)      # 是分组：内层每个元素才是一个环\n"
        "\t\telse:\n"
        "\t\t\tout.append(g)            # 直接就是环\n"
        "\treturn out\n")
    if "_flatten_ring_groups" not in s:
        s = s.replace(old, new)
        # 把 helper 挂到 _closest_on_segment 之前
        anchor = "static func _closest_on_segment("
        if anchor in s:
            s = s.replace(anchor, helper.lstrip("\n") + "\n\n\n" + anchor, 1)
        save(p, s)
        changed.append("city_data.gd  land 分组拍平")

for c in changed:
    print("  " + c)
print("done, %d 项" % len(changed))
