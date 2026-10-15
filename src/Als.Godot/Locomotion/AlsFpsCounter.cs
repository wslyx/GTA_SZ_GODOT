using Godot;

namespace GodotAls.Locomotion;

// Minimal on-screen FPS/frame-time HUD for stutter diagnosis. Built entirely in
// code like the boot overlay; the demo entry adds it for interactive starts so
// no scene file or fixture changes are needed.
public partial class AlsFpsCounter : CanvasLayer
{
    private Label _text = null!;
    private double _window;
    private int _frames;
    private double _worstMs;

    public override void _Ready()
    {
        Layer = 100; // Above the boot overlay and the demo HUD.

        var panel = new PanelContainer();
        panel.AddThemeStyleboxOverride("panel", new StyleBoxFlat
        {
            BgColor = new Color(0f, 0f, 0f, 0.55f),
            ContentMarginLeft = 8, ContentMarginRight = 8,
            ContentMarginTop = 4, ContentMarginBottom = 4,
            CornerRadiusTopRight = 4, CornerRadiusBottomRight = 4,
            CornerRadiusBottomLeft = 4, CornerRadiusTopLeft = 4,
        });
        AddChild(panel);
        // Bottom-left corner with an 8 px margin; grows up/right as the label
        // sizes itself and stays pinned there on window resize.
        panel.SetAnchorsAndOffsetsPreset(
            Control.LayoutPreset.BottomLeft, Control.LayoutPresetMode.KeepSize, 8);
        panel.GrowVertical = Control.GrowDirection.Begin;
        panel.GrowHorizontal = Control.GrowDirection.End;

        _text = new Label();
        _text.AddThemeFontSizeOverride("font_size", 14);
        _text.AddThemeColorOverride("font_color", new Color(0.85f, 0.95f, 1f));
        panel.AddChild(_text);
    }

    public override void _Process(double delta)
    {
        // Accumulate over half-second windows so the HUD text updates at a
        // readable rate while still exposing frame-time spikes via the worst
        // frame of each window.
        _window += delta;
        _frames++;
        var milliseconds = delta * 1000.0;
        if (milliseconds > _worstMs) _worstMs = milliseconds;
        if (_window < 0.5) return;

        var averageMs = _window / _frames * 1000.0;
        _text.Text = $"FPS {Engine.GetFramesPerSecond()}   平均帧 {averageMs:F1} ms   最差帧 {_worstMs:F1} ms";
        _window = 0;
        _frames = 0;
        _worstMs = 0;
    }
}
