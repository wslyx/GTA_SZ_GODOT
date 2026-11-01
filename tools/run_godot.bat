@echo off
rem ============================================================
rem  启动深城纪（GTA_SZ_GODOT）
rem
rem  - 用便携 .NET SDK（Godot mono 需要；系统里没装 SDK）
rem  - 打开 ALS_SKIP_PROVENANCE=1：本机仓库里的 ALS 资产与导出时的字节
rem    不完全一致（git 把 json 换行规范化了），取证摘要会对不上，
rem    人物将不显示。开关只跳过"跨文件摘要"比较，结构校验照常。
rem    详见 修复记录.md 三十六节。
rem
rem  用法：tools\run_godot.bat            普通运行
rem        tools\run_godot.bat --headless  无头
rem ============================================================

set "DOTNET_SDK_DIR=D:/PortableSoft/dotnet-sdk-8.0.424-win-x64"
set "GODOT_EXE=D:/PortableSoft/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"

set "DOTNET_ROOT=%DOTNET_SDK_DIR%"
set "DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR=%DOTNET_SDK_DIR%"
set "PATH=%DOTNET_SDK_DIR%;%PATH%"
set "ALS_SKIP_PROVENANCE=1"

if not exist "%GODOT_EXE%" (
    echo [ERROR] 找不到 Godot: %GODOT_EXE%
    exit /b 1
)

rem 以本脚本所在目录的上一级作为项目根
pushd "%~dp0.."
"%GODOT_EXE%" --path . %*
popd
