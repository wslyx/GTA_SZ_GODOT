"""解析冻结进程的 minidump:每个线程的 RIP 落在哪个模块 + 等待状态。"""
from minidump.minidumpfile import MinidumpFile
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "tools/dumps/frozen2.dmp"
mdf = MinidumpFile.parse(path)
mdf.reader.move(0)

# 模块表
modules = []
for m in mdf.modules.modules:
    modules.append((m.baseaddress, m.size, m.name))

def which_module(addr):
    for base, size, name in modules:
        if base <= addr < base + size:
            short = name.replace("\\", "/").split("/")[-1]
            off = addr - base
            return "%s+0x%x" % (short, off)
    return "?? 0x%x" % addr

# 线程上下文
threads = mdf.threads.threads
print("线程总数:", len(threads))
results = []
for t in threads:
    tid = t.ThreadId
    ctx = None
    try:
        ctx = t.__dict__.get("ContextObject") or getattr(t, "ContextObject", None)
    except Exception:
        pass
    # minidump 库: t has .ThreadContext (location) — 用 reader 解析 CONTEXT
    # 直接用库的 get_thread_context 不可用时跳过
    results.append((tid, t, ctx))

# 尝试库自带的线程上下文解析
from minidump.thread_ex import ThreadInfo
count = 0
for tid, t, ctx in results:
    rip = None
    try:
        # minidump lib: t.ThreadContext is a _MINIDUMP_LOCATION_DESCRIPTOR
        # 用 reader 直接读 CONTEXT 结构 (x64: Rip at offset 0xF8)
        tc = t.ThreadContext
        r = mdf.reader
        r.move(tc.start_of_memory_range + 0xF8)
        import struct
        rip = struct.unpack("<Q", r.read(8))[0]
    except Exception as e:
        continue
    wait = getattr(t, "WaitReason", None)
    print("TID %-6d RIP在 %-40s wait=%s" % (tid, which_module(rip), wait))
    count += 1
print("已解析上下文线程:", count)
