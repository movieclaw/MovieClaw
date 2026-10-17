"""插件的第三方依赖：锁文件与主程序自带包清单（docs/design/plugin-dependencies.md）。

::

    python -m movieclaw_sdk.deps constraints > host-constraints.txt   # 主程序自带的包与版本
    python -m movieclaw_sdk.deps lock <插件目录>                       # requirements.in → 锁文件
    python -m movieclaw_sdk.deps check <插件目录>                      # 校验锁文件

锁文件是 pip 的 requirements 格式（安装时原样交给 ``pip install --require-hashes``），每个包上方用
``#>`` 注释行列出它的每个轮子（文件名、字节数、sha256）——批准页的「多大、有没有本机代码」从这里读，
不用先下载；pip 把这些行当注释跳过::

    # python: 3.12
    #> lz4-4.4.4-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl 1289012 sha256:…
    lz4==4.4.4 \\
        --hash=sha256:…

规则：全部 ``==`` 钉死、每个包带 ``--hash``、只接受轮子（用户机器上不编译）、
不能与主程序已有的包重名。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import tomllib
import urllib.request
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from functools import cached_property
from importlib import metadata
from pathlib import Path

from packaging import tags as _tags
from packaging.utils import InvalidWheelFilename, canonicalize_name, parse_wheel_filename

MANIFEST = "movieclaw-plugin.toml"
REQUIREMENTS = "requirements.in"
DEFAULT_INDEX = "https://pypi.org/simple"
TSINGHUA_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple"
#: 每个服务器版本随发版附带一份（docs/design/plugin-dependencies.md §1）
CONSTRAINTS_URL = (
    "https://github.com/movieclaw/MovieClaw/releases/latest/download/host-constraints.txt"
)
#: 打包时至少要覆盖的平台（镜像是这两种架构）
TARGETS = ("linux/amd64", "linux/arm64")
_ARCH = {"linux/amd64": "x86_64", "linux/arm64": "aarch64"}
#: 镜像的 glibc（python:3.12-slim-bookworm = Debian 12 = glibc 2.36）
_GLIBC = (2, 36)

_REQ = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(===|==|~=|!=|>=|<=|>|<)?\s*(\S*)$"
)
_HASH = re.compile(r"^--hash=sha256:([0-9a-f]{64})$")
_HEADER = re.compile(r"^#\s*(python|index):\s*(\S+)\s*$")


class LockError(ValueError):
    """锁文件不合规：原因直接给用户看。"""


@dataclass(frozen=True)
class Wheel:
    filename: str
    size: int | None
    sha256: str

    @cached_property
    def tags(self) -> frozenset[_tags.Tag]:
        return parse_wheel_filename(self.filename)[3]

    @property
    def native(self) -> bool:
        return any(t.abi != "none" or t.platform != "any" for t in self.tags)


@dataclass(frozen=True)
class Locked:
    name: str
    """规范化的包名（PEP 503）。"""
    version: str
    hashes: tuple[str, ...]
    wheels: tuple[Wheel, ...]

    @property
    def native(self) -> bool:
        """含本机代码：任何一个轮子不是纯 Python。"""
        return any(w.native for w in self.wheels)

    def pick(self, supported: Iterable[_tags.Tag]) -> Wheel | None:
        """按平台标签的优先级挑出这台机器会装的轮子；没有适用的返回 None。"""
        by_tag: dict[_tags.Tag, Wheel] = {}
        for wheel in self.wheels:
            for tag in wheel.tags:
                by_tag.setdefault(tag, wheel)
        return next((by_tag[t] for t in supported if t in by_tag), None)


@dataclass(frozen=True)
class Lock:
    packages: tuple[Locked, ...]
    python: str | None
    index: str | None
    digest: str
    """锁文件内容的 sha256：授权与依赖目录都按它认。"""


# ---------------------------------------------------------------------- 解析
def parse_lock(text: str) -> Lock:
    """解析并校验锁文件；不合规抛 ``LockError``（带行号的中文原因）。"""
    header: dict[str, str] = {}
    pending: list[tuple[int, Wheel]] = []
    packages: dict[str, Locked] = {}
    for number, line in _logical_lines(text):
        if line.startswith("#>"):
            pending.append((number, _wheel_line(number, line)))
            continue
        if line.startswith("#"):
            if match := _HEADER.match(line):
                header[match[1]] = match[2]
            continue
        locked = _requirement(number, line, [w for _n, w in pending])
        pending = []
        if locked.name in packages:
            raise LockError(f"第 {number} 行：{locked.name} 出现了两次")
        packages[locked.name] = locked
    if pending:
        raise LockError(f"第 {pending[0][0]} 行：末尾的 #> 行下面没有对应的包")
    if not packages:
        raise LockError("锁文件里没有任何包；不需要第三方依赖就去掉清单里的 [dependencies]")
    return Lock(
        packages=tuple(packages.values()),
        python=header.get("python"),
        index=header.get("index"),
        digest=lock_digest(text),
    )


def lock_digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _logical_lines(text: str) -> Iterable[tuple[int, str]]:
    """去空行、拼接 ``\\`` 续行；注释行不参与续行（与 pip 一致）。"""
    buffer: list[str] = []
    start = 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if buffer and line.startswith("#"):
            raise LockError(f"第 {number} 行：续行（\\）中间不能插注释")
        if not buffer:
            start = number
        if line.endswith("\\"):
            buffer.append(line[:-1].strip())
            continue
        buffer.append(line)
        joined = " ".join(p for p in buffer if p)
        buffer = []
        if joined:
            yield start, joined
    if buffer:
        raise LockError(f"第 {start} 行：最后一行以 \\ 结尾，后面没有内容")


def _wheel_line(number: int, line: str) -> Wheel:
    parts = line[2:].split()
    if len(parts) != 3 or not parts[2].startswith("sha256:"):
        raise LockError(f"第 {number} 行：#> 行须是「文件名 字节数 sha256:哈希」")
    filename, size, digest = parts[0], parts[1], parts[2].removeprefix("sha256:")
    if not filename.endswith(".whl"):
        raise LockError(
            f"第 {number} 行：{filename} 是源码包：只接受预编译好的轮子（.whl），用户机器上不编译"
        )
    try:
        parse_wheel_filename(filename)
    except InvalidWheelFilename as exc:
        raise LockError(f"第 {number} 行：{filename} 不是合法的轮子文件名") from exc
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise LockError(f"第 {number} 行：{filename} 的 sha256 写法不对")
    if size != "?" and not size.isdigit():
        raise LockError(f"第 {number} 行：{filename} 的字节数写法不对")
    return Wheel(filename=filename, size=None if size == "?" else int(size), sha256=digest)


def _requirement(number: int, line: str, wheels: list[Wheel]) -> Locked:
    if ";" in line:
        raise LockError(
            f"第 {number} 行：不支持环境标记（; 之后的条件）："
            "锁文件按主程序的平台生成，用打包工具重新生成"
        )
    line = re.sub(r"\s+#.*$", "", line)
    spec, *options = line.split()
    if spec.startswith("-") or "/" in spec or ":" in spec:
        raise LockError(f"第 {number} 行：只能写「包名==版本」加 --hash，不能写 {spec}")
    match = _REQ.match(spec)
    if not match:
        raise LockError(f"第 {number} 行：看不懂 {spec}，须写成「包名==版本」")
    raw, extras, op, version = match.groups()
    name = canonicalize_name(raw)
    if extras:
        raise LockError(
            f"第 {number} 行：{raw}{extras} 不要写附加依赖，锁文件里直接列出展开后的每个包"
        )
    if op != "==" or not version or "*" in version:
        raise LockError(f"第 {number} 行：{raw} 没有钉死版本，须写成 {raw}==具体版本")
    hashes: list[str] = []
    for option in options:
        found = _HASH.match(option)
        if found is None:
            if option.startswith("--hash="):
                raise LockError(f"第 {number} 行：{raw} 只接受 sha256 哈希（--hash=sha256:…）")
            raise LockError(f"第 {number} 行：{raw} 后面只能跟 --hash，不能写 {option}")
        hashes.append(found[1])
    if not hashes:
        raise LockError(
            f"第 {number} 行：{raw} 缺少 --hash：每个包都要带 sha256 哈希，防止下载到被替换的文件"
        )
    described = {w.sha256: w for w in wheels}
    for wheel in wheels:
        wheel_name, wheel_version, _build, _t = parse_wheel_filename(wheel.filename)
        if wheel_name != name or str(wheel_version) != version:
            raise LockError(f"第 {number} 行上方的 {wheel.filename} 不是 {raw}=={version} 的轮子")
        if wheel.sha256 not in hashes:
            raise LockError(f"第 {number} 行：{wheel.filename} 的哈希不在 {raw} 的 --hash 里")
    for digest in hashes:
        if digest not in described:
            raise LockError(
                f"第 {number} 行：{raw}=={version} 的哈希 {digest[:12]}… "
                "没有对应的轮子说明（#> 行），可能是源码包；只接受轮子，请用打包工具重新生成锁文件"
            )
    return Locked(name=name, version=version, hashes=tuple(hashes), wheels=tuple(wheels))


# ---------------------------------------------------------------------- 主程序自带的包
def host_packages() -> dict[str, str]:
    """这个解释器环境里装着的包（规范化包名 → 版本）：插件直接用这些，锁文件里不能再出现。"""
    found: dict[str, str] = {}
    for dist in metadata.distributions():
        name = dist.metadata["Name"]
        if name:
            found.setdefault(canonicalize_name(name), dist.version)
    return dict(sorted(found.items()))


def constraints_text(packages: Mapping[str, str] | None = None) -> str:
    from movieclaw_sdk import SDK_VERSION

    packages = host_packages() if packages is None else packages
    lines = [
        "# MovieClaw 主程序自带的包：插件直接用这些，依赖锁文件里不能再出现",
        f"# python: {sys.version_info.major}.{sys.version_info.minor}",
        f"# sdk: {SDK_VERSION}",
        *(f"{name}=={version}" for name, version in packages.items()),
    ]
    return "\n".join(lines) + "\n"


def parse_constraints(text: str) -> tuple[dict[str, str], str | None]:
    """``host-constraints.txt`` → (包名 → 版本, Python 版本)。"""
    packages: dict[str, str] = {}
    python = None
    for raw in text.splitlines():
        line = raw.strip()
        if match := _HEADER.match(line):
            if match[1] == "python":
                python = match[2]
            continue
        if not line or line.startswith("#"):
            continue
        name, sep, version = line.partition("==")
        if sep:
            packages[canonicalize_name(name.strip())] = version.strip()
    return packages, python


def check_host(lock: Lock, host: Mapping[str, str]) -> None:
    """不许覆盖主程序已有的包：重名一律拒绝（版本相同也不行，直接用主程序的）。"""
    clash = [p for p in lock.packages if p.name in host]
    if clash:
        detail = "、".join(f"{p.name}（锁文件 {p.version}，主程序 {host[p.name]}）" for p in clash)
        raise LockError(f"{detail}是主程序自带的包，不能再装一份；从锁文件里去掉，直接用主程序的")


# ---------------------------------------------------------------------- 平台
def target_tags(target: str, python: str) -> list[_tags.Tag]:
    """镜像平台（``linux/amd64`` / ``linux/arm64``）+ Python 版本支持的轮子标签，按优先级排。"""
    arch = _ARCH[target]
    major, minor = (int(p) for p in python.split(".")[:2])
    platforms = [f"manylinux_{_GLIBC[0]}_{m}_{arch}" for m in range(_GLIBC[1], 4, -1)]
    platforms += [f"manylinux2014_{arch}"]
    if arch == "x86_64":
        platforms += ["manylinux2010_x86_64", "manylinux1_x86_64"]
    platforms.append(f"linux_{arch}")
    version = (major, minor)
    return [
        *_tags.cpython_tags(version, abis=[f"cp{major}{minor}"], platforms=platforms),
        *_tags.compatible_tags(version, interpreter=f"cp{major}{minor}", platforms=platforms),
    ]


def missing_platforms(lock: Lock, python: str) -> dict[str, list[str]]:
    """打包时检查：每个目标平台缺轮子的包（平台 → [包 版本]）。"""
    missing: dict[str, list[str]] = {}
    for target in TARGETS:
        supported = target_tags(target, python)
        lacking = [f"{p.name} {p.version}" for p in lock.packages if p.pick(supported) is None]
        if lacking:
            missing[target] = lacking
    return missing


def here_tags() -> list[_tags.Tag]:
    return list(_tags.sys_tags())


# ---------------------------------------------------------------------- 生成
def generate(
    requirements: list[str],
    *,
    constraints: str,
    index_url: str = DEFAULT_INDEX,
    python: str | None = None,
) -> str:
    """按主程序的约束清单解析出完整依赖闭包，写成锁文件（与主程序重名的包不进锁文件）。"""
    host, host_python = parse_constraints(constraints)
    python = python or host_python or f"{sys.version_info.major}.{sys.version_info.minor}"
    with tempfile.TemporaryDirectory(prefix="movieclaw-lock-") as tmp:
        base = Path(tmp)
        (base / "requirements.in").write_text("\n".join(requirements) + "\n", encoding="utf-8")
        (base / "constraints.txt").write_text(constraints, encoding="utf-8")
        platforms = [str(t.platform) for t in target_tags("linux/amd64", python)]
        command = [
            sys.executable, "-m", "pip", "install", "--dry-run", "--ignore-installed",
            "--quiet", "--report", str(base / "report.json"), "--only-binary=:all:",
            "--python-version", python, "--implementation", "cp", "--index-url", index_url,
            "-c", str(base / "constraints.txt"), "-r", str(base / "requirements.in"),
        ]  # fmt: skip
        for platform in dict.fromkeys(platforms):
            command += ["--platform", platform]
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout).strip().splitlines()[-8:]
            raise LockError(
                "解析依赖失败（只接受有 linux 轮子的包；与主程序重名的包按主程序的版本）：\n"
                + "\n".join(tail)
            )
        report = json.loads((base / "report.json").read_text(encoding="utf-8"))
    resolved = {
        canonicalize_name(item["metadata"]["name"]): item["metadata"]["version"]
        for item in report.get("install", [])
    }
    lines = [
        "# MovieClaw 插件依赖锁文件：python -m movieclaw_sdk.deps lock 生成，不要手改",
        f"# python: {python}",
        f"# index: {index_url}",
        "# 每个包上方的 #> 行是它的轮子（文件名、字节数、sha256），安装时 pip 当注释跳过",
    ]
    for name, version in sorted(resolved.items()):
        if name in host:
            continue
        wheels = _index_wheels(index_url, name, version)
        if not wheels:
            raise LockError(f"{name} {version} 在 {index_url} 上没有轮子：只接受预编译好的轮子")
        lines.append("")
        lines += [f"#> {w.filename} {_size(w)} sha256:{w.sha256}" for w in wheels]
        hashes = [f"    --hash=sha256:{w.sha256}" for w in wheels]
        lines.append(f"{name}=={version} \\")
        lines += [h + " \\" for h in hashes[:-1]] + [hashes[-1]]
    if len(lines) == 4:
        raise LockError("依赖全部是主程序自带的包，不需要锁文件；去掉清单里的 [dependencies] 即可")
    return "\n".join(lines) + "\n"


def _size(wheel: Wheel) -> str:
    return "?" if wheel.size is None else str(wheel.size)


INDEX_ACCEPT = "application/vnd.pypi.simple.v1+json, text/html;q=0.1"


@dataclass(frozen=True)
class IndexFile:
    filename: str
    size: int | None
    sha256: str
    url: str


def index_page_url(index_url: str, name: str) -> str:
    return f"{index_url.rstrip('/')}/{canonicalize_name(name)}/"


def parse_index_page(body: str, content_type: str, page_url: str) -> list[IndexFile]:
    """包索引的项目页（PEP 691 JSON，或不支持它的镜像的 HTML 页）→ 文件列表（不含撤回的）。"""
    from urllib.parse import urldefrag, urljoin

    files: list[IndexFile] = []
    if "json" in content_type:
        for item in json.loads(body).get("files", []):
            digest = (item.get("hashes") or {}).get("sha256")
            if digest and not item.get("yanked"):
                url = urljoin(page_url, urldefrag(item["url"])[0])
                files.append(IndexFile(item["filename"], item.get("size"), digest, url))
        return files
    for tag, href, filename in re.findall(r'(<a[^>]*href="([^"]+)"[^>]*>)([^<]+)</a>', body):
        found = re.search(r"#sha256=([0-9a-f]{64})", href)
        if found and "data-yanked" not in tag:
            url = urljoin(page_url, urldefrag(href)[0])
            files.append(IndexFile(filename.strip(), None, found[1], url))
    return files


def version_wheels(files: Iterable[IndexFile], name: str, version: str) -> list[IndexFile]:
    wheels: list[IndexFile] = []
    for item in files:
        if not item.filename.endswith(".whl"):
            continue
        try:
            wheel_name, wheel_version, _b, _t = parse_wheel_filename(item.filename)
        except InvalidWheelFilename:
            continue
        if wheel_name == canonicalize_name(name) and str(wheel_version) == version:
            wheels.append(item)
    return sorted(wheels, key=lambda w: w.filename)


def _index_wheels(index_url: str, name: str, version: str) -> list[Wheel]:
    """包索引上这个版本的全部轮子。

    所有平台、所有 Python 版本都记下：主程序换了 Python 版本后可以按原锁文件重装。
    """
    page = index_page_url(index_url, name)
    request = urllib.request.Request(page, headers={"Accept": INDEX_ACCEPT})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 -- 作者给的索引地址
        body = response.read().decode("utf-8")
        kind = response.headers.get("Content-Type", "")
    found = version_wheels(parse_index_page(body, kind, response.url or page), name, version)
    return [Wheel(filename=f.filename, size=f.size, sha256=f.sha256) for f in found]


# ---------------------------------------------------------------------- 命令行
def read_constraints(source: str | None) -> tuple[str, str]:
    """约束清单：文件、网址，或缺省时取最新服务器版本的；拿不到就用当前环境（并说明）。"""
    if source is None:
        try:
            return _fetch(CONSTRAINTS_URL), CONSTRAINTS_URL
        except OSError as exc:
            note = f"当前环境（取不到 {CONSTRAINTS_URL}：{exc}；建议用 --constraints 指定）"
            return constraints_text(), note
    if source.startswith(("http://", "https://")):
        return _fetch(source), source
    return Path(source).read_text(encoding="utf-8"), source


def _fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as response:  # noqa: S310 -- 固定 / 用户给的地址
        return response.read().decode("utf-8")


def manifest_lock(directory: Path) -> Path:
    data = tomllib.loads((directory / MANIFEST).read_text(encoding="utf-8"))
    lock = (data.get("dependencies") or {}).get("lock")
    if not lock:
        raise LockError(f'{MANIFEST} 里没有 [dependencies] lock = "…"')
    return directory / lock


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m movieclaw_sdk.deps")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("constraints", help="输出主程序自带的包（host-constraints.txt）")
    for name in ("lock", "check"):
        cmd = sub.add_parser(name)
        cmd.add_argument("directory", type=Path)
        cmd.add_argument("--constraints", help="主程序的 host-constraints.txt（文件或网址）")
        if name == "lock":
            cmd.add_argument("--index-url", default=DEFAULT_INDEX)
            cmd.add_argument("--python", help="目标 Python 版本（缺省取约束清单里的）")
    args = parser.parse_args(argv)
    if args.command == "constraints":
        sys.stdout.write(constraints_text())
        return 0
    try:
        target = manifest_lock(args.directory)
        constraints, source = read_constraints(args.constraints)
        print(f"主程序约束清单：{source}", file=sys.stderr)
        if args.command == "lock":
            requirements = args.directory / REQUIREMENTS
            if not requirements.is_file():
                raise LockError(f"{args.directory} 下没有 {REQUIREMENTS}（每行一个直接依赖）")
            wanted = [
                line.strip()
                for line in requirements.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.strip().startswith("#")
            ]
            text = generate(
                wanted, constraints=constraints, index_url=args.index_url, python=args.python
            )
            target.write_text(text, encoding="utf-8")
            print(f"已写入 {target}", file=sys.stderr)
        report(target.read_text(encoding="utf-8"), constraints)
    except (LockError, OSError) as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 1
    return 0


def report(text: str, constraints: str) -> Lock:
    """校验并打印锁文件摘要；缺平台只告警（安装到那个平台时会给出原因）。"""
    host, python = parse_constraints(constraints)
    lock = parse_lock(text)
    check_host(lock, host)
    native = [p.name for p in lock.packages if p.native]
    print(
        f"✓ 锁文件合规：{len(lock.packages)} 个包"
        + (f"，含本机代码：{'、'.join(native)}" if native else "，全部是纯 Python")
    )
    for target, lacking in missing_platforms(lock, python or lock.python or "3.12").items():
        print(f"⚠ 没有 {target} 的轮子：{'、'.join(lacking)}（装到这个平台会失败）")
    return lock


if __name__ == "__main__":
    sys.exit(main())
