using System;
using System.Collections.Generic;

namespace GodotAls.Import.Compilation;

/// <summary>
/// 资产"导出取证摘要"校验的旁路开关。
///
/// ALS 的导入产物里烘焙了一串摘要（layeringSha256 / overlaySha256 /
/// request.bindingDigest / rootBindingsSha256 / catalogSha256 …），用来证明
/// "当前资产导出与当前编译器是同一次产物"。这在 CI 上极有价值，但它假定
/// **文件字节与导出时完全一致**（连 CRLF/LF 都算），而仓库里的 json 会被
/// git 的 `*.json text` 规则统一成 LF —— 于是加载时逐层校验失败，
/// GtaSzAlsPlayerHost._Ready() 抛异常 → RuntimeReady=false → 下车没有人。
///
/// 本开关只跳过"跨文件取证"的比较（消息里带 digest/sha256/stale/foreign/
/// provenance/belongs to another/bind the current 的那一类），
/// **结构与范围校验一律保留**（schema、节点数、图哈希、数值范围等）。
///
/// 默认关闭，行为与原来完全一致。打开方式：启动前设 ALS_SKIP_PROVENANCE=1。
/// </summary>
public static class AlsProvenancePolicy
{
    private static readonly bool Enabled = Read();

    private static readonly string[] Markers =
    {
        "provenance", "stale", "foreign", "digest", "sha256",
        "belongs to another", "bind the current",
    };

    private static readonly List<string> SkippedMessages = new();

    /// <summary>开关是否打开</summary>
    public static bool SkipEnabled => Enabled;

    /// <summary>已跳过的取证项（供宿主打印，便于排查）</summary>
    public static IReadOnlyList<string> Skipped
    {
        get { lock (SkippedMessages) return SkippedMessages.ToArray(); }
    }

    /// <summary>这条校验失败是否属于"跨文件取证"，且在开关打开时应降级为警告</summary>
    public static bool SkipFor(string message)
    {
        if (!Enabled) return false;
        foreach (var marker in Markers)
        {
            if (message.IndexOf(marker, StringComparison.OrdinalIgnoreCase) < 0) continue;
            lock (SkippedMessages) { if (SkippedMessages.Count < 64) SkippedMessages.Add(message); }
            return true;
        }
        return false;
    }

    private static bool Read()
    {
        var value = (Environment.GetEnvironmentVariable("ALS_SKIP_PROVENANCE") ?? string.Empty).Trim();
        return value is "1" or "true" or "TRUE" or "on" or "ON";
    }
}
