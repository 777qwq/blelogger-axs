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


def assert_arm64e(path, label):
    archs = macho_archs(path)
    assert (ARM64, ARM64E_SUBTYPE) in archs, \
        label + " 缺 arm64e 切片，arm64e 设备上加载会失败：" + repr(archs)
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
