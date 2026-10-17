"""插件依赖锁文件的校验（docs/design/plugin-dependencies.md §1）：不合规的锁文件给出具体原因。"""

from __future__ import annotations

import hashlib

import pytest

from movieclaw_sdk import deps

LZ4 = (
    "lz4-4.4.4-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
    "lz4-4.4.4-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl",
    "lz4-4.4.4-cp312-cp312-macosx_11_0_arm64.whl",
)
ECDSA = ("ecdsa-0.19.1-py2.py3-none-any.whl",)


def sha(filename: str) -> str:
    return hashlib.sha256(filename.encode()).hexdigest()


def block(spec: str, files: tuple[str, ...], *, hashes: list[str] | None = None) -> str:
    lines = [f"#> {f} 1000 sha256:{sha(f)}" for f in files]
    hashes = [sha(f) for f in files] if hashes is None else hashes
    return "\n".join([*lines, f"{spec} \\", *(f"    --hash=sha256:{h} \\" for h in hashes)]).rstrip(
        " \\"
    )


def lock(*blocks: str) -> str:
    return "# python: 3.12\n" + "\n\n".join(blocks) + "\n"


GOOD = lock(block("lz4==4.4.4", LZ4), block("ecdsa==0.19.1", ECDSA))


def test_a_generated_style_lock_parses_with_sizes_and_native_flags() -> None:
    parsed = deps.parse_lock(GOOD)
    by_name = {p.name: p for p in parsed.packages}
    assert by_name["lz4"].native and not by_name["ecdsa"].native
    assert by_name["lz4"].version == "4.4.4" and len(by_name["lz4"].hashes) == 3
    assert parsed.python == "3.12"
    assert parsed.digest == hashlib.sha256(GOOD.encode()).hexdigest()


def test_platform_picks_the_right_wheel_and_reports_missing_ones() -> None:
    parsed = deps.parse_lock(GOOD)
    lz4 = next(p for p in parsed.packages if p.name == "lz4")
    assert lz4.pick(deps.target_tags("linux/arm64", "3.12")).filename == LZ4[1]
    assert lz4.pick(deps.target_tags("linux/amd64", "3.12")).filename == LZ4[0]
    # 主程序换了 Python：cp312 的轮子装不上
    assert lz4.pick(deps.target_tags("linux/amd64", "3.13")) is None
    only_x86 = deps.parse_lock(lock(block("lz4==4.4.4", LZ4[:1])))
    assert deps.missing_platforms(only_x86, "3.12") == {"linux/arm64": ["lz4 4.4.4"]}
    assert deps.missing_platforms(parsed, "3.12") == {}


BAD = {
    "not-pinned": (lock(block("lz4>=4.0", LZ4)), "没有钉死版本"),
    "wildcard": (lock(block("lz4==4.*", LZ4)), "没有钉死版本"),
    "no-hash": (
        lock("#> " + LZ4[0] + f" 1000 sha256:{sha(LZ4[0])}\nlz4==4.4.4"),
        "缺少 --hash",
    ),
    "md5": (lock("lz4==4.4.4 --hash=md5:abcdef"), "只接受 sha256"),
    "sdist-line": (
        lock(f"#> lz4-4.4.4.tar.gz 1000 sha256:{sha('x')}\nlz4==4.4.4 --hash=sha256:{sha('x')}"),
        "是源码包：只接受预编译好的轮子",
    ),
    "undescribed-hash": (
        lock(block("lz4==4.4.4", LZ4[:1], hashes=[sha(LZ4[0]), sha("lz4-4.4.4.tar.gz")])),
        "没有对应的轮子说明",
    ),
    "wrong-wheel": (lock(block("lz4==4.4.5", LZ4)), "不是 lz4==4.4.5 的轮子"),
    "extras": (lock(block("lz4[flame]==4.4.4", LZ4)), "不要写附加依赖"),
    "marker": (lock('lz4==4.4.4 ; python_version < "3.13"'), "不支持环境标记"),
    "url": (lock("https://example.com/lz4.whl"), "不能写"),
    "option": (lock("--index-url https://example.com/simple"), "不能写"),
    "duplicate": (lock(block("lz4==4.4.4", LZ4), block("LZ4==4.4.4", LZ4)), "出现了两次"),
    "empty": ("# python: 3.12\n", "没有任何包"),
    "dangling": (GOOD + f"#> {ECDSA[0]} 1 sha256:{sha(ECDSA[0])}\n", "下面没有对应的包"),
}


@pytest.mark.parametrize("case", sorted(BAD))
def test_bad_locks_are_rejected_with_a_reason(case) -> None:
    text, message = BAD[case]
    with pytest.raises(deps.LockError, match=message):
        deps.parse_lock(text)


def test_packages_the_host_already_has_are_rejected() -> None:
    parsed = deps.parse_lock(GOOD)
    clash = r"ecdsa（锁文件 0.19.1，主程序 0.18.0）是主程序自带的包"
    with pytest.raises(deps.LockError, match=clash):
        deps.check_host(parsed, {"ecdsa": "0.18.0", "httpx": "0.28.1"})
    deps.check_host(parsed, {"httpx": "0.28.1"})


def test_constraints_list_the_host_environment() -> None:
    text = deps.constraints_text()
    packages, python = deps.parse_constraints(text)
    assert packages["httpx"] and packages["cryptography"]
    assert python and python.count(".") == 1
    assert deps.parse_constraints("# python: 3.12\nFoo_Bar==1.0\n") == ({"foo-bar": "1.0"}, "3.12")
