using System;
using System.Runtime.InteropServices;

// 等待链遍历（WCT）: 打印某线程卡在等谁 —— 死锁定位
unsafe class Program
{
    [StructLayout(LayoutKind.Sequential)]
    struct WCT_NODE { public int Object; } // 占位,实际用指针数组

    [DllImport("advapi32.dll")]
    static extern IntPtr OpenThreadWaitChainSession(uint flags, IntPtr callback);
    [DllImport("advapi32.dll")]
    static extern void CloseThreadWaitChainSession(IntPtr session);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetThreadWaitChain(IntPtr session, IntPtr context, uint flags,
        uint threadId, ref uint nodeCount, [Out] IntPtr[] nodes, out bool isCycle);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenThread(uint access, bool inherit, uint tid);

    [StructLayout(LayoutKind.Sequential)]
    struct WAITCHAIN_NODE_INFO
    {
        public int ObjectType;     // WCT_OBJECT_TYPE
        public int ObjectStatus;   // WCT_OBJECT_STATUS
        public WAITCHAIN_NODE_INFO_DATA Data;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WAITCHAIN_NODE_INFO_DATA
    {
        public ulong ObjectA; // ObjectName ptr / ProcessId
        public ulong ObjectB; // ListPtr / ThreadId
    }

    const uint WCT_MAX_NODES = 32;
    const uint WCT_OUT_OF_CONTEXT = 1;

    static void Main(string[] args)
    {
        uint pid = uint.Parse(args[0]);
        uint tid = uint.Parse(args[1]);
        var session = OpenThreadWaitChainSession(0, IntPtr.Zero);
        var buf = Marshal.AllocHGlobal(32 * (int)WCT_MAX_NODES);
        var nodes = new IntPtr[1]; nodes[0] = buf;
        uint count = WCT_MAX_NODES;
        bool isCycle;
        // 目标线程本身必须先打开一个句柄放进 nodes[0]? 不需要 —— GetThreadWaitChain 直接查 tid
        uint flg = args.Length > 2 ? uint.Parse(args[2]) : WCT_OUT_OF_CONTEXT;
        bool ok = GetThreadWaitChain(session, IntPtr.Zero, flg,
            tid, ref count, buf, out isCycle);
        if (!ok) { Console.WriteLine("GetThreadWaitChain 失败 err=" + Marshal.GetLastWin32Error()); return; }
        Console.WriteLine($"链长 {count}, 环={isCycle}");
        for (int i = 0; i < count; i++)
        {
            var n = Marshal.PtrToStructure<WAITCHAIN_NODE_INFO>((IntPtr)((long)buf + i * 32));
            // ObjectType: 1=Thread 2=Process 3=COM 4=CriticalSection 5=Mutex 6=ALPC 7=Socket...
            string t = n.ObjectType switch { 1=>"线程", 2=>"进程", 4=>"临界区", 5=>"互斥体", 6=>"ALPC", 7=>"Socket", _=>"类型"+n.ObjectType };
            string s = n.ObjectStatus switch { 0=>"无", 1=>"空闲", 2=>"被挂", 3=>"等", _=>"状态"+n.ObjectStatus };
            Console.WriteLine($"  [{i}] {t} {s}  A=0x{n.Data.ObjectA:X} B=0x{n.Data.ObjectB:X}");
        }
        CloseThreadWaitChainSession(session);
    }
}
