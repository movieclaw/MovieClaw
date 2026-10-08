#!/usr/bin/env python3
"""从正式 APK 读取版本、架构和签名，生成随 APK 一起发布/沿用的下载元数据。"""

import argparse
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path


def describe(apk: Path, aapt2: str, apksigner: str) -> dict:
    badging = subprocess.check_output([aapt2, "dump", "badging", str(apk)], text=True)
    package = re.search(r"^package: (.+)$", badging, re.MULTILINE)
    if not package:
        raise ValueError("无法读取 APK 包信息")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package[1]))
    if fields["name"] != "io.movieclaw.android" or "application-debuggable" in badging:
        raise ValueError("只允许发布 MovieClaw 正式 APK")
    if not re.fullmatch(r"\d+\.\d+\.\d+", fields["versionName"]):
        raise ValueError("Android versionName 必须为 X.Y.Z")
    if not 1 <= int(fields["versionCode"]) <= 2100000000:
        raise ValueError("Android versionCode 超出允许范围")
    sdk = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    if sdk is None:
        raise ValueError("APK 缺少最低 SDK 版本")
    with zipfile.ZipFile(apk) as archive:
        libraries = {n for n in archive.namelist() if n.startswith("lib/") and n.endswith(".so")}
    if {n.split("/")[1] for n in libraries} != {"arm64-v8a"}:
        raise ValueError("正式包必须包含 arm64-v8a 原生库")
    required = {
        "libmovieclaw_jni.so", "libmp2.so", "libc++_shared.so", "libavcodec.so",
        "libavformat.so", "libavfilter.so", "libavutil.so", "libswscale.so",
        "libswresample.so", "libavdevice.so",
    }
    missing = required - {Path(n).name for n in libraries}
    if missing:
        raise ValueError(f"APK 缺少播放器原生库：{sorted(missing)}")
    signature = subprocess.check_output(
        [apksigner, "verify", "--verbose", "--print-certs", str(apk)], text=True
    )
    certificate = re.search(r"Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]{64})", signature)
    if certificate is None or "CN=Android Debug" in signature:
        raise ValueError("APK 必须使用正式签名证书")
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "product": "android", "applicationId": fields["name"],
        "version": fields["versionName"], "build": fields["versionCode"],
        "arch": "arm64", "minimumSdk": int(sdk[1]), "asset": apk.name,
        "size": apk.stat().st_size, "sha256": digest, "signed": True,
        "certificateSha256": certificate[1].lower(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--apksigner", required=True)
    args = parser.parse_args()
    entry = describe(args.apk, args.aapt2, args.apksigner)
    args.apk.with_suffix(".json").write_text(json.dumps(entry, indent=2) + "\n")
    print(f"已校验正式 APK：Android {entry['version']} ({entry['build']})，{entry['arch']}")


if __name__ == "__main__":
    main()
