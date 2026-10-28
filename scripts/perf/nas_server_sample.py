#!/usr/bin/env python3
"""容器内一次性只读采样：进程内存/CPU/IO、cgroup、NFS、网卡（docs/perf/nas-server-baseline-2026-10.md）。

只读 /proc 与 cgroup，不写盘、不常驻：隔 ``window`` 秒读两次做差分，打一行 JSON 就退出。
群晖内核 4.4 没有 smaps_rollup / RssAnon，自己累加 smaps。

用法（NAS 上，容器里没有 ps/top）::

    ssh nas '/usr/local/bin/docker exec -i movieclaw python3 - 60' \\
        < scripts/perf/nas_server_sample.py
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

WINDOW = float(sys.argv[1]) if len(sys.argv) > 1 else 30
HZ = os.sysconf("SC_CLK_TCK")


def _read(path: str) -> str:
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def _field(text: str, key: str) -> int:
    m = re.search(rf"^{key}:\s+(\d+)", text, re.M)
    return int(m.group(1)) if m else 0


def _smaps_sum(pid: str) -> str:
    acc: dict[str, int] = {}
    for line in _read(f"/proc/{pid}/smaps").splitlines():
        m = re.match(r"(Pss|Anonymous|Swap):\s+(\d+)", line)
        if m:
            acc[m.group(1)] = acc.get(m.group(1), 0) + int(m.group(2))
    return "\n".join(f"{k}: {v}" for k, v in acc.items())


def _procs() -> dict[str, dict]:
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        cmd = _read(f"/proc/{pid}/cmdline").replace("\0", " ").strip()
        if not cmd:
            continue
        stat = _read(f"/proc/{pid}/stat").rsplit(")", 1)[-1].split()
        status = _read(f"/proc/{pid}/status")
        smaps = _read(f"/proc/{pid}/smaps_rollup") or _smaps_sum(pid)
        io_lines = _read(f"/proc/{pid}/io").splitlines()
        io = dict(line.split(": ") for line in io_lines if ": " in line)
        out[pid] = {
            "cmd": cmd[:110],
            "cpu": int(stat[11]) + int(stat[12]) if len(stat) > 12 else 0,
            "rss": _field(status, "VmRSS"),
            "hwm": _field(status, "VmHWM"),
            "anon": _field(status, "RssAnon") or _field(smaps, "Anonymous"),
            "threads": _field(status, "Threads"),
            "pss": _field(smaps, "Pss"),
            "rchar": int(io.get("rchar", 0)),
            "write_bytes": int(io.get("write_bytes", 0)),
        }
    return out


def _cgroup() -> tuple[dict[str, int], int]:
    stat = {}
    for line in _read("/sys/fs/cgroup/memory/memory.stat").splitlines():
        key, value = line.split()
        stat[key] = int(value)
    return stat, int(_read("/sys/fs/cgroup/cpuacct/cpuacct.usage") or 0)


def _nfs() -> dict[str, dict[str, int]]:
    """每个 NFS 挂载 READ/WRITE/GETATTR 的累计次数、字节与 RTT/执行毫秒。"""
    res: dict[str, dict[str, int]] = {}
    mount = None
    for line in _read("/proc/self/mountstats").splitlines():
        if line.startswith("device"):
            m = re.match(r"device \S+ mounted on (\S+) with fstype nfs", line)
            mount = m.group(1) if m else None
            continue
        m = re.match(r"\s+(READ|WRITE|GETATTR|LOOKUP):\s+(.*)", line)
        if mount and m:
            f = [int(x) for x in m.group(2).split()]
            # ops trans timeouts bytes_sent bytes_recv queue rtt execute
            res[f"{mount}:{m.group(1)}"] = {
                "ops": f[0],
                "bytes": f[3] + f[4],
                "rtt": f[6],
                "exe": f[7],
            }
    return res


def _net() -> dict[str, tuple[int, int]]:
    out = {}
    for line in _read("/proc/net/dev").splitlines()[2:]:
        name, rest = line.split(":", 1)
        f = rest.split()
        out[name.strip()] = (int(f[0]), int(f[8]))
    return out


def main() -> None:
    p0, (_, cpu0), n0, e0, t0 = _procs(), _cgroup(), _nfs(), _net(), time.time()
    time.sleep(WINDOW)
    p1, (c1, cpu1), n1, e1, t1 = _procs(), _cgroup(), _nfs(), _net(), time.time()
    dt = t1 - t0
    procs = []
    for pid, b in p1.items():
        a = p0.get(pid, b)
        procs.append(
            {
                "pid": int(pid),
                "cmd": b["cmd"],
                "pss_mb": b["pss"] / 1024,
                "rss_mb": b["rss"] / 1024,
                "hwm_mb": b["hwm"] / 1024,
                "anon_mb": b["anon"] / 1024,
                "threads": b["threads"],
                "cpu_pct": (b["cpu"] - a["cpu"]) / HZ / dt * 100,
                "read_mb_s": (b["rchar"] - a["rchar"]) / dt / 1e6,
                "disk_write_kb_s": (b["write_bytes"] - a["write_bytes"]) / dt / 1e3,
            }
        )
    procs.sort(key=lambda r: -r["pss_mb"])
    nfs = {}
    for key, v in n1.items():
        u = n0.get(key, v)
        ops = v["ops"] - u["ops"]
        if ops:
            nfs[key] = {
                "ops_s": ops / dt,
                "mb_s": (v["bytes"] - u["bytes"]) / dt / 1e6,
                "rtt_ms": (v["rtt"] - u["rtt"]) / ops,
                "exe_ms": (v["exe"] - u["exe"]) / ops,
            }
    print(
        json.dumps(
            {
                "ts": time.strftime("%F %T"),
                "window_s": dt,
                "cgroup": {
                    "rss_mb": c1["total_rss"] / 2**20,
                    # 页缓存可回收：docker stats 的 MEM USAGE 含它，别当成泄漏
                    "cache_mb": c1["total_cache"] / 2**20,
                    "swap_mb": c1.get("total_swap", 0) / 2**20,
                    # 含短命子进程（健康探测、ffprobe）——与常驻进程之和的差就是它们
                    "cpu_pct": (cpu1 - cpu0) / 1e9 / dt * 100,
                },
                "net": {
                    k: {
                        "rx_mb_s": (v[0] - e0[k][0]) / dt / 1e6,
                        "tx_mb_s": (v[1] - e0[k][1]) / dt / 1e6,
                    }
                    for k, v in e1.items()
                    if k in e0 and k != "lo"
                },
                "nfs": nfs,
                "procs": procs,
            },
            ensure_ascii=False,
            default=lambda x: round(x, 2),
        )
    )


if __name__ == "__main__":
    main()
