#!/usr/bin/env python3
"""Inspect actual release HAPs and sign/verify them before generating release metadata."""

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

BUNDLE = "io.movieclaw.HUAWEI"
ASSET = "MovieClaw-HarmonyOS.hap"


def inspect(hap):
    with zipfile.ZipFile(hap) as archive:
        app = json.loads(archive.read("module.json"))["app"]
        if app.get("bundleName") != BUNDLE:
            raise ValueError("HAP bundleName does not match MovieClaw")
        if app.get("debug") is not False or app.get("buildMode") != "release":
            raise ValueError("A debug HAP cannot be published")
        for name in ("movieclaw_mpv", "mpv", "movieclaw_z"):
            if f"libs/arm64-v8a/lib{name}.so" not in archive.namelist():
                raise ValueError(f"Missing ARM64 player library: {name}")
        return app


def run(command):
    # Sign tool diagnostics may contain signing material; do not copy them to public CI logs.
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(f"Signing/verification command failed: {Path(command[0]).name}")
    return result.stdout


def sign(hap, tools, output):
    inspect(hap)
    required = [
        "HARMONY_KEYSTORE_PATH",
        "HARMONY_CERT_PATH",
        "HARMONY_PROFILE_PATH",
        "HARMONY_KEY_ALIAS",
        "HARMONY_KEY_PASSWORD",
        "HARMONY_KEYSTORE_PASSWORD",
    ]
    for name in required:
        if not os.environ.get(name):
            raise ValueError(f"Missing signing configuration: {name}")
    java = str(Path(os.environ["JAVA_HOME"]) / "bin/java")
    signer = tools / "sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
    output.mkdir(parents=True, exist_ok=True)
    signed = output / ASSET
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        candidate = work / ASSET
        app = inspect(hap)
        run(
            [
                java,
                "-jar",
                str(signer),
                "sign-app",
                "-mode",
                "localSign",
                "-keyAlias",
                os.environ["HARMONY_KEY_ALIAS"],
                "-keyPwd",
                os.environ["HARMONY_KEY_PASSWORD"],
                "-keystorePwd",
                os.environ["HARMONY_KEYSTORE_PASSWORD"],
                "-keystoreFile",
                os.environ["HARMONY_KEYSTORE_PATH"],
                "-appCertFile",
                os.environ["HARMONY_CERT_PATH"],
                "-profileFile",
                os.environ["HARMONY_PROFILE_PATH"],
                "-signAlg",
                "SHA256withECDSA",
                "-compatibleVersion",
                str(app["minAPIVersion"]),
                "-inFile",
                str(hap),
                "-outFile",
                str(candidate),
            ]
        )
        run(
            [
                java,
                "-jar",
                str(signer),
                "verify-app",
                "-inFile",
                str(candidate),
                "-outCertChain",
                str(work / "certificate.cer"),
                "-outProfile",
                str(work / "profile.p7b"),
            ]
        )
        raw = run(
            [
                "openssl",
                "cms",
                "-verify",
                "-inform",
                "DER",
                "-noverify",
                "-in",
                str(work / "profile.p7b"),
            ]
        )
        profile = json.loads(raw)
        if (
            profile.get("type") != "release"
            or profile.get("bundle-info", {}).get("bundle-name") != BUNDLE
            or profile.get("issuer") == "pki_internal"
        ):
            raise ValueError("A Huawei release profile for the application is required")
        validity = profile["validity"]
        if not validity["not-before"] <= time.time() < validity["not-after"]:
            raise ValueError("Release profile is outside its validity period")
        # Only move a verified package into the directory that the workflow uploads.
        signed.write_bytes(candidate.read_bytes())
        inspect(signed)
        cert = run(["openssl", "x509", "-in", str(work / "certificate.cer"), "-outform", "DER"])
    entry = {
        "product": "harmony",
        "asset": ASSET,
        "applicationId": BUNDLE,
        "version": app["versionName"],
        "build": str(app["versionCode"]),
        "minimumSdk": app["minAPIVersion"],
        "arch": "arm64",
        "signed": True,
        "size": signed.stat().st_size,
        "sha256": hashlib.sha256(signed.read_bytes()).hexdigest(),
        "certificateSha256": hashlib.sha256(cert).hexdigest(),
    }
    signed.with_suffix(".json").write_text(json.dumps(entry, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["inspect", "sign"])
    parser.add_argument("hap", type=Path)
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    app = inspect(args.hap)
    expected = json.loads((Path(__file__).resolve().parents[2] / "AppScope/app.json5").read_text())[
        "app"
    ]
    if (app["versionName"], app["versionCode"]) != (
        expected["versionName"],
        expected["versionCode"],
    ):
        raise ValueError("Package version does not match AppScope/app.json5")
    if args.mode == "inspect":
        print(json.dumps(inspect(args.hap)))
    else:
        if args.tools is None or args.output is None:
            parser.error("sign requires --tools and --output")
        sign(args.hap, args.tools, args.output)


if __name__ == "__main__":
    main()
