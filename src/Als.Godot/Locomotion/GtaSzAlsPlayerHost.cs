using Godot;
using GodotAls.Animation;
using GodotAls.Assets;
using GodotAls.Core.Contracts;
using GodotAls.Core.Locomotion;
using GodotAls.Dispatch;
using GodotAls.Import;
using GodotAls.Import.Compilation;
using System.Runtime;

namespace GodotAls.Locomotion;

// 深城纪（GTA_SZ_GODOT）的 ALS 玩家宿主。
//
// 与 P4LocomotionDemo 的差异：demo 宿主自带测试关卡（StartFloor / 坡道 / 楼梯 /
// 移动平台）与 HUD，而本宿主只承载角色运行时三件套 —— AlsP3CharacterSlot（角色）、
// AlsOrbitCamera（轨道相机）、AlsPlayerInputAdapter（输入）。地面与建筑碰撞由
// GTA 侧的 scripts/world/als_physics_ground.gd 提供的角色周围动态 StaticBody
// 代理负责，本宿主不做任何关卡几何。
//
// 模式衔接（由 main_game.gd 驱动）：
//   enter_world(feetWorldPos, dataYaw) —— 从载具下车时把角色放到车门落脚点；
//   exit_world()                        —— 上车/进观景时停用角色并把位置写回 CityWalk。
// 坐标约定：GTA 世界 = (east, y, -north)，yaw 为数据朝向（0=北），Godot 节点
// yaw = -数据 yaw（见 GTA 的 scripts/utils/coordinate_util.gd）。
public partial class GtaSzAlsPlayerHost : Node3D
{
    private const string ProfilePath = "res://assets/config/p4_cycle_locomotion_profile.json";
    private const string SettingsPath = "res://assets/config/p3_locomotion_settings.json";

    private AlsPlayerInputAdapter _playerInput = new();
    private AlsP3RuntimeContext _context = null!;
    private AlsP3CharacterSlot _slot = null!;
    private AlsOrbitCamera _orbitCamera = null!;
    private long _inputLifecycleRevision;
    private uint _inputLifecycleGeneration;
    private bool _runtimeConfigured;
    private bool _slotConfigured;
    private bool _failed;
    private string? _failure;

    /// <summary>角色当前是否受玩家控制（步行模式）。</summary>
    public bool Active { get; private set; }

    /// <summary>GDScript 侧直接引用的 overlay 常量（与 AlsOverlayKind 对齐）。</summary>
    public const int OverlayDefault = (int)AlsOverlayKind.Default;
    public const int OverlayRifle = (int)AlsOverlayKind.Rifle;
    public const int OverlayPistol2H = (int)AlsOverlayKind.Pistol2H;

    /// <summary>
    /// 当前请求的 overlay（持枪/持物姿态）。GTA 侧每帧按武器状态设置：
    /// 手枪 → Pistol2H，冲锋枪/霰弹枪 → Rifle，空手 → Default。
    /// 运行时据此驱动举枪 overlay 动画层**和**枪模 prop（AlsP3WorkerRoot 的
    /// Props.Capture 直接吃命令里的 RequestedOverlay）。
    /// ⚠️ 此前这里写死 AlsOverlayKind.Default，"aim" 只切 RotationMode.Aiming，
    /// 角色永远不举枪 —— 手枪瞄准姿态整个缺失（GTA化 §2.3 的 v1 待补项）。
    /// </summary>
    public AlsOverlayKind RequestedOverlay { get; set; } = AlsOverlayKind.Default;

    /// <summary>
    /// 越肩瞄准开关（透传 OrbitCamera.ShoulderAim）。
    /// GTA 侧：持枪且按住 aim（右键）时置 true —— 相机右移拉近，角色让出准星。
    /// </summary>
    public bool ShoulderAim
    {
        get => _orbitCamera is not null && _orbitCamera.ShoulderAim;
        set { if (_orbitCamera is not null) _orbitCamera.ShoulderAim = value; }
    }

    /// <summary>动画运行时资源是否就绪（资源加载失败时为 false，宿主静默降级）。</summary>
    public bool RuntimeReady => _runtimeConfigured && !_failed;

    /// <summary>失败原因（RuntimeReady 为 false 时供日志读取）。</summary>
    public string? Failure => _failure;

    /// <summary>马达（胶囊体）中心的世界坐标。</summary>
    public Vector3 MotorPosition => _slotConfigured && !_failed
        ? ((AlsCharacterMotor)_slot.ActiveCharacter.MovementAnchor).GlobalPosition
        : Vector3.Zero;

    /// <summary>马达水平速度（m/s，Godot 世界坐标即真实米制）。</summary>
    public float HorizontalSpeed
    {
        get
        {
            if (!_slotConfigured || _failed) return 0f;
            var velocity = ((AlsCharacterMotor)_slot.ActiveCharacter.MovementAnchor).Velocity;
            return new Vector2(velocity.X, velocity.Z).Length();
        }
    }

    /// <summary>轨道相机节点 yaw；GTA 数据 yaw = -ViewYaw。</summary>
    public float ViewYaw => _orbitCamera.Yaw;

