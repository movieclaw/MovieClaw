"""Build a deterministic, dependency-free .mcplugin archive."""

import argparse
import hashlib
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
source = Path(__file__).parent
with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in (
        "movieclaw-plugin.toml",
        "watch_presence.py",
        "settings.html",
        "settings.js",
        "settings.css",
    ):
        info = zipfile.ZipInfo(name, date_time=(2026, 10, 12, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, (source / name).read_bytes())
print(args.output.name + " SHA256 " + hashlib.sha256(args.output.read_bytes()).hexdigest())
