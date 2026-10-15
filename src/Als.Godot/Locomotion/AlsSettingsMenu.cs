using Godot;

namespace GodotAls.Locomotion;

// Esc-toggled in-game settings menu for interactive runs. The demo entry
// attaches it as the last entry child, so its _Input runs before the orbit
// camera's: Esc opens/closes the menu without leaking into the camera's
// mouse-capture toggle, and while the menu is open camera look and
// click-to-capture are suspended so menu clicks are not stolen. Built entirely
// in code like AlsBootOverlay; anti-aliasing options apply live to the root
// viewport and last for the current session only.
public partial class AlsSettingsMenu : CanvasLayer
{
    private static readonly string[] MsaaLabels = ["关闭", "2× MSAA", "4× MSAA", "8× MSAA"];
    private static readonly string[] ScreenAaLabels = ["关闭", "FXAA", "SMAA"];

    internal AlsDemoEntry Entry { get; init; } = null!;

    private Control _root = null!;
    private OptionButton _msaa = null!;
    private OptionButton _screenAa = null!;
    private CheckButton _taa = null!;
    private bool _wasCaptured;

    public bool IsOpen => _root.Visible;

    public override void _Ready()
    {
        Layer = 30; // Above the switcher HUD (20) and the demo HUD.
        BuildUi();
    }

    public override void _Input(InputEvent @event)
    {
        if (!@event.IsActionPressed("mouse_capture_toggle", allowEcho: false)) return;
        GetViewport().SetInputAsHandled();
        if (IsOpen) Close();
        else Open();
    }

    private void Open()
    {
        var camera = Entry.Demo?.OrbitCamera;
        _wasCaptured = camera is not null && camera.IsMouseCaptured;
        if (camera is not null)
        {
            camera.InputEnabled = false; // Suspend mouse look + click-to-capture.
            camera.SetMouseCaptured(false);
        }
        SyncFromViewport();
        _root.Visible = true;
    }

    private void Close()
    {
        _root.Visible = false;
        var camera = Entry.Demo?.OrbitCamera;
        if (camera is null) return;
        camera.InputEnabled = true;
        if (_wasCaptured) camera.SetMouseCaptured(true);
    }

    private void SyncFromViewport()
    {
        var viewport = GetViewport();
        _msaa.Select((int)viewport.Msaa3D);
        _screenAa.Select((int)viewport.ScreenSpaceAA);
        _taa.SetPressedNoSignal(viewport.UseTaa);
    }

    private void BuildUi()
    {
        _root = new Control { Visible = false, MouseFilter = Control.MouseFilterEnum.Stop };
        _root.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        AddChild(_root);

        var dim = new ColorRect { Color = new Color(0f, 0f, 0f, 0.45f), MouseFilter = Control.MouseFilterEnum.Ignore };
        dim.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        _root.AddChild(dim);

        var center = new CenterContainer();
        center.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        _root.AddChild(center);

        var panel = new PanelContainer();
        panel.AddThemeStyleboxOverride("panel", new StyleBoxFlat
        {
            BgColor = new Color(0.07f, 0.09f, 0.13f, 0.97f),
            CornerRadiusTopLeft = 10, CornerRadiusTopRight = 10,
            CornerRadiusBottomLeft = 10, CornerRadiusBottomRight = 10,
            ContentMarginLeft = 28, ContentMarginRight = 28,
            ContentMarginTop = 22, ContentMarginBottom = 22,
        });
        center.AddChild(panel);

        var box = new VBoxContainer();
        box.AddThemeConstantOverride("separation", 14);
        panel.AddChild(box);

        var title = new Label { Text = "设置", HorizontalAlignment = HorizontalAlignment.Center };
        title.AddThemeFontSizeOverride("font_size", 24);
        title.AddThemeColorOverride("font_color", new Color(0.87f, 0.91f, 1f));
        box.AddChild(title);

        var grid = new GridContainer { Columns = 2 };
        grid.AddThemeConstantOverride("h_separation", 28);
        grid.AddThemeConstantOverride("v_separation", 10);
        box.AddChild(grid);

        AddOptionRow(grid, "MSAA (3D)", MsaaLabels, index => GetViewport().Msaa3D = (Viewport.Msaa)index, out _msaa);
        AddOptionRow(grid, "屏幕空间 AA", ScreenAaLabels, index => GetViewport().ScreenSpaceAA = (Viewport.ScreenSpaceAAEnum)index, out _screenAa);

        var taaLabel = new Label { Text = "TAA" };
        taaLabel.AddThemeFontSizeOverride("font_size", 15);
        grid.AddChild(taaLabel);
        _taa = new CheckButton { Text = "启用" };
        _taa.Toggled += pressed => GetViewport().UseTaa = pressed;
        grid.AddChild(_taa);

        var note = new Label
        {
            Text = "设置立即生效（仅当前会话）· SMAA/TAA 需要 Forward+ 渲染器",
            HorizontalAlignment = HorizontalAlignment.Center,
            AutowrapMode = TextServer.AutowrapMode.WordSmart,
            CustomMinimumSize = new Vector2(420, 0),
        };
        note.AddThemeFontSizeOverride("font_size", 13);
        note.AddThemeColorOverride("font_color", new Color(0.45f, 0.52f, 0.65f));
        box.AddChild(note);

        var closeRow = new CenterContainer();
        var close = new Button { Text = "关闭 (Esc)" };
        close.Pressed += Close;
        closeRow.AddChild(close);
        box.AddChild(closeRow);
    }

    private void AddOptionRow(GridContainer grid, string caption, string[] options, Action<long> apply, out OptionButton button)
    {
        var label = new Label { Text = caption };
        label.AddThemeFontSizeOverride("font_size", 15);
        grid.AddChild(label);
        button = new OptionButton();
        foreach (var option in options) button.AddItem(option);
        button.ItemSelected += index => apply(index);
        grid.AddChild(button);
    }
}
