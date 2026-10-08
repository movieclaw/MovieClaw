#!/usr/bin/env python3
"""从 Android TV 正式 APK 读取版本、架构和签名，生成随 APK 一起发布 / 沿用的下载元数据。

与手机版（apps/android/scripts/build-release-metadata.py）同一份契约，产品名 ``androidtv``；
电视盒子还有大量 32 位机器，正式包同时带 arm64-v8a 与 armeabi-v7a，
两种架构的 FFmpeg 音频解码与 libass 都必须在。
"""

import argparse
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

APPLICATION_ID = "io.movieclaw.androidtv"
ABIS = ("arm64-v8a", "armeabi-v7a")
REQUIRED_LIBRARIES = (
    "libffmpegJNI.so",
    "libavcodec.so",
    "libavutil.so",
    "libswresample.so",
    "libass.so",
    "libasskt.so",
    "libc++_shared.so",
)


def describe(apk: Path, aapt2: str, apksigner: str) -> dict:
    badging = subprocess.check_output([aapt2, "dump", "badging", str(apk)], text=True)
    package = re.search(r"^package: (.+)$", badging, re.MULTILINE)
    if not package:
        raise ValueError("无法读取 APK 包信息")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package[1]))
    if fields["name"] != APPLICATION_ID or "application-debuggable" in badging:
        raise ValueError("只允许发布 MovieClaw Android TV 正式 APK")
    if not re.fullmatch(r"\d+\.\d+\.\d+", fields["versionName"]):
        raise ValueError("Android TV versionName 必须为 X.Y.Z")
    if not 1 <= int(fields["versionCode"]) <= 2100000000:
        raise ValueError("Android TV versionCode 超出允许范围")
    sdk = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    if sdk is None:
        raise ValueError("APK 缺少最低 SDK 版本")
    with zipfile.ZipFile(apk) as archive:
        libraries = {n for n in archive.namelist() if n.startswith("lib/") and n.endswith(".so")}
    for abi in ABIS:
        present = {Path(n).name for n in libraries if n.split("/")[1] == abi}
        missing = set(REQUIRED_LIBRARIES) - present
        if missing:
            raise ValueError(f"APK 的 {abi} 缺少原生库：{sorted(missing)}")
    signature = subprocess.check_output(
        [apksigner, "verify", "--verbose", "--print-certs", str(apk)], text=True
    )
    # minSdk 23 的包带 v1 + v2 两种签名，apksigner 按方案逐行列出
    # （「V2 Signer: certificate SHA-256 digest」）；只有一种方案时是「Signer #1 …」
    certificate = re.search(
        r"(?:Signer #1|V2 Signer):? certificate SHA-256 digest: ([0-9a-fA-F]{64})", signature
    )
    if certificate is None or "CN=Android Debug" in signature:
        raise ValueError("APK 必须使用正式签名证书")
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "product": "androidtv",
        "applicationId": fields["name"],
        "version": fields["versionName"],
        "build": fields["versionCode"],
        "arch": "arm",
        "abis": list(ABIS),
        "minimumSdk": int(sdk[1]),
        "asset": apk.name,
        "size": apk.stat().st_size,
        "sha256": digest,
        "signed": True,
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
    abis = "+".join(entry["abis"])
    print(f"已校验正式 APK：Android TV {entry['version']} ({entry['build']})，{abis}")


if __name__ == "__main__":
    main()
