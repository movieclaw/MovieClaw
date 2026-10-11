"""生成 mpv sidecar 校验文件 (mpv-checksum.json)"""
import hashlib
import json
import os
import sys


def main():
    mpv_path = input("mpv.exe 路径: ").strip() if len(sys.argv) < 2 else sys.argv[1]

    if not os.path.exists(mpv_path):
        print(f"文件不存在: {mpv_path}")
        sys.exit(1)

    # SHA256
    h = hashlib.sha256()
    with open(mpv_path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    sha256 = h.hexdigest()

    # 版本 (从 PE 资源读取，Windows only)
    version = ""
    if sys.platform == "win32":
        try:
            import ctypes
            from ctypes import wintypes
            ver_dll = ctypes.WinDLL("version.dll")
            size = ver_dll.GetFileVersionInfoSizeW(mpv_path, None)
            if size:
                buf = ctypes.create_string_buffer(size)
                ver_dll.GetFileVersionInfoW(mpv_path, 0, size, buf)
                lplp = ctypes.c_void_p()
                uLen = wintypes.UINT()
                if ver_dll.VerQueryValueW(buf, "\\", ctypes.byref(lplp), ctypes.byref(uLen)):
                    import struct
                    ms = struct.unpack_from("<I", lplp.value, 8)[0]
                    ls = struct.unpack_from("<I", lplp.value, 12)[0]
                    version = f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
        except Exception:
            pass

    size = os.path.getsize(mpv_path)
    out_path = os.path.join(os.path.dirname(mpv_path), "mpv-checksum.json")
    data = {
        "file": "mpv.exe",
        "version": version,
        "sha256": sha256,
        "size": size,
    }
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2)

    print(f"SHA256: {sha256}")
    print(f"Version: {version or '(unknown)'}")
    print(f"Size: {size:,} bytes")
    print(f"输出: {out_path}")

if __name__ == "__main__":
    main()