    /// <summary>内存打点（性能优化方案 §7.7）：强制收一轮 GC 后报托管堆/工作集/提交量，
    /// 外加 Godot 原生资源记账（static）与显存（video），用于把 ALS 启动期的内存增量
    /// 拆成「Godot 资源 / 托管堆 / 非记账原生」三份。只允许在启动预热期调用。</summary>
    private static void PrintMemory(string label)
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        var managed = GC.GetTotalMemory(false) / 1048576.0;
        var stat = Godot.Performance.GetMonitor(Godot.Performance.Monitor.MemoryStatic) / 1048576.0;
        var video = Godot.RenderingServer.GetRenderingInfo(Godot.RenderingServer.RenderingInfo.VideoMemUsed) / 1048576.0;
        using var p = System.Diagnostics.Process.GetCurrentProcess();
        var ws = p.WorkingSet64 / 1048576.0;
        var priv = p.PrivateMemorySize64 / 1048576.0;
        GD.Print($"[ALS-MEM] {label} 托管={managed:F0}MB static={stat:F0}MB video={video:F0}MB 工作集={ws:F0}MB 提交={priv:F0}MB");
    }

    public override void _Ready()
    {
        // 启动性能归因：ALS 资产链（摘要校验 + 动画集编译）在大仓库里可能吃掉
        // 数十秒 —— 用秒表把每段耗时打出来（grep [ALS-T]）。
        var sw = System.Diagnostics.Stopwatch.StartNew();
        void Mark(string label)
        {
            PrintMemory(label);
            GD.Print($"[ALS-T] {label} {sw.ElapsedMilliseconds} ms");
            sw.Restart();
        }
        try
        {
            // 动画运行时选项必须在任何角色/图构造之前解析一次。
            AlsAnimationRuntimeOptions.ConfigureDemo();
            Mark("运行时选项");
            _slot = new AlsP3CharacterSlot { Name = "CharacterSlot" };
            AddChild(_slot);
            _orbitCamera = new AlsOrbitCamera { Name = "OrbitCamera" };
            var springArm = new SpringArm3D
            {
                Name = "SpringArm3D",
                SpringLength = 4.2f,
                Margin = 0.2f,
            };
            var camera = new Camera3D { Name = "Camera3D", Fov = 70f, Current = false };
            springArm.AddChild(camera);
            _orbitCamera.AddChild(springArm);
            AddChild(_orbitCamera);

            var animationSetResource = ResourceLoader.Load<AlsAnimationSetResource>(
                AlsGodotImportCoordinator.CompiledResourcePath)
                ?? throw new InvalidOperationException("ALS compiled animation set resource is missing.");
            Mark("加载编译资源 tres");
            var animationSet = animationSetResource.LoadDefinition();
            Mark("LoadDefinition（含摘要链）");
            var profile = AlsLocomotionProfileCompiler.Compile(
                Godot.FileAccess.GetFileAsString(ProfilePath), animationSet);
            Mark("运动轮廓编译");
            var settings = AlsLocomotionSettings.Load(
                Godot.FileAccess.GetFileAsString(SettingsPath));
            var motorSettings = CreateMotorSettings(settings);
            _context = new AlsP3RuntimeContext(
                AlsHarnessMode.Parallel,
                settings,
                motorSettings,
                animationSet,
                profile,
                System.Environment.CurrentManagedThreadId,
                headlessOrDebug: OS.IsDebugBuild());
            Mark("运行时上下文构造");
            // 自动布娃娃环境：GTA 主场景没有 demo 的 World 节点，交给宿主父级（城市根）。
            _context.AutomaticRagdollEnvironment = GetParent() as Node ?? this;
            _runtimeConfigured = true;
            var skipped = GodotAls.Import.Compilation.AlsProvenancePolicy.Skipped;
            if (skipped.Count > 0)
            {
                GD.Print($"[ALS] 已跳过 {skipped.Count} 项导出取证校验（ALS_SKIP_PROVENANCE=1，结构与范围校验仍在跑）");
                foreach (var message in skipped) GD.Print($"    - {message}");
            }
        }
        catch (Exception exception)
        {
            Fail(exception);
        }
    }

    /// <summary>进入步行模式：把角色放到 dataYaw 视线朝向的落脚点并激活。</summary>
    public void EnterWorld(Vector3 feetWorldPosition, float dataYaw)
    {
        if (_failed || !_runtimeConfigured)
        {
            GD.Print($"[ALS] EnterWorld 跳过（failed={_failed} runtimeConfigured={_runtimeConfigured}）");
            return;
        }
        GD.Print($"[ALS] EnterWorld feet={feetWorldPosition} yaw={dataYaw} 首次配置={!_slotConfigured}");
        var enterSw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            var capsuleCenter = feetWorldPosition + Vector3.Up * (_context.MotorSettings.StandingHeight * 0.5f);
            if (!_slotConfigured)
            {
                // 首次下车：此刻才构造角色（图与角色资源已随 _Ready 预热）。
                var cfgSw = System.Diagnostics.Stopwatch.StartNew();
                _slot.Configure(_context, () => _playerInput, capsuleCenter);
                _slotConfigured = true;
                enterSw.Restart();
                // 预热收尾：编译期 69MB 原始动画解析在 LOH 留下大量碎片，.NET 不会
                // 主动归还 OS —— 压缩 LOH + 激进回收一次（性能优化方案 §7.7）。
                PrintMemory("slot.Configure 后（压缩前）");
                GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                GC.Collect(2, GCCollectionMode.Aggressive, true, true);
                PrintMemory("slot.Configure 后（压缩后）");
                GD.Print($"[ALS-T] slot.Configure {cfgSw.ElapsedMilliseconds} ms");
            }
            else
            {
                // 再次下车：角色停用期间直接搬马达并清速度。
                var motor = (AlsCharacterMotor)_slot.ActiveCharacter.MovementAnchor;
                motor.GlobalPosition = capsuleCenter;
                motor.Velocity = Vector3.Zero;
            }
            var active = _slot.ActiveCharacter;
            if (!active.LifecycleDiagnostics.IsActive) active.SetActive(true);
            _slot.ActiveCharacter.Visible = true;
            _slot.ProcessMode = ProcessModeEnum.Inherit;
            _orbitCamera.Configure(active.MovementAnchor);
            // GTA 数据 yaw（0=北）→ Godot 节点 yaw 取负。
            _orbitCamera.SetView(-dataYaw, -0.2f);
            _orbitCamera.GetNode<Camera3D>("SpringArm3D/Camera3D").Current = true;
            Active = true;
            GD.Print($"[ALS] EnterWorld 完成（角色已激活，轨道相机接管）{enterSw.ElapsedMilliseconds} ms");
        }
        catch (Exception exception)
        {
            Fail(exception);
        }
    }

    /// <summary>离开步行模式：停用角色、让出相机。位置由调用方先读走。</summary>
    public void ExitWorld()
    {
        if (!Active || _failed || !_slotConfigured)
        {
            return;
        }
        GD.Print("[ALS] ExitWorld（角色停用，相机交还追尾）");
        Active = false;
        _slot.ActiveCharacter.SetActive(false);
        _slot.ActiveCharacter.Visible = false;
        _slot.ProcessMode = ProcessModeEnum.Disabled;
        _orbitCamera.GetNode<Camera3D>("SpringArm3D/Camera3D").Current = false;
        if (Input.MouseMode == Input.MouseModeEnum.Captured)
        {
            Input.MouseMode = Input.MouseModeEnum.Visible;
        }
    }

    public override void _PhysicsProcess(double delta)
    {
        if (_failed || !Active || !_runtimeConfigured || !_slotConfigured)
        {
            return;
        }
        try
        {
            var active = _slot.ActiveCharacter;
            SynchronizeInputLifecycle();
            if (!active.LifecycleDiagnostics.IsActive) return;
            var nextFrame = active.PublishedFrameId + 1;
            if (_playerInput.CapturedFrameId < nextFrame)
            {
                _playerInput.CaptureGodotFrame(
                    new AlsFrameIdentity(nextFrame, active.Handle.CharacterId, active.Handle.Generation),
                    _orbitCamera.Yaw,
                    _orbitCamera.Pitch,
                    RequestedOverlay);
            }
        }
        catch (Exception exception)
        {
            Fail(exception);
        }
    }

    public override void _ExitTree()
    {
        if (GodotThread.IsMainThread() && _slotConfigured && !_failed)
        {
            _slot.DisposeRuntime();
        }
    }

    private void SynchronizeInputLifecycle()
    {
        var active = _slot.ActiveCharacter;
        if (_inputLifecycleGeneration == active.Handle.Generation &&
            _inputLifecycleRevision == active.AnimationLifecycleRevision)
        {
            return;
        }
        if (active.AnimationLifecycleRevision != 0)
        {
            _playerInput.DiscardUnpublishedActions(active.PublishedFrameId);
        }
        _inputLifecycleGeneration = active.Handle.Generation;
        _inputLifecycleRevision = active.AnimationLifecycleRevision;
    }

    // 与 P4LocomotionDemo.CreateMotorSettings 相同的生产参数。
    private static AlsMotorSettings CreateMotorSettings(AlsLocomotionSettings settings) => new(
        0.35f,
        settings.StandingHalfHeight * 2f,
        settings.CrouchedHalfHeight * 2f,
        settings.Standing,
        settings.Crouching,
        settings.InitialMaxAcceleration,
        settings.InitialMaxBrakingDeceleration,
        settings.Gravity,
        settings.JumpSpeed,
        1,
        settings.VelocityAngleInterpolationStart,
        settings.VelocityAngleInterpolationEnd);

    private void Fail(Exception exception)
    {
        if (_failed)
        {
            return;
        }
        _failed = true;
        var message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
        _failure = $"{exception.GetType().Name}: {message}";
        // [ALS] 前缀便于 grep；堆栈首行一起打（定位抛出点）
        var stackTop = (exception.StackTrace ?? "").Split('\n');
        var firstFrame = stackTop.Length > 0 ? stackTop[0].Trim() : "";
        GD.PushError($"[ALS] player host failed: {_failure} @ {firstFrame}");
    }
}
