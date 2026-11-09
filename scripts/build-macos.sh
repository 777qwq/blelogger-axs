#!/bin/bash
# macOS / Xcode 构建：一次产出 arm64 + arm64e 双切片（fat）。
#
# 为什么必须在这边编：arm64e 的指针认证（ptrauth）、__AUTH 段和 chained
# fixups 只有 Apple 的 ld64 会生成，Linux 的 ld64.lld 明确拒绝 arm64e
# （"-fixup_chains is only supported on x86_64 and arm64 targets"）。
# Settings.app 是 arm64e 进程，dlopen 只接受带 arm64e 切片的 bundle。
set -e
cd "$(dirname "$0")/.."

VER=${VER:-1.4.1}
TARGET_DYLIB=AxsBLELogger
BIN_DIR=${BIN_DIR:-/tmp/axsbuild}
rm -rf "$BIN_DIR" && mkdir -p "$BIN_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
echo "SDK: $SDK"
"$CC" --version | head -1

# 只有 %ctor，本地直接换成构造函数，不引入 logos.pl
sed -e 's/^%ctor {/__attribute__((constructor)) static void axs_blelogger_ctor(void) {/' \
    -e '/^%end$/d' Hooks/AxsBLELoggerMain.xm > "$BIN_DIR/Hooks.m"

COMMON=(-isysroot "$SDK"
        -IHeaders -ISources
        -fobjc-arc -O2 -fno-omit-frame-pointer
        -Wl,-undefined,dynamic_lookup)

build_arch() {
  local A=$1
  echo "== $A =="
  "$CC" -target "$A-apple-ios15.0" "${COMMON[@]}" -dynamiclib \
    -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/${TARGET_DYLIB}.dylib \
    -framework UIKit -framework Foundation -framework CoreBluetooth -framework CoreFoundation \
    Sources/*.m "$BIN_DIR/Hooks.m" \
    -o "$BIN_DIR/${TARGET_DYLIB}_${A}.dylib"

  # Preferences 是私有框架，SDK 里没有它的头。只补 Preferences/ 这一层，
  # 不要整个 -Ivendor/iosmini —— 那样精简版的 Foundation/UIKit 会盖掉真 SDK 的，
  # 声明缺一大截反而编不过。
  "$CC" -target "$A-apple-ios15.0" "${COMMON[@]}" -Ivendor/prefs-headers -bundle \
    -framework UIKit -framework Foundation -framework CoreFoundation \
    AxsBLELoggerPrefs/*.m \
    -o "$BIN_DIR/AxsBLELoggerPrefs_${A}"
}

build_arch arm64
build_arch arm64e

lipo -create "$BIN_DIR/${TARGET_DYLIB}_arm64.dylib" "$BIN_DIR/${TARGET_DYLIB}_arm64e.dylib" \
     -output "$BIN_DIR/${TARGET_DYLIB}.dylib"
lipo -create "$BIN_DIR/AxsBLELoggerPrefs_arm64" "$BIN_DIR/AxsBLELoggerPrefs_arm64e" \
     -output "$BIN_DIR/AxsBLELoggerPrefs"

# adhoc 签名。lipo 合并后原签名失效，必须在这之后签；
# fatal 让签名失败直接中断，不要产出装不上的包。
codesign --force --sign - --timestamp=none "$BIN_DIR/${TARGET_DYLIB}.dylib"
codesign --force --sign - --timestamp=none "$BIN_DIR/AxsBLELoggerPrefs"

lipo -info "$BIN_DIR/${TARGET_DYLIB}.dylib"
lipo -info "$BIN_DIR/AxsBLELoggerPrefs"

BIN_DIR="$BIN_DIR" VER="$VER" ./scripts/package.sh
