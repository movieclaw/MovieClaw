"""Check shipped PE imports without trusting developer DLLs installed on the CI host."""

import argparse
import json
import pathlib
import struct

SYSTEM_DLLS = set(
    [
        "advapi32",
        "avicap32",
        "avrt",
        "bcrypt",
        "bcryptprimitives",
        "cfgmgr32",
        "comctl32",
        "combase",
        "crypt32",
        "d2d1",
        "d3d11",
        "d3d12",
        "dcomp",
        "dbghelp",
        "dnsapi",
        "dwrite",
        "dwmapi",
        "dxgi",
        "gdi32",
        "imm32",
        "iphlpapi",
        "kernel32",
        "mf",
        "mfplat",
        "mfuuid",
        "normaliz",
        "ntdll",
        "ole32",
        "oleaut32",
        "opengl32",
        "powrprof",
        "propsys",
        "psapi",
        "rpcrt4",
        "secur32",
        "setupapi",
        "shcore",
        "shell32",
        "shlwapi",
        "user32",
        "userenv",
        "ucrtbase",
        "uxtheme",
        "version",
        "winhttp",
        "wininet",
        "winmm",
        "winspool",
        "wintrust",
        "wldap32",
        "ws2_32",
        "wtsapi32",
    ]
)


def imports(data):
    if data[:2] != b"MZ":
        raise ValueError("Not a Windows PE executable")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe : pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE signature")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic not in (0x10B, 0x20B):
        raise ValueError("Unknown PE optional header")
    directory = optional + (112 if magic == 0x20B else 96)
    sections = [
        struct.unpack_from("<IIII", data, optional + optional_size + index * 40 + 8)
        for index in range(count)
    ]

    def offset(rva):
        for size, address, raw_size, raw_offset in sections:
            if address <= rva < address + max(size, raw_size):
                return raw_offset + rva - address
        raise ValueError("PE RVA outside sections")

    names = []
    # Ordinary imports and delay-loaded imports both need to resolve on a new device.
    for index, stride, name_field in ((1, 20, 12), (13, 32, 4)):
        rva, size = struct.unpack_from("<II", data, directory + index * 8)
        if not rva or not size:
            continue
        start = offset(rva)
        for position in range(start, start + size, stride):
            descriptor = data[position : position + stride]
            if not any(descriptor):
                break
            name_rva = struct.unpack_from("<I", descriptor, name_field)[0]
            name_start = offset(name_rva)
            names.append(data[name_start : data.index(b"\0", name_start)].decode("ascii").lower())
    return sorted(set(names))


def audit(package):
    inventory = {}
    for executable in sorted(package.rglob("*")):
        if executable.suffix.lower() not in (".exe", ".dll", ".com"):
            continue
        dependencies = imports(executable.read_bytes())
        neighbors = {file.name.lower() for file in executable.parent.iterdir() if file.is_file()}
        missing = [
            name
            for name in dependencies
            if name not in neighbors
            and not name.startswith(("api-ms-win-", "ext-ms-win-"))
            and name.removesuffix(".dll") not in SYSTEM_DLLS
        ]
        if missing:
            raise ValueError(
                f"{executable.relative_to(package)} requires unbundled DLLs: {missing}"
            )
        inventory[str(executable.relative_to(package))] = dependencies
    if "movieclaw-desktop.exe" not in inventory or not any(
        name.endswith("mpv.exe") for name in inventory
    ):
        raise ValueError("The package must include the application and mpv")
    return inventory


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(audit(args.package), indent=2), encoding="utf-8")
