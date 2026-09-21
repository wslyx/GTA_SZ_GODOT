#!/usr/bin/env python3
"""对 GTA_SZ_GODOT 做静态体检。

本项目约定「禁止编译校验」，所以这里用纯静态分析抓最容易出错的三类问题：
  1. res:// 路径写错（preload / load / ResourceLoader.exists 的目标不存在）
  2. 括号 / 引号不平衡
  3. class_name 引用悬空（用了某个类名但没有脚本定义它）

用法：python tools/validate_project.py [项目根目录]
"""
import os
import re
import sys
import glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

gd_files = sorted(glob.glob(os.path.join(ROOT, "**", "*.gd"), recursive=True))
shader_files = sorted(glob.glob(os.path.join(ROOT, "**", "*.gdshader"), recursive=True))

problems = []


def rel(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")


def strip_code(text):
    """去掉注释与字符串，便于做括号配对检查。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == '"' or c == "'":
            quote = c
            triple = text[i:i + 3] == quote * 3
            if triple:
                i += 3
                while i < n and text[i:i + 3] != quote * 3:
                    i += 1
                i += 3
            else:
                i += 1
                while i < n and text[i] != quote:
                    if text[i] == "\\":
                        i += 1
                    i += 1
                i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ---------- 1. 括号平衡 ----------
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    code = strip_code(src)
    for open_c, close_c, label in (("(", ")", "圆括号"), ("[", "]", "方括号"), ("{", "}", "花括号")):
        if code.count(open_c) != code.count(close_c):
            problems.append("括号不平衡 %-46s %s %d/%d" % (
                rel(p), label, code.count(open_c), code.count(close_c)))

# ---------- 2. class_name 收集 ----------
class_defs = {}
for p in gd_files:
    for m in re.finditer(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", open(
            p, "r", encoding="utf-8").read(), re.M):
        name = m.group(1)
        if name in class_defs:
            problems.append("class_name 重复：%s（%s 与 %s）" % (name, class_defs[name], rel(p)))
        class_defs[name] = rel(p)

# ---------- 3. res:// 路径存在性 ----------
path_re = re.compile(r'"(res://[^"\n]+)"')
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    for m in path_re.finditer(src):
        target = m.group(1)
        local = os.path.join(ROOT, target[len("res://"):].replace("/", os.sep))
        if not os.path.exists(local):
            problems.append("res:// 路径不存在 %-30s ← %s" % (target, rel(p)))

# ---------- 4. autoload 名称 ----------
autoloads = set()
proj = os.path.join(ROOT, "project.godot")
if os.path.exists(proj):
    text = open(proj, "r", encoding="utf-8").read()
    in_auto = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[autoload]"):
            in_auto = True
            continue
        if s.startswith("[") and s != "[autoload]":
            in_auto = False
        if in_auto and "=" in s:
            autoloads.add(s.split("=")[0].strip())
    for name, _ in [("CoordinateUtil", 0), ("GameState", 0), ("SaveSystem", 0),
                    ("GraphicsQuality", 0), ("CityData", 0), ("GameContent", 0)]:
        if name not in autoloads:
            problems.append("autoload 缺失：%s" % name)

# ---------- 5. 单例 / 类名引用悬空 ----------
known = set(class_defs) | autoloads | {
    "Node", "Node3D", "Node2D", "Control", "CanvasLayer", "RefCounted", "Object",
    "Resource", "MeshInstance3D", "MultiMesh", "MultiMeshInstance3D", "Camera3D",
    "DirectionalLight3D", "OmniLight3D", "SpotLight3D", "WorldEnvironment", "Environment",
    "ShaderMaterial", "StandardMaterial3D", "ORMMaterial3D", "SurfaceTool", "ArrayMesh",
    "Mesh", "BoxMesh", "SphereMesh", "Label", "Label3D", "ColorRect", "Texture2D",
    "String", "Vector2", "Vector3", "Vector4", "Vector2i", "Vector3i", "Rect2", "Rect2i",
    "Color", "Basis", "Transform3D", "Quaternion", "PackedScene", "RandomNumberGenerator",
    "SystemFont", "Font", "Sky", "PanoramaSkyMaterial", "Time", "Engine", "Input",
    "InputEvent", "InputEventKey", "InputEventMouseButton", "InputEventMouseMotion",
    "FileAccess", "DirAccess", "ProjectSettings", "DisplayServer", "JSON", "RegEx",
    "Timer", "Tween", "SceneTree", "Geometry2D", "Math", "Callable", "Dictionary",
    "Array", "PackedFloat32Array", "PackedFloat64Array", "PackedInt32Array", "PackedByteArray",
    "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "GDScript",
    "World3D", "Viewport", "SubViewport", "Material", "BaseMaterial3D", "GeometryInstance3D",
    "CollisionShape3D", "StaticBody3D", "CharacterBody3D", "Area3D", "RigidBody3D",
    "NodePath", "DebugDraw", "VisualInstance3D", "Light3D", "AnimationPlayer", "AudioStreamPlayer",
    "AudioStreamPlayer3D", "AudioStreamGenerator", "AudioStreamGeneratorPlayback",
    "Theme", "StyleBoxFlat", "VBoxContainer", "HBoxContainer", "MarginContainer", "Panel",
    "TextureRect", "ProgressBar", "OptionButton", "Button", "CheckBox", "Slider", "Container",
    "Shape3D", "BoxShape3D", "SphereShape3D", "ConcavePolygonShape3D", "MeshInstance3D",
    "PackedScene", "ResourceLoader", "Thread", "WorkerThreadPool", "Image", "ImageTexture",
    "NoiseTexture2D", "FastNoiseLite", "AnimationTree", "Skeleton3D", "BoneAttachment3D",
}
known |= set(class_defs)

# 收集 `XxxName.new()` / `XxxName.某常量` 形式的引用
ref_re = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\.(?:new|CONST|[A-Z][A-Z0-9_]+)\b")
ignore_prefix = ("Object", "Resource", "Mesh", "Render", "Shader", "Surface", "Material",
                 "Geometry", "Physics", "Vector", "Color", "Basis", "Transform", "Input",
                 "Display", "Project", "Engine", "File", "Dir", "JSON", "RegEx", "Time",
                 "Math", "Node", "Camera", "Light", "Environment", "Sky", "Font", "Label",
                 "Rendering", "Projection", "Curve", "Gradient", "Noise", "Image", "Audio",
                 "Animation", "Skeleton", "Multi", "Packed", "Array", "Dictionary", "Callable",
                 "Random", "Scene", "Tween", "Timer", "Viewport", "World", "Theme", "Style",
                 "Container", "Control", "Panel", "Texture", "Progress", "Option", "Button",
                 "Check", "Slider", "Shape", "Box", "Sphere", "Concave", "Static", "Character",
                 "Area", "Rigid", "Collision", "Canvas", "Config", "System", "Environment",
                 "Performance", "OS", "Class", "Variant", "Expression", "String", "FastNoise")
suspicious = {}
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    code = strip_code(src)
    for m in ref_re.finditer(code):
        name = m.group(1)
        if name in known:
            continue
        if name.startswith(ignore_prefix):
            continue
        suspicious.setdefault(name, set()).add(rel(p))

for name, files in sorted(suspicious.items()):
    problems.append("可疑类名引用 %-26s ← %s" % (name, ", ".join(sorted(files)[:3])))

# ---------- 5. 类型推断风险（Variant 来源的 := ）----------
# GDScript 里 `dict["key"]` 取出的是 Variant，`var x := dict["key"]` 会因为
# "Cannot infer the type of x variable" 报解析错误。同理 `a if c else b` 两边都是
# Variant 时也推断不出来。而 `float(d["x"])` / `int(e[0])` 这类**外面套了转换函数**
# 的写法是安全的（返回类型由函数签名决定），所以只检查"最外层就是下标"或
# "三元两边都是下标"的形态。
VARIANT_WRAPPERS = (
    "float(", "int(", "str(", "bool(", "absf(", "absi(", "sinf(", "cosf(", "tanf(",
    "minf(", "maxf(", "mini(", "maxi(", "clampf(", "clampi(", "sqrt(", "pow(", "round(",
    "floor(", "ceil(", "signf(", "lerpf(", "rad_to_deg(", "deg_to_rad(", "snappedf(",
    "Array(", "Vector2(", "Vector3(", "Vector4(", "Color(", "Basis(", "Transform3D(",
    "PackedStringArray(", "PackedVector2Array(", "PackedVector3Array(", "PackedInt32Array(",
    "PackedFloat32Array(", "PackedFloat64Array(", "PackedByteArray(", "String(", "format(",
    "fposmod(", "wrapf(", "sin(", "cos(", "atan2(", "exp(", "log(", "is_finite(",
)

SUBSCRIPT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\[.*\]$", re.S)
TERNARY_RE = re.compile(r"^(.*?)\s+if\s+(.+?)\s+else\s+(.*)$", re.S)


def dict_valued_names(text):
    """收集该文件里确定是 Dictionary 的标识符。"""
    names = set()
    for m in re.finditer(r"^\s*(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*Dictionary)?\s*:?=\s*\{",
                         text, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^\s*(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Dictionary",
                         text, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"func\s+\w+\s*\(([^)]*)\)", text):
        for part in m.group(1).split(","):
            mm = re.match(r"\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Dictionary", part)
            if mm:
                names.add(mm.group(0).split(":")[0].strip())
    return names


type_risks = []
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    code = strip_code(src)
    dicts = dict_valued_names(code)
    for i, line in enumerate(code.splitlines(), 1):
        m = re.match(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+?)\s*$", line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2).strip()
        if rhs.startswith(VARIANT_WRAPPERS):
            continue
        sub = SUBSCRIPT_RE.match(rhs)
        if sub and sub.group(1) in dicts:
            type_risks.append("%s:%d  var %s := %s   ← 字典下标是 Variant，改成 var %s: <类型> = ..."
                              % (rel(p), i, name, rhs, name))
            continue
        tm = TERNARY_RE.match(rhs)
        if tm:
            a, b = SUBSCRIPT_RE.match(tm.group(1).strip()), SUBSCRIPT_RE.match(tm.group(3).strip())
            if a and b and a.group(1) in dicts:
                type_risks.append("%s:%d  var %s := %s   ← 三元两边都是字典下标（Variant）"
                                  % (rel(p), i, name, rhs))

for x in type_risks:
    problems.append("类型推断风险 " + x)

# ---------- 6. 调用未声明返回类型的函数 + := 推断 ----------
# `func f():` 没有 `-> T` 时返回 Variant（哪怕是 `return {}` / `return 1.0`）。
# `var x := f()` 就会报 "Cannot infer the type of x variable"。
# 这是同一类错误的第二种来源，和字典下标一样高频。
FUNC_DEF_RE = re.compile(r"^\s*(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?:->\s*([^:\n]+))?:",
                         re.M)

project_funcs = {}      # 名称 → 是否有返回类型（跨文件合并，同名取"有类型优先"）
for p in gd_files:
    for m in FUNC_DEF_RE.finditer(open(p, "r", encoding="utf-8").read()):
        name = m.group(1)
        typed = m.group(3) is not None and m.group(3).strip() != ""
        project_funcs[name] = project_funcs.get(name, False) or typed

untyped_calls = []
for p in gd_files:
    code = strip_code(open(p, "r", encoding="utf-8").read())
    for i, line in enumerate(code.splitlines(), 1):
        m = re.match(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                     line)
        if not m:
            continue
        name, callee = m.group(1), m.group(2)
        if callee in project_funcs and not project_funcs[callee]:
            untyped_calls.append("%s:%d  var %s := %s(...)   ← 该函数没有声明 -> 返回类型"
                                 % (rel(p), i, name, callee))

for x in untyped_calls:
    problems.append("类型推断风险 " + x)

# ---------- 7. 遍历无类型容器的循环变量 + := ----------
# 第三个 Variant 来源，而且最隐蔽：
#     for k in [A, B, C]:          # 无类型数组字面量 → k 是 Variant
#         var p := "user://" + k   # → 推断失败
#
# 判据要同时满足两条，缺一就会大面积误报：
#   (a) 迭代对象**确定**是 Variant 来源
#       —— 只认三种：数组字面量 `[...]`、`.keys()` / `.values()`、裸名且声明为 Array / Dictionary。
#          不要用"猜不出类型就算 Variant"的兜底，那会把 `for r in rows - 1`、
#          `for i in arr.size()`、`for n in graph.nodes` 这些**有类型**的写法全误报。
#   (b) RHS 的**最外层不是函数调用**
#       —— `str(i)` / `float(i) / 10.0` / `Vector2(v).distance_to(..)` 的返回类型由被调函数
#          决定，与参数里的 Variant 无关，是安全的。只有裸的算术、下标、三元才会被污染。
CALL_HEAD_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*\s*\(")
LOOP_RE = re.compile(r"^(\s*)for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?):\s*$")
# 把 Variant 包进这些转换函数后，结果类型由被调函数决定 → 安全
WRAP_AROUND_RE = (r"(?:float|int|str|bool|absf|absi|signf|signi|Vector2|Vector3|Vector4|"
                  r"Color|Array|PackedVector2Array|PackedVector3Array)\s*\(\s*[^)]*\b%s\b")

loop_risks = []
for p in gd_files:
    code = strip_code(open(p, "r", encoding="utf-8").read())
    lines = code.splitlines()
    # 同名变量在不同函数里类型可能不同，所以收集**所有**声明；
    # 只有全部声明都是 Array / Dictionary 时才认定它是 Variant 来源
    # （否则 `pts` 这种"某处是 PackedVector2Array、某处是 Array"的情况会误报）
    declared_sets = {}
    for m in re.finditer(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)", code, re.M):
        declared_sets.setdefault(m.group(1), set()).add(m.group(2))
    for i, line in enumerate(lines):
        m = LOOP_RE.match(line)
        if not m:
            continue
        indent, var, iterable = m.group(1), m.group(2), m.group(3).strip()
        if iterable.startswith("["):
            is_variant = True
        elif iterable.endswith(".keys()") or iterable.endswith(".values()"):
            is_variant = True
        elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", iterable):
            types = declared_sets.get(iterable)
            is_variant = bool(types) and types <= {"Array", "Dictionary"}
        else:
            is_variant = False
        if not is_variant:
            continue
        for j in range(i + 1, len(lines)):
            body = lines[j]
            if body.strip() == "":
                continue
            body_indent = len(body) - len(body.lstrip())
            if body_indent <= len(indent):
                break
            use = re.search(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+?)\s*$", body)
            if not use:
                continue
            rhs = use.group(2)
            if not re.search(r"\b%s\b" % re.escape(var), rhs):
                continue
            if CALL_HEAD_RE.match(rhs):
                continue            # RHS 是函数调用 → 返回类型由被调函数决定
            if rhs.startswith("{"):
                continue            # 字典字面量，推断为 Dictionary，不是 Variant
            if re.search(WRAP_AROUND_RE % re.escape(var), rhs):
                continue            # Variant 被转换函数包住了 → 安全
            loop_risks.append("%s:%d  for %s in %s → var %s := %s   ← 算术里混入了 Variant 循环变量"
                              % (rel(p), j + 1, var, iterable, use.group(1), rhs))

for x in loop_risks:
    problems.append("类型推断风险 " + x)

# ---------- 8. 与原生类成员重名 ----------
# `Node` 已有 `ready` 信号；`Node3D` 已有 position/rotation/scale/visible…
# 在自己的脚本里再 `var ready := …` 会报
#     Member "ready" redefined (original in native class 'Node3D')
NODE_BASE_MEMBERS = {
    "ready", "name", "owner", "tree", "process_mode", "process_priority",
    "script", "scene_file_path", "multiplayer", "editor_description",
}
NODE3D_BASE_MEMBERS = NODE_BASE_MEMBERS | {
    "position", "rotation", "rotation_degrees", "rotation_edit_mode", "scale",
    "transform", "global_transform", "global_position", "global_basis",
    "global_rotation", "basis", "quaternion", "visible", "top_level",
    "axis_lock_angular_x", "axis_lock_angular_y", "axis_lock_angular_z",
}
CAMERA3D_BASE_MEMBERS = NODE3D_BASE_MEMBERS | {
    "fov", "near", "far", "current", "projection", "size", "h_offset", "v_offset",
    "keep_aspect", "cull_mask", "environment", "doppler_tracking",
}
CANVASLAYER_BASE_MEMBERS = {
    "layer", "visible", "offset", "rotation", "scale", "transform",
    "follow_viewport_enabled", "follow_viewport_scale", "custom_viewport",
}
EXTENDS_MEMBERS = {
    "Node": NODE_BASE_MEMBERS,
    "Node2D": NODE_BASE_MEMBERS | {"position", "rotation", "scale", "visible", "transform"},
    "Node3D": NODE3D_BASE_MEMBERS,
    "Camera3D": CAMERA3D_BASE_MEMBERS,
    "CanvasLayer": CANVASLAYER_BASE_MEMBERS,
    "Control": CANVASLAYER_BASE_MEMBERS | {"size", "modulate", "mouse_filter", "theme"},
    "CollisionObject3D": NODE3D_BASE_MEMBERS,
    "CharacterBody3D": NODE3D_BASE_MEMBERS,
    "StaticBody3D": NODE3D_BASE_MEMBERS,
    "Area3D": NODE3D_BASE_MEMBERS,
    "RigidBody3D": NODE3D_BASE_MEMBERS,
    "Light3D": NODE3D_BASE_MEMBERS,
    "DirectionalLight3D": NODE3D_BASE_MEMBERS,
    "OmniLight3D": NODE3D_BASE_MEMBERS,
    "SpotLight3D": NODE3D_BASE_MEMBERS,
    "MeshInstance3D": NODE3D_BASE_MEMBERS | {"mesh", "material_override", "skeleton"},
}

shadow_risks = []
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    em = re.search(r"^extends\s+([A-Za-z_][A-Za-z0-9_]*)", src, re.M)
    if not em:
        continue
    members = EXTENDS_MEMBERS.get(em.group(1))
    if not members:
        continue
    for i, line in enumerate(strip_code(src).splitlines(), 1):
        dm = re.match(r"^\s*(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::|=)", line)
        if dm and dm.group(1) in members:
            shadow_risks.append("%s:%d  %s   ← 与 %s 的原生成员重名"
                                % (rel(p), i, line.strip(), em.group(1)))

for x in shadow_risks:
    problems.append("成员重名 " + x)

# ---------- 9. 不存在的全局函数 ----------
# Godot 4 的全局作用域里 sin/cos/tan 只接受 float，**没有** sinf/cosf/tanf。
# 同理容易误写的还有 sqrtf/powf/floorf 之类（这些也不存在）。
BAD_GLOBALS = {
    "sinf": "sin", "cosf": "cos", "tanf": "tan",
    "sqrtf": "sqrt", "powf": "pow", "fmodf": "fmod",
}
bad_calls = []
for p in gd_files:
    code = strip_code(open(p, "r", encoding="utf-8").read())
    for i, line in enumerate(code.splitlines(), 1):
        for bad, good in BAD_GLOBALS.items():
            if re.search(r"\b%s\s*\(" % bad, line):
                bad_calls.append("%s:%d  %s(...) 不存在，应为 %s(...)"
                                 % (rel(p), i, bad, good))

for x in bad_calls:
    problems.append("函数不存在 " + x)

# ---------- 10. autoload 必须 extends Node ----------
# 否则启动时报
#     ERROR: Failed to instantiate an autoload, script '...' does not inherit from 'Node'.
# （脚本自身有解析错误时也会连带报这一条，所以要配合前面的规则一起看）
if os.path.exists(proj):
    text = open(proj, "r", encoding="utf-8").read()
    in_auto = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[autoload]"):
            in_auto = True
            continue
        if s.startswith("[") and s != "[autoload]":
            in_auto = False
        if not in_auto or "=" not in s or s.startswith(";"):
            continue
        name_, value = s.split("=", 1)
        name_ = name_.strip()
        target = value.strip().lstrip("*").strip().strip('"')
        if not target.startswith("res://"):
            continue
        local = os.path.join(ROOT, target[len("res://"):].replace("/", os.sep))
        if not os.path.exists(local):
            continue
        head = open(local, "r", encoding="utf-8").read()
        em = re.search(r"^extends\s+([A-Za-z_][A-Za-z0-9_.]*)", head, re.M)
        if not em:
            problems.append("autoload 缺 extends %s（%s）" % (name_, target))
        elif em.group(1) not in ("Node", "Node3D", "Node2D", "Control", "CanvasLayer"):
            problems.append("autoload %s 继承自 %s，不是 Node（%s）" % (name_, em.group(1), target))

# ---------- 11. const 里放了非常量表达式 ----------
# 报错长这样：
#     Assigned value for constant "X" isn't a constant expression.
# Godot 只对**值类型**（Vector2 / Vector3 / Vector4 / Color / Basis / Rect2 …）的构造
# 做常量折叠；Packed*Array 的构造不是常量表达式。
# 另外 const 上带 `: Array[T]` 类型标注同样有兼容风险，一并拦掉。
const_risks = []
for p in gd_files:
    src = open(p, "r", encoding="utf-8").read()
    for i, line in enumerate(strip_code(src).splitlines(), 1):
        s = line.strip()
        if not s.startswith("const ") or "=" not in s:
            continue
        rhs = s.split("=", 1)[1]
        if re.search(r"Packed\w*Array\s*\(", rhs):
            const_risks.append("%s:%d  %s   ← Packed*Array 构造不是常量表达式，"
                               "改成 const 放普通数组、函数体内再转 Packed*Array"
                               % (rel(p), i, s[:80]))
        elif re.search(r":\s*Array\s*\[", s):
            const_risks.append("%s:%d  %s   ← const 带 Array[T] 标注有兼容风险，"
                               "去掉标注、在调用处显式标注类型" % (rel(p), i, s[:80]))

for x in const_risks:
    problems.append("常量表达式 " + x)

# ---------- 12. 带类型标注的循环变量 ----------
# `for x: float in arr:` 这类写法的语法兼容性不确定，统一用
# 「函数体内把容器转成 Packed*Array 再遍历」的写法代替。
typed_loop = []
for p in gd_files:
    code = strip_code(open(p, "r", encoding="utf-8").read())
    for i, line in enumerate(code.splitlines(), 1):
        if re.match(r"^\s*for\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*[A-Za-z_][A-Za-z0-9_]*\s+in\s+", line):
            typed_loop.append("%s:%d  %s" % (rel(p), i, line.strip()))

for x in typed_loop:
    problems.append("语法兼容性 " + x)

# ---------- 报告 ----------
print("项目：%s" % ROOT)
print("GDScript %d 个，shader %d 个，class_name %d 个，autoload %d 个"
      % (len(gd_files), len(shader_files), len(class_defs), len(autoloads)))
print()
if problems:
    print("发现 %d 项：" % len(problems))
    for x in problems:
        print("  " + x)
else:
    print("未发现问题。")

print()
print("class_name 清单：")
for k in sorted(class_defs):
    print("  %-24s %s" % (k, class_defs[k]))

sys.exit(1 if problems else 0)
