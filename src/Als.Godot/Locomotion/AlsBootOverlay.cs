using Godot;

namespace GodotAls.Locomotion;

// Interactive startup overlay: project title, status text, and a progress bar
// fed by the threaded demo-scene load. Built entirely in code so no scene file
// or fixture changes are needed; the demo entry adds and frees it.
public partial class AlsBootOverlay : CanvasLayer
{
    private const float BarSpeed = 0.85f; // Progress units per second while smoothing.

    private ProgressBar _progress = null!;
    private Label _status = null!;
    private float _target;

    public override void _Ready()
    {
        // Keep the cursor visible and usable for the whole startup; the orbit
        // camera re-captures it only after the demo scene finishes attaching.
        Input.MouseMode = Input.MouseModeEnum.Visible;

        var background = new ColorRect { Color = new Color(0.043f, 0.051f, 0.071f) };
        background.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        AddChild(background);

        var center = new CenterContainer();
        center.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        AddChild(center);

        var box = new VBoxContainer();
        box.AddThemeConstantOverride("separation", 16);
        center.AddChild(box);

        var title = new Label { Text = "GODOT ALS", HorizontalAlignment = HorizontalAlignment.Center };
        title.AddThemeFontSizeOverride("font_size", 42);
        title.AddThemeColorOverride("font_color", new Color(0.87f, 0.91f, 1f));
        box.AddChild(title);

        _status = new Label { Text = "正在加载演示场景…", HorizontalAlignment = HorizontalAlignment.Center };
        _status.AddThemeFontSizeOverride("font_size", 15);
        _status.AddThemeColorOverride("font_color", new Color(0.65f, 0.72f, 0.85f));
        box.AddChild(_status);

        _progress = new ProgressBar
        {
            MinValue = 0, MaxValue = 1, Value = 0, ShowPercentage = false,
            CustomMinimumSize = new Vector2(420, 8),
        };
        _progress.AddThemeStyleboxOverride("background", new StyleBoxFlat
        {
            BgColor = new Color(0.12f, 0.14f, 0.19f),
            CornerRadiusTopLeft = 4, CornerRadiusTopRight = 4,
            CornerRadiusBottomLeft = 4, CornerRadiusBottomRight = 4,
        });
        _progress.AddThemeStyleboxOverride("fill", new StyleBoxFlat
        {
            BgColor = new Color(0.34f, 0.62f, 1f),
            CornerRadiusTopLeft = 4, CornerRadiusTopRight = 4,
            CornerRadiusBottomLeft = 4, CornerRadiusBottomRight = 4,
        });
        box.AddChild(_progress);

        var tip = new Label
        {
            Text = "加载期间不捕获鼠标；进入场景后点击画面开始游戏，按 Esc 释放",
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        tip.AddThemeFontSizeOverride("font_size", 13);
        tip.AddThemeColorOverride("font_color", new Color(0.45f, 0.52f, 0.65f));
        box.AddChild(tip);
    }

    // Feed the latest threaded-load progress (0..1). Displayed value is smoothed.
    public void Report(float value)
    {
        _target = Mathf.Clamp(value, 0f, 1f);
    }

    // The threaded load finished; the remaining work happens synchronously in
    // the demo entry's _Ready, so fill the bar and swap the status text now.
    public void SetStatus(string text)
    {
        _target = 1f;
        _progress.Value = 1;
        _status.Text = text;
    }

    public override void _Process(double delta)
    {
        // Hard guarantee while loading: nothing may capture the cursor until
        // the overlay is dismissed and the user clicks the running scene.
        Input.MouseMode = Input.MouseModeEnum.Visible;
        if ((float)_progress.Value >= _target) return;
        _progress.Value = Mathf.MoveToward((float)_progress.Value, _target, (float)delta * BarSpeed);
    }
}
