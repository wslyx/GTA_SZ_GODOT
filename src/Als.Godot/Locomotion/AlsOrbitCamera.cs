using Godot;

namespace GodotAls.Locomotion;

public partial class AlsOrbitCamera : Node3D
{
    private Node3D? _target;
    private SpringArm3D? _springArm;
    private float _yaw;
    private float _pitch = -0.2f;
    private bool _captureRequested;

    [Export(PropertyHint.Range, "0.0005,0.02,0.0005")]
    public float MouseSensitivity { get; set; } = 0.0025f;

    public float MinimumPitch { get; } = Mathf.DegToRad(-70f);

    public float MaximumPitch { get; } = Mathf.DegToRad(25f);

    public float Yaw => _yaw;

    public float Pitch => _pitch;

    public Vector3 FollowOffset { get; } = new(0f, 0.53f, 0f);

    private float _aimBlend;

    /// <summary>
    /// 越肩瞄准（GTA 侧每帧设置：持枪且按住 aim 时为 true）。
    /// 生效时相机向**右**偏移并把视距拉近，让角色让出屏幕中心 —— 否则第三人称
    /// 角色正好顶在准星下面，瞄准射击时人挡着准星。
    /// 偏移量按 _aimBlend 平滑过渡（约 0.17s），松开 aim 回到正常跟随。
    /// </summary>
    public bool ShoulderAim { get; set; }

    /// <summary>越肩偏移的平滑系数（0=跟随 1=完全越肩）。</summary>
    public float AimBlend => _aimBlend;

    public Node3D? Target =>
        _target is not null && GodotObject.IsInstanceValid(_target)
            ? _target
            : null;

    public bool IsMouseCaptured { get; private set; }

    // False while the settings menu is open: suspends the _Input handlers below
    // (mouse look, click-to-capture, Esc capture toggle) without touching the
    // camera rig. Gameplay input polling elsewhere is unaffected.
    public bool InputEnabled { get; set; } = true;

    internal void UseNativeOutput()
    {
        _springArm!.ProcessMode = ProcessModeEnum.Disabled;
        var camera = GetNode<Camera3D>("SpringArm3D/Camera3D");
        camera.TopLevel = true;
        camera.KeepAspect = Camera3D.KeepAspectEnum.Width;
    }

    internal void UseOrbitOutput(Node3D target)
    {
        Configure(target);
        var camera = GetNode<Camera3D>("SpringArm3D/Camera3D");
        camera.TopLevel = false; camera.Transform = Transform3D.Identity;
        _springArm!.ProcessMode = ProcessModeEnum.Inherit;
        GlobalPosition = target.GlobalPosition + FollowOffset;
        ApplyOrbit();
    }

    public override void _Ready()
    {
        _springArm = GetNodeOrNull<SpringArm3D>("SpringArm3D")
            ?? throw new InvalidOperationException(
                "ALS orbit camera requires a SpringArm3D child named SpringArm3D.");
        ApplyOrbit();
        // Start with a visible cursor; capture begins only on a window click
        // (see _Input) or an explicit SetMouseCaptured call from a fixture.
        SetMouseCaptured(false);
    }

