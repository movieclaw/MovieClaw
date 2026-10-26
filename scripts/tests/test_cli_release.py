"""CLI 附件命名契约，以及真实下载、校验、解压和安装流程。"""

import fnmatch
import hashlib
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CliReleaseTest(unittest.TestCase):
    def test_six_platform_archive_names_match_upload_and_publish(self):
        config = (ROOT / "cli/.goreleaser.yaml").read_text()
        template = re.search(r'- name_template: "([^"]+)"', config)[1]
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        upload_patterns = re.findall(r"cli/dist/(\S+)", workflow)
        required = re.search(r'required="([^"]+)"', workflow)[1].split()
        windows = (ROOT / "scripts/install-cli.ps1").read_text()
        windows_template = re.search(r'\$asset = "([^"]+)"', windows)[1]
        for system in ("linux", "darwin", "windows"):
            for arch in ("amd64", "arm64"):
                with self.subTest(system=system, arch=arch):
                    extension = "zip" if system == "windows" else "tar.gz"
                    expected = f"mclaw_cli_{system}_{arch}.{extension}"
                    actual = template.replace("{{ .Os }}", system).replace("{{ .Arch }}", arch)
                    self.assertEqual(f"{actual}.{extension}", expected)
                    self.assertIn(expected, required)
                    self.assertTrue(any(fnmatch.fnmatch(expected, p) for p in upload_patterns))
                    if system == "windows":
                        self.assertEqual(windows_template.replace("$arch", arch), expected)

    def test_unix_install_from_release_archive(self):
        for system in ("Linux", "Darwin"):
            for machine, arch in (("x86_64", "amd64"), ("arm64", "arm64")):
                for version in ("latest", "v0.0.0"):
                    with self.subTest(system=system, arch=arch, version=version):
                        self.install_archive(system, machine, arch, version)

    def test_install_from_legacy_release_archive(self):
        for version in ("latest", "v0.0.0"):
            with self.subTest(version=version):
                self.install_archive("Linux", "x86_64", "amd64", version, legacy=True)

    def install_archive(self, system, machine, arch, version, *, legacy=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            suffix = "latest/download" if version == "latest" else f"download/{version}"
            release = root / "releases" / suffix
            release.mkdir(parents=True)
            binary = root / "mclaw"
            binary.write_text("#!/bin/sh\nprintf 'mclaw version 0.0.0\\n'\n")
            binary.chmod(0o755)
            prefix = "mclaw" if legacy else "mclaw_cli"
            asset = f"{prefix}_{system.lower()}_{arch}.tar.gz"
            archive = release / asset
            with tarfile.open(archive, "w:gz") as package:
                package.add(binary, arcname="mclaw")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            (release / "checksums.txt").write_text(f"{checksum}  {asset}\n")
            tools = root / "bin"
            tools.mkdir()
            uname = tools / "uname"
            uname.write_text(
                f'#!/bin/sh\ncase "$1" in -s) echo {system};; -m) echo {machine};; esac\n'
            )
            # 仅将安装落点重定向到临时目录，不改实际安装脚本。
            move = tools / "mv"
            move.write_text(
                f'#!/bin/sh\nexec "{shutil.which("mv")}" "$1" "$CLI_TEST_INSTALL/mclaw"\n'
            )
            uname.chmod(0o755)
            move.chmod(0o755)
            installed = root / "installed"
            installed.mkdir()
            result = subprocess.run(
                ["/bin/sh", str(ROOT / "scripts/install-cli.sh")],
                env={
                    **os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "LC_ALL": "C",
                    "MOVIECLAW_CLI_VERSION": version,
                    "MOVIECLAW_DOWNLOAD_BASE": (root / "releases").as_uri(),
                    "CLI_TEST_INSTALL": str(installed),
                },
                capture_output=True, text=True, errors="replace", timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("✓ 校验和通过", result.stdout, result.stderr)
            self.assertEqual(
                subprocess.check_output([str(installed / "mclaw"), "--version"], text=True),
                "mclaw version 0.0.0\n",
            )


if __name__ == "__main__":
    unittest.main()
