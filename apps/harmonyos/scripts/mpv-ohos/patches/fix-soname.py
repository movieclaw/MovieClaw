#!/usr/bin/env python3
"""libmpv.so SONAME 改写：libmpv.so.2 -> libmpv.so（跨平台纯 python，替代 patchelf --set-soname）。

meson 给 libmpv 设了版本化 SONAME（libmpv.so.2），但 HAP 只按 libmpv.so 打包，
运行时 NEEDED libmpv.so.2 解析不到会导致 NAPI 模块整体加载失败。
原理：SONAME 字符串存在 .dynstr 里，新名更短 → 原地覆写补零，文件大小不变。
"""

import sys

OLD = b"libmpv.so.2\x00"
NEW = b"libmpv.so\x00\x00\x00"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: fix-soname.py <libmpv.so>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as f:
        data = bytearray(f.read())

    count = data.count(OLD)
    if count == 0:
        # 可能已经是 libmpv.so（幂等重跑）
        if b"\x00libmpv.so\x00" in data:
            print("fix-soname: SONAME 已是 libmpv.so，跳过")
            return 0
        print("fix-soname: 未找到 libmpv.so.2（ SONAME 结构与预期不符），放弃", file=sys.stderr)
        return 1
    if count > 1:
        print("fix-soname: libmpv.so.2 出现 %d 次（期望 1 次），放弃" % count, file=sys.stderr)
        return 1

    idx = data.index(OLD)
    data[idx:idx + len(OLD)] = NEW
    with open(path, "wb") as f:
        f.write(data)
    print("fix-soname: SONAME libmpv.so.2 -> libmpv.so")
    return 0


if __name__ == "__main__":
    sys.exit(main())
