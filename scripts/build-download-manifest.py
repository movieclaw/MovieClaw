#!/usr/bin/env python3
"""从发行 ZIP / APK 生成官网 downloads.json；沿用旧包时保留真实版本。

用法：python3 scripts/build-download-manifest.py --tag v0.32.0 --directory dist/downloads
在 macOS 上会额外复核 Developer ID 签名及公证，供官网按实际结果展示。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def architecture(binary: bytes) -> str:
    """读取 Mach-O 主程序的切片，不根据 ZIP 文件名猜测芯片。"""
    magic = binary[:4]
    if magic in (
        b"\xca\xfe\xba\xbe",
        b"\xca\xfe\xba\xbf",
        b"\xbe\xba\xfe\xca",
        b"\xbf\xba\xfe\xca",
    ):
        endian = ">" if magic[:1] == b"\xca" else "<"
        count = struct.unpack_from(endian + "I", binary, 4)[0]
        stride = 32 if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
        cpus = {struct.unpack_from(endian + "I", binary, 8 + i * stride)[0] for i in range(count)}
    elif magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        cpus = {struct.unpack_from(("<" if magic[0] == 0xCF else ">") + "I", binary, 4)[0]}
    else:
        raise ValueError("主程序不是支持的 64 位 Mach-O")
    names = {0x0100000C: "arm64", 0x01000007: "x86_64"}
    if not cpus or cpus - names.keys():
        raise ValueError(f"不支持的 Mach-O 芯片：{cpus}")
    return "universal" if len(cpus) == 2 else names[next(iter(cpus))]


def verification(archive: Path, app_path: str) -> tuple[bool | None, bool | None]:
    if sys.platform != "darwin":
        return None, None
    with tempfile.TemporaryDirectory(prefix="movieclaw-download-") as tmp:
        # ditto 保留 Bundle 中的符号链接和权限；不使用 zipfile.extractall。
        subprocess.run(["ditto", "-x", "-k", str(archive), tmp], check=True)
        app = str(Path(tmp) / app_path)
        details = subprocess.run(
            ["codesign", "-dv", "--verbose=4", app], capture_output=True, text=True
        )
        valid = subprocess.run(
            ["codesign", "--verify", "--strict", "--deep", app], capture_output=True
        )
        signed = valid.returncode == 0 and "Authority=Developer ID Application:" in details.stderr
        notarized = (
            signed
            and subprocess.run(
                ["xcrun", "stapler", "validate", app],
                capture_output=True,
            ).returncode
            == 0
        )
        return signed, notarized


def describe(archive: Path) -> dict:
    with zipfile.ZipFile(archive) as z:
        plists = [n for n in z.namelist() if re.fullmatch(r"[^/]+\.app/Contents/Info\.plist", n)]
        if len(plists) != 1:
            raise ValueError(f"{archive.name} 必须只包含一个顶层 App")
        info = plistlib.loads(z.read(plists[0]))
        product = {"io.movieclaw.app": "mac", "com.movieclaw.transcoder": "transcoder"}.get(
            info["CFBundleIdentifier"]
        )
        if not product:
            raise ValueError(f"未知 App：{info['CFBundleIdentifier']}")
        app_path = plists[0].removesuffix("/Contents/Info.plist")
        binary = z.read(f"{app_path}/Contents/MacOS/{info['CFBundleExecutable']}")
        entry = {
            "product": product,
            "version": str(info["CFBundleShortVersionString"]),
            "build": str(info["CFBundleVersion"]),
            "arch": architecture(binary),
            "minimumSystemVersion": str(info["LSMinimumSystemVersion"]),
            "asset": archive.name,
            "size": archive.stat().st_size,
        }
    with archive.open("rb") as f:
        entry["sha256"] = hashlib.file_digest(f, "sha256").hexdigest()
    for field in ("version", "minimumSystemVersion"):
        if not re.fullmatch(r"\d+(?:\.\d+){1,3}", entry[field]):
            raise ValueError(f"{archive.name} 的 {field} 不合法：{entry[field]}")
    entry["signed"], entry["notarized"] = verification(archive, app_path)
    return entry


def describe_android(
    apk: Path, product: str = "android", application_id: str = "io.movieclaw.android",
    arch: str = "arm64",
) -> dict:
    # 元数据由 Android runner 的 aapt2 / apksigner 从实际 APK 生成；沿用时一起复制。
    # publish 的 macOS runner 不需要再安装 Android SDK，先校验元数据绑定的包未改变。
    # Android TV 是独立 App（product androidtv），同一份契约；它同时带 64 / 32 位，arch 记 arm。
    entry = json.loads(apk.with_suffix(".json").read_text())
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if (entry.get("asset"), entry.get("size"), entry.get("sha256")) != (
        apk.name, apk.stat().st_size, digest
    ):
        raise ValueError(f"{apk.name} 与 Android 下载元数据不一致")
    if (
        entry.get("product") != product
        or entry.get("applicationId") != application_id
        or entry.get("arch") != arch
        or entry.get("signed") is not True
        or not re.fullmatch(r"\d+\.\d+\.\d+", entry.get("version", ""))
        or not re.fullmatch(r"[0-9a-f]{64}", entry.get("certificateSha256", ""))
        or not 1 <= int(entry.get("build", "0")) <= 2100000000
        or not isinstance(entry.get("minimumSdk"), int)
    ):
        raise ValueError(f"{apk.name} 的 Android 下载元数据不合法")
    return entry


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[\w.-]+)?", args.tag):
        parser.error("tag 必须是应用 Release 的 vX.Y.Z")
    packages = [describe(p) for p in sorted(args.directory.glob("MovieClaw*-macos-*.zip"))]
    packages += [
        describe_android(p) for p in sorted(args.directory.glob("MovieClaw-Android-*.apk"))
    ]
    packages += [
        describe_android(p, "androidtv", "io.movieclaw.androidtv", "arm")
        for p in sorted(args.directory.glob("MovieClaw-AndroidTV.apk"))
    ]
    manifest = {"schema": 1, "release": args.tag, "packages": packages}
    output = args.directory / "downloads.json"
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"已生成 {output}（{len(packages)} 个安装包）")


if __name__ == "__main__":
    main()
