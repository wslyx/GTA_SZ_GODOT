using Godot;
using GodotAls.Animation;

namespace GodotAls.Locomotion;

// Bootstrap before instantiating the scene: child constructors assign process
// groups, so changing animation modes in the Demo's _Ready would be too late.
public partial class AlsDemoEntry : Node
{
    internal P4LocomotionDemo Demo { get; private set; } = null!;
    internal AlsSettingsMenu? SettingsMenu { get; private set; }
    internal Action<P4LocomotionDemo>? ConfigureBeforeReady { get; init; }

    private const string HeavyDemoScenePath = "res://scenes/demo/p4_locomotion_demo.tscn";
    private AlsBootOverlay? _bootOverlay;
    private bool _threadedBoot;
    private bool _attachPending;
    private PackedScene? _loadedScene;
    private System.Threading.Tasks.Task? _resourcePrewarm;
    private readonly System.Diagnostics.Stopwatch _bootClock = System.Diagnostics.Stopwatch.StartNew();

    public override void _Ready()
    {
        try
        {
            // Interactive starts (entry attached directly to the root window)
            // show a progress overlay and stream the heavy demo scene on a
            // background thread. Fixtures and headless runs — which need Demo
            // right after AddChild — keep the original synchronous path.
            if (GetParent() == GetTree().Root && DisplayServer.GetName() != "headless")
            {
                _bootOverlay = new AlsBootOverlay();
                AddChild(_bootOverlay);
                AddChild(new AlsFpsCounter());
                AlsAnimationRuntimeOptions.ConfigureDemo();
                // The refactored demo resources take ~20s to build on first use
                // inside the animation graph construction. Prebuild them on a
                // worker thread while the boot overlay stays interactive; the
                // later graph construction then reuses the finished Lazy value.
                if (AlsAnimationRuntimeOptions.Has("--refactored-stance-hosts"))
                    _resourcePrewarm = System.Threading.Tasks.Task.Run(
                        () => _ = AlsRefactoredDemoResources.Locomotion.Value);
                var requestError = ResourceLoader.LoadThreadedRequest(HeavyDemoScenePath, "PackedScene", true);
                if (requestError == Error.Ok) { _threadedBoot = true; return; }
                GD.PushWarning($"Threaded demo load unavailable ({requestError}); falling back to a synchronous start.");
                InitializeDemo(configureRuntime: false); // ConfigureDemo already ran.
                return;
            }
            InitializeDemo(configureRuntime: true);
        }
        catch (Exception exception)
        {
            GD.PushError($"ALS Demo initialization failed: {exception}");
            GetTree().Quit(1);
        }
    }

    public override void _Process(double delta)
    {
        // Deferred attach: the "initializing" overlay text gets one rendered
        // frame before the synchronous demo initialization blocks the main
        // thread, so the window never looks frozen mid-progress.
        if (_attachPending)
        {
            _attachPending = false;
            try
            {
                AttachDemo(_loadedScene!);
                _loadedScene = null;
                GD.Print($"ALS_BOOT_READY ms={_bootClock.ElapsedMilliseconds}");
                _ = DismissOverlayAsync();
            }
            catch (Exception exception)
            {
                GD.PushError($"ALS Demo initialization failed: {exception}");
                GetTree().Quit(1);
            }
            return;
        }
        if (!_threadedBoot) return;
        try
        {
            if (_loadedScene is null)
            {
                var progress = new Godot.Collections.Array();
                var status = ResourceLoader.LoadThreadedGetStatus(HeavyDemoScenePath, progress);
                if (status is ResourceLoader.ThreadLoadStatus.InvalidResource or ResourceLoader.ThreadLoadStatus.Failed)
                {
                    _threadedBoot = false;
                    GD.PushWarning($"Threaded demo load failed ({status}); falling back to a synchronous start.");
                    InitializeDemo(configureRuntime: false); // ConfigureDemo already ran.
                    return;
                }
                float reported = 0f;
                if (progress.Count > 0) reported = Mathf.Clamp(progress[progress.Count - 1].AsSingle(), 0f, 1f);
                _bootOverlay?.Report(reported);
                if (status != ResourceLoader.ThreadLoadStatus.Loaded) return;
                _loadedScene = (PackedScene?)ResourceLoader.LoadThreadedGet(HeavyDemoScenePath)
                    ?? throw new InvalidOperationException("ALS Demo scene is missing.");
                _bootOverlay?.Report(1f);
                _bootOverlay?.SetStatus("正在准备动画运行时…");
                return; // Keep pumping frames while the background prewarm runs.
            }
            if (_resourcePrewarm is { IsCompleted: false }) return; // Window stays interactive here.
            _threadedBoot = false;
            _bootOverlay?.SetStatus("正在初始化场景…");
            _attachPending = true; // Attach on the next frame so the overlay renders first.
        }
        catch (Exception exception)
        {
            _threadedBoot = false;
            GD.PushError($"ALS Demo initialization failed: {exception}");
            GetTree().Quit(1);
        }
    }

    private async System.Threading.Tasks.Task DismissOverlayAsync()
    {
        // Keep the overlay on screen for the first fully initialized frame.
        await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);
        _bootOverlay?.QueueFree();
        _bootOverlay = null;
    }

    // Original synchronous bootstrap, shared by fixtures, headless runs, and
    // the threaded-load fallback/finish paths.
    private void InitializeDemo(bool configureRuntime)
    {
        try
        {
            if (configureRuntime) AlsAnimationRuntimeOptions.ConfigureDemo();
            var scene = ResourceLoader.Load<PackedScene>(HeavyDemoScenePath)
                ?? throw new InvalidOperationException("ALS Demo scene is missing.");
            AttachDemo(scene);
        }
        catch (Exception exception)
        {
            GD.PushError($"ALS Demo initialization failed: {exception}");
            GetTree().Quit(1);
        }
    }

    private void AttachDemo(PackedScene scene)
    {
        Demo = scene.Instantiate<P4LocomotionDemo>();
        Demo.EnableNativeCamera = true;
        ConfigureBeforeReady?.Invoke(Demo);
        AddChild(Demo);
        if (Demo.IsRuntimeReady) AlsMantlingCourse.Add(Demo.GetNode<Node3D>("World"));
        // Interactive runs only: fixtures/headless must not get an Esc-handling
        // menu. Attached last so its _Input runs before the demo camera's
        // mouse-capture toggle.
        if (_bootOverlay is not null)
        {
            SettingsMenu = new AlsSettingsMenu { Entry = this };
            AddChild(SettingsMenu);
        }
    }

}
