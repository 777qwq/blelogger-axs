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


def chain_pointer_formats(path, subtype):
    """返回指定切片里 chained fixups 用到的 pointer_format 集合。

    1 = DYLD_CHAINED_PTR_ARM64E，7 = ..._KERNEL，9 = ..._USERLAND，
    12 = ..._USERLAND24。这几个才带 ptrauth 的 auth 位。
    2/6 是普通 64 位指针，arm64e 进程里加载 objc 类会认签失败。
    """
    data = open(path, "rb").read()
    for cpu, sub, offset, size in macho_slices(path):
        if cpu != ARM64 or sub != subtype:
            continue
        s = data[offset:offset + size]
        ncmds = struct.unpack_from("<I", s, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", s, off)
            if cmd == 0x80000034:  # LC_DYLD_CHAINED_FIXUPS
                dataoff = struct.unpack_from("<I", s, off + 8)[0]
                starts = dataoff + struct.unpack_from("<I", s, dataoff + 4)[0]
                segc = struct.unpack_from("<I", s, starts)[0]
                fmts = set()
                for j in range(segc):
                    segoff = struct.unpack_from("<I", s, starts + 4 + 4 * j)[0]
                    if segoff == 0:
                        continue
                    ss = starts + segoff
                    _, _, pfmt = struct.unpack_from("<IHH", s, ss)
                    fmts.add(pfmt)
                return fmts
            off += cmdsize
    return set()


ARM64E_PTR_FORMATS = {1, 7, 9, 12}


def assert_arm64e(path, label):
    archs = [(c, s) for c, s, _, _ in macho_slices(path)]
    assert (ARM64, ARM64E_SUBTYPE) in archs, \
        label + " 缺 arm64e 切片，arm64e 设备上加载会失败：" + repr(archs)

    # 光有架构标签不够，但判断依据不是段名 —— 现代 ld64 会把签名指针
    # 直接放 __DATA_CONST，不一定单独开 __AUTH 段。真正要验的是
    # chained fixups 的 pointer_format 是不是 arm64e 那几种（带 auth 位）。
    fmts = chain_pointer_formats(path, ARM64E_SUBTYPE)
    assert fmts & ARM64E_PTR_FORMATS, \
        label + " 的 arm64e 切片指针格式不是 arm64e（未签名），加载会崩：" + repr(fmts)
    return archs

REQUIRED = [
    "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.dylib",
    "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.plist",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/AxsBLELoggerPrefs",
    "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/Info.plist",
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
    assert b"writeValue:forCharacteristic:type:" in dylib, "抓包库没 hook 写入方向"
    assert b"didUpdateValueForCharacteristic" in dylib, "抓包库没 hook 接收方向"
    assert b"com.apple." in dylib, "抓包库没跳过系统进程"
    assert b"app.plist" in dylib, "抓包库没有抓包落盘路径"

    # 1.5.0：SpringBoard 直连扫描必须也在里面，否则注入失败时无任何退路
    assert b"com.apple.springboard" in dylib, "抓包库没有 SpringBoard 直连分支"
    assert b"scanForPeripheralsWithServices" in dylib, "抓包库没有扫描实现"
    assert b"setNotifyValue:forCharacteristic:" in dylib, "抓包库没有订阅 Notify"
    # 存储位置：Caches 目录，且不能再往 Preferences 里写
    assert b"/var/mobile/Library/Caches/com.qwq.blelogger" in dylib, "抓包库没有用新的数据目录"
    assert b"config.plist" in dylib, "抓包库没有读新配置文件名"

    # Filter 必须放行 SpringBoard
    filt = plistlib.load(open(os.path.join(
        base, "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.plist"), "rb"))
    bundles = filt.get("Filter", {}).get("Bundles", [])
    classes = filt.get("Filter", {}).get("Classes", [])
    assert "com.apple.springboard" in bundles or "UIApplication" in classes, \
        "Filter 既没点名 SpringBoard 也没放行 UIApplication"

    # 面板必须写回父类的 _specifiers，否则表格 0 行（1.3.0 的空白 bug）
    assert b"_specifiers" in prefs_bin, "面板没有引用 PSListController 的 _specifiers，界面会空白"
    assert b"targetUUID" in prefs_bin, "面板没有直连目标选择，扫描器连不上设备"

    print("OK", deb)


if __name__ == "__main__":
    main(sys.argv[1])
