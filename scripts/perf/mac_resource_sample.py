#!/usr/bin/env python3
"""Sample macOS process CPU deltas and physical footprint without attaching a profiler."""
import argparse
import ctypes
import json
import time


class Usage(ctypes.Structure):
    # rusage_info_v2, from the macOS SDK's sys/resource.h.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime", "child_user_time",
            "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
            "child_pageins", "child_elapsed_abstime", "diskio_bytesread",
            "diskio_byteswritten",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def cpu_percent(cpu_ticks, elapsed_ns, numer, denom):
    # proc_pid_rusage CPU times are Mach absolute ticks, not nanoseconds.
    return 100 * cpu_ticks * numer / denom / elapsed_ns


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--phase", default="idle")
    args = parser.parse_args()
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    timebase = Timebase()
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    if system.mach_timebase_info(ctypes.byref(timebase)):
        raise RuntimeError("mach_timebase_info failed")
    previous = None
    for _ in range(args.seconds + 1):
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)):
            raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
        now = time.monotonic_ns()
        cpu = usage.user_time + usage.system_time
        if previous:
            print(json.dumps({
                "t": now / 1e9, "phase": args.phase,
                "cpu_percent": cpu_percent(
                    cpu - previous[1], now - previous[0], timebase.numer, timebase.denom
                ),
                "cpu_timebase": [timebase.numer, timebase.denom],
                "footprint_mb": usage.phys_footprint / 1024**2,
                "resident_mb": usage.resident_size / 1024**2,
                "idle_wakeups": usage.pkg_idle_wkups - previous[2],
            }), flush=True)
        previous = now, cpu, usage.pkg_idle_wkups
        time.sleep(1)


if __name__ == "__main__":
    main()
