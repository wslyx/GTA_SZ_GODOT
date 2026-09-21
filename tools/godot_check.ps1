$ErrorActionPreference = "Continue"
$g   = "D:\programs\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe"
$src = "D:\CodePro\game_ws\GTA_SZ_GODOT"
$dst = "C:\Users\YIYAY\AppData\Local\Temp\gdcheck"
$log = "C:\Users\YIYAY\AppData\Local\Temp\gdscan_raw.txt"
$out = "C:\Users\YIYAY\AppData\Local\Temp\gdscan_err.txt"

Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item "$src\project.godot", "$src\icon.svg" $dst -Force
foreach ($d in @("scripts", "shaders", "scenes")) {
    Copy-Item "$src\$d" "$dst\$d" -Recurse -Force
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
