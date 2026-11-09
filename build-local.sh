#!/bin/bash
# Linux 本地快速构建（无 Theos）。只出 arm64 单切片，用于验证能不能编译、
# 包结构对不对；arm64e 切片必须在 macOS 上用 scripts/build-macos.sh 生成，
# 否则在 arm64e 设备的「设置」里会报 incompatible architecture。
set -e
cd "$(dirname "$0")"

VER=${VER:-1.5.0}
TARGET_DYLIB=AxsBLELogger
BIN_DIR=${BIN_DIR:-/tmp/axsbuild}

if ! command -v clang >/dev/null 2>&1; then
  echo "需要 clang"; exit 1
fi
if command -v ld64.lld >/dev/null 2>&1; then
  LD64=$(command -v ld64.lld)
else
  LD64=/usr/lib/llvm-18/bin/ld64.lld
fi

CFLAGS=(-target arm64-apple-ios15.0 -nostdinc -isystem vendor/iosmini
        -IHeaders -ISources
        -fobjc-arc -O2 -fno-omit-frame-pointer -nostdlib
        -fuse-ld="$LD64" -Wl,-arch,arm64 -Wl,-platform_version,ios,15.0,15.0
        -Wl,-undefined,dynamic_lookup -Wl,-adhoc_codesign
        -Fvendor/tbd -Lvendor/tbd/lib)

rm -rf "$BIN_DIR" && mkdir -p "$BIN_DIR"

# Logos 只有 %ctor，本地直接换成构造函数，不引入 logos.pl
sed -e 's/^%ctor {/__attribute__((constructor)) static void axs_blelogger_ctor(void) {/' \
    -e '/^%end$/d' Hooks/AxsBLELoggerMain.xm > "$BIN_DIR/Hooks.m"

echo "== tweak =="
clang "${CFLAGS[@]}" -dynamiclib \
  -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/${TARGET_DYLIB}.dylib \
  -framework UIKit -framework Foundation -framework CoreBluetooth -framework CoreFoundation \
  -lSystem -lobjc \
  Sources/*.m "$BIN_DIR/Hooks.m" \
  -o "$BIN_DIR/${TARGET_DYLIB}.dylib"

echo "== prefs bundle =="
clang "${CFLAGS[@]}" -bundle \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -lSystem -lobjc \
  AxsBLELoggerPrefs/*.m \
  -o "$BIN_DIR/AxsBLELoggerPrefs"

BIN_DIR="$BIN_DIR" VER="$VER" ./scripts/package.sh
echo ""
echo "注意：本地包只有 arm64，arm64e 设备（A12 及以上）的「设置」加载面板会失败。"
echo "      要真机可用的包，走 scripts/build-macos.sh（CI macos-14 会自动跑）。"
