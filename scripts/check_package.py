#!/usr/bin/env python3
"""检查 deb 结构：面板入口、bundle 资源、二进制架构与关键符号。

架构是重点：Settings.app 在 A12 及以上机型是 arm64e 进程，dlopen 只接受
带 arm64e 切片的 Mach-O，缺了就会报 incompatible architecture
(have 'arm64', need 'arm64e')。
"""
import os
import plistlib
import struct
import subprocess
import sys
import tempfile

ARM64 = 0x0100000C
ARM64E_SUBTYPE = 2


def macho_archs(path):
    """返回 [(cputype, cpusubtype)]，fat 与 thin 都支持。"""
    data = open(path, "rb").read()
    magic_be = struct.unpack(">I", data[:4])[0]
    if magic_be in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack(">I", data[4:8])[0]
        step = 20 if magic_be == 0xCAFEBABE else 32
        out = []
        for i in range(count):
            base = 8 + i * step
            cputype, cpusubtype = struct.unpack(">ii", data[base:base + 8])
            out.append((cputype, cpusubtype & 0x00FFFFFF))
        return out

    magic_le = struct.unpack("<I", data[:4])[0]
    assert magic_le == 0xFEEDFACF, "不是 64 位 Mach-O"
    cputype, cpusubtype = struct.unpack("<ii", data[4:12])
    return [(cputype, cpusubtype & 0x00FFFFFF)]


def macho_slices(path):
    """返回 [(cputype, cpusubtype, offset, size)]。"""
    data = open(path, "rb").read()
    magic_be = struct.unpack(">I", data[:4])[0]
    out = []
    if magic_be in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack(">I", data[4:8])[0]
        wide = magic_be == 0xCAFEBABF
        step = 32 if wide else 20
        for i in range(count):
            base = 8 + i * step
            cputype, cpusubtype = struct.unpack(">ii", data[base:base + 8])
            if wide:
                offset, size = struct.unpack(">QQ", data[base + 8:base + 24])
            else:
                offset, size = struct.unpack(">II", data[base + 8:base + 16])
            out.append((cputype, cpusubtype & 0x00FFFFFF, offset, size))
        return out

    cputype, cpusubtype = struct.unpack("<ii", data[4:12])
    return [(cputype, cpusubtype & 0x00FFFFFF, 0, len(data))]


def slice_segments(path, subtype):
    """取指定 subtype 切片里的所有段名。"""
    data = open(path, "rb").read()
    for cpu, sub, offset, size in macho_slices(path):
        if cpu != ARM64 or sub != subtype:
            continue
        slice_data = data[offset:offset + size]
        ncmds = struct.unpack_from("<I", slice_data, 16)[0]
        off = 32
        names = []
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", slice_data, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                names.append(slice_data[off + 8:off + 24].rstrip(b"\0").decode("utf-8", "replace"))
            off += cmdsize
        return names
    return []


def assert_arm64e(path, label):
    archs = [(c, s) for c, s, _, _ in macho_slices(path)]
    assert (ARM64, ARM64E_SUBTYPE) in archs, \
        label + " 缺 arm64e 切片，arm64e 设备上加载会失败：" + repr(archs)

    # 只有架构标签不够。objc 的 class_ro_t* 需要 ptrauth 签名，
    # 没有 __AUTH 段就是"假 arm64e"，进设置会 SIGBUS（readClass 认签失败）。
    segs = slice_segments(path, ARM64E_SUBTYPE)
    assert any(s.startswith("__AUTH") for s in segs), \
        label + " 的 arm64e 切片没有 __AUTH 段，objc 指针未签名，加载会崩：" + repr(segs)
    return archs

REQUIRED = [
    "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.dylib",
    "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.plist",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/AxsBLELoggerPrefs",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/Info.plist",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/AxsBLELoggerRoot.plist",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/icon.png",
    "Library/PreferenceLoader/Preferences/AxsBLELoggerPrefs.plist",
]


def main(deb):
    tmp = tempfile.mkdtemp()
    subprocess.run(["dpkg-deb", "-x", deb, tmp], check=True)
    base = os.path.join(tmp, "var/jb")

    for rel in REQUIRED:
        path = os.path.join(base, rel)
        assert os.path.exists(path), "缺少 " + rel
        if path.endswith(".plist"):
            plistlib.load(open(path, "rb"))

    entry = plistlib.load(open(os.path.join(
        base, "Library/PreferenceLoader/Preferences/AxsBLELoggerPrefs.plist"), "rb"))["entry"]
    assert entry.get("isController") is True, "entry 缺 isController，设置里不会出现"
    assert entry.get("detail") == "AxsBLELoggerRootListController"
    assert entry.get("bundle") == "AxsBLELoggerPrefs"

    prefs_path = os.path.join(
        base, "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/AxsBLELoggerPrefs")
    dylib_path = os.path.join(
        base, "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.dylib")

    print("  面板:", assert_arm64e(prefs_path, "面板"))
    print("  抓包库:", assert_arm64e(dylib_path, "抓包库"))

    prefs_bin = open(prefs_path, "rb").read()
    assert b"AxsBLELoggerRootListController" in prefs_bin, "面板二进制里没有入口类"

    dylib = open(dylib_path, "rb").read()
    assert b"com.qwq.blelogger.plist" in dylib, "抓包库没有读配置"
    assert b"selected" in dylib, "抓包库没有白名单逻辑"

    print("OK", deb)


if __name__ == "__main__":
    main(sys.argv[1])
