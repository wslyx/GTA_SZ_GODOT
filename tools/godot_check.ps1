param(
    # 项目根目录；不传则按脚本位置推断（tools/ 的上一级）
    [string]$ProjectRoot = ""
)
$ErrorActionPreference = "Continue"

# GDScript 编译体检：把 scripts/shaders/scenes 复制到临时目录，用 Godot 的
# --headless --editor --quit 跑一遍，只把报错行捞出来。
#
# 路径全部**从脚本位置推**，不写死盘符/用户名 —— 这个脚本原先写的是
# D:\programs / D:\CodePro\game_ws / C:\Users\YIYAY，项目迁盘、换用户之后一跑就炸。
#
# 用法：
#   .\tools\godot_check.ps1
#   .\tools\godot_check.ps1 -ProjectRoot E:\path\to\project
#   $env:GODOT_EXE = "E:\Godot\Godot_v4.7.x_console.exe"; .\tools\godot_check.ps1
#
# ⚠️ 本文件必须存成 **UTF-8 带 BOM**：Windows PowerShell 5.1 对无 BOM 的 .ps1
#    按 ANSI(GBK) 解码，中文注释会被拆成非法标记，直接报
#    "表达式或语句中包含意外的标记"。改动本文件后请确认 BOM 还在。

if (-not $ProjectRoot) {
    $here = $PSScriptRoot
    if (-not $here) {
        # 某些宿主（-Command 注入 / dot-source）下 $PSScriptRoot 为空，退回调用路径
        if ($MyInvocation.MyCommand.Path) {
            $here = Split-Path -Parent $MyInvocation.MyCommand.Path
        } else {
            $here = Join-Path (Get-Location).Path "tools"
        }
    }
    $ProjectRoot = Split-Path -Parent $here
}
if (-not (Test-Path (Join-Path $ProjectRoot "project.godot"))) {
    Write-Error "项目根不正确（找不到 project.godot）: $ProjectRoot"
    exit 1
}
$src = $ProjectRoot

$g = $env:GODOT_EXE
# 本机已知的一份（portable 安装）；换机器请设 GODOT_EXE 或加进 PATH
if (-not $g) {
    $known = "D:/PortableSoft/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
    if (Test-Path $known) { $g = $known }
}
if (-not $g) {
    $cmd = Get-Command godot, godot_console -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $g = $cmd.Source }
}
if (-not $g -or -not (Test-Path $g)) {
    Write-Error "找不到 Godot 可执行文件：请设置 `$env:GODOT_EXE 指向 Godot_v4.x_*_console.exe，或把 godot 加进 PATH"
    exit 1
}

$dst = Join-Path $env:TEMP "gdcheck"
$log = Join-Path $env:TEMP "gdscan_raw.txt"
$out = Join-Path $env:TEMP "gdscan_err.txt"

Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src "project.godot") $dst -Force
$icon = Join-Path $src "icon.svg"
if (Test-Path $icon) { Copy-Item $icon $dst -Force }
foreach ($d in @("scripts", "shaders", "scenes")) {
    $from = Join-Path $src $d
    if (Test-Path $from) { Copy-Item $from (Join-Path $dst $d) -Recurse -Force }
}

& $g --headless --editor --quit --path $dst *> $log

# 只保留报错行，并去掉进度条的 ANSI 噪音
$lines = Get-Content $log -Encoding utf8
$keep = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i] -replace "\x1b\[[0-9;]*m", ""
    if ($l -match "SCRIPT ERROR|Parse Error|Compile Error|ERROR:|WARNING:|at: GDScript|^\s*at: ") {
        $keep += $l.Trim()
    }
}
$keep += ""
$keep += "=== 统计 ==="
$keep += ("SCRIPT ERROR 行: " + ($keep | Where-Object { $_ -match "SCRIPT ERROR" } | Measure-Object).Count)
$keep -join "`n" | Set-Content -Encoding utf8 $out

Write-Host "结果写入: $out"