    public void Configure(Node3D target)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (!GodotObject.IsInstanceValid(target) || !target.IsInsideTree())
        {
            throw new InvalidOperationException("Orbit camera target must be a live scene node.");
        }
        _target = target;
    }

    public override void _Process(double delta)
    {
        // 越肩混合：偏移与视距都按同一系数平滑，避免切瞄准时的硬跳。
        _aimBlend = Mathf.MoveToward(_aimBlend, ShoulderAim ? 1f : 0f, (float)delta * 6f);
        if (_springArm is not null)
        {
            _springArm.SpringLength = Mathf.Lerp(SpringLengthNormal, SpringLengthAim, _aimBlend);
        }
        if (_target is not null && GodotObject.IsInstanceValid(_target))
        {
            // 右偏在**相机朝向空间**里做：yaw 转动时偏移方向跟着视线走。
            var right = GlobalTransform.Basis.X;
            GlobalPosition = _target.GlobalPosition + FollowOffset
                + right * (ShoulderLateral * _aimBlend);
        }
    }

    /// <summary>正常跟随视距（米）。</summary>
    public const float SpringLengthNormal = 4.2f;

    /// <summary>越肩瞄准视距（米）：拉近到肩后，准星更贴近枪口指向。</summary>
    public const float SpringLengthAim = 1.9f;

    /// <summary>越肩横向偏移（米，向右）。</summary>
    public const float ShoulderLateral = 0.55f;

    public override void _Input(InputEvent @event)
    {
        if (!InputEnabled) return;
        if (@event.IsActionPressed("mouse_capture_toggle"))
        {
            ToggleMouseCapture();
            GetViewport().SetInputAsHandled();
            return;
        }
        if (!IsMouseCaptured && @event is InputEventMouseButton { Pressed: true })
        {
            // Click-to-capture: the first click starts mouse look and must not
            // leak into gameplay actions polled later this frame (fire/aim).
            SetMouseCaptured(true);
            Input.ActionRelease("aim");
            GetViewport().SetInputAsHandled();
            return;
        }
        if (IsMouseCaptured && @event is InputEventMouseMotion mouseMotion)
        {
            ApplyMouseMotion(mouseMotion.Relative);
            GetViewport().SetInputAsHandled();
        }
    }

    // ⚠️ 参数按值传（不要用 in/ref/out 修饰）：Godot 的 C# 源生成器不会把带
    // 这些修饰符的方法暴露给 GDScript —— 深城纪宿主（main_game.gd）捕获鼠标
    // 后要从 GDScript 调本方法驱动环视，签名必须保持脚本互通。
    public void ApplyMouseMotion(Vector2 relative)
    {
        if (!float.IsFinite(relative.X) || !float.IsFinite(relative.Y) ||
            !float.IsFinite(MouseSensitivity) || MouseSensitivity <= 0f)
        {
            throw new ArgumentOutOfRangeException(nameof(relative),
                "Mouse motion and sensitivity must be finite and sensitivity must be positive.");
        }
        _yaw = Mathf.Wrap(_yaw - (relative.X * MouseSensitivity), -Mathf.Pi, Mathf.Pi);
        _pitch = Mathf.Clamp(
            _pitch - (relative.Y * MouseSensitivity),
            MinimumPitch,
            MaximumPitch);
        ApplyOrbit();
    }

    public void ToggleMouseCapture() => SetMouseCaptured(!IsMouseCaptured);

    // 直接设定视角（弧度）。P4 demo 由鼠标增量自然驱动 yaw/pitch；深城纪宿主
    // 在下车瞬间要把相机对齐到 CityWalk 记录的视线朝向，需要一次性设值入口。
    public void SetView(float yaw, float pitch)
    {
        _yaw = Mathf.Wrap(yaw, -Mathf.Pi, Mathf.Pi);
        _pitch = Mathf.Clamp(pitch, MinimumPitch, MaximumPitch);
        ApplyOrbit();
    }

    public void SetMouseCaptured(bool captured)
    {
        _captureRequested = captured;
        IsMouseCaptured = captured;
        Input.MouseMode = captured
            ? Input.MouseModeEnum.Captured
            : Input.MouseModeEnum.Visible;
    }

    public override void _Notification(int what)
    {
        switch (what)
        {
            case (int)NotificationWMWindowFocusOut:
                IsMouseCaptured = false;
                break;
            case (int)NotificationWMWindowFocusIn:
                IsMouseCaptured = _captureRequested;
                Input.MouseMode = _captureRequested
                    ? Input.MouseModeEnum.Captured
                    : Input.MouseModeEnum.Visible;
                break;
        }
    }

    private void ApplyOrbit()
    {
        Rotation = new Vector3(0f, _yaw, 0f);
        if (_springArm is not null)
        {
            _springArm.Rotation = new Vector3(_pitch, 0f, 0f);
        }
    }
}
