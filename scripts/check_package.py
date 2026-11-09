#!/usr/bin/env python3
"""检查 deb 结构：面板入口、bundle 资源、二进制类型都能对上。"""
import os
import plistlib
import subprocess
import sys
import tempfile

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

    prefs_bin = open(os.path.join(
        base, "Library/PreferenceBundles/AxsBLELoggerPrefs.bundle/AxsBLELoggerPrefs"), "rb").read()
    assert b"AxsBLELoggerRootListController" in prefs_bin, "面板二进制里没有入口类"

    dylib = open(os.path.join(
        base, "Library/MobileSubstrate/DynamicLibraries/AxsBLELogger.dylib"), "rb").read()
    assert b"com.qwq.blelogger.plist" in dylib, "抓包库没有读配置"
    assert b"selected" in dylib, "抓包库没有白名单逻辑"

    print("OK", deb)


if __name__ == "__main__":
    main(sys.argv[1])
