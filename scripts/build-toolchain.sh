#!/bin/bash
# Linux + Apple ld64（Theos 的 iOSToolchain）构建 arm64 / arm64e 双切片。
#
# 为什么不用 ld64.lld：它明确拒绝 arm64e 输出
# （-fixup_chains is only supported on x86_64 and arm64 targets），
# 生成的也不是 __AUTH 段，指针没有 ptrauth 签名，arm64e 进程加载会崩。
# Settings.app 就是 arm64e，面板必须带真 arm64e 切片。
#
# 用法：
#   APPLE_LD64=/opt/tc/linux/iphone/bin/ld64 ./scripts/build-toolchain.sh
# CI 里由 .github/workflows/build.yml 准备工具链后调用。
set -e
cd "$(dirname "$0")/.."

VER=${VER:-1.4.0}
TARGET_DYLIB=AxsBLELogger
BIN_DIR=${BIN_DIR:-/tmp/axsbuild}

: "${APPLE_LD64:?需要 APPLE_LD64 指向 Apple ld64（Linux 移植版）}"
[ -x "$APPLE_LD64" ] || { echo "APPLE_LD64 不可执行：$APPLE_LD64"; exit 1; }

if [ -n "${LDID:-}" ]; then
  :
elif command -v ldid >/dev/null 2>&1; then
  LDID=ldid
elif [ -x "$(dirname "$APPLE_LD64")/ldid" ]; then
  LDID=$(dirname "$APPLE_LD64")/ldid
else
  echo "找不到 ldid"; exit 1
fi

CLANG=${CLANG:-clang}
echo "clang: $CLANG ($($CLANG --version | head -1))"
echo "ld64: $APPLE_LD64"
echo "ldid: $LDID"

rm -rf "$BIN_DIR" && mkdir -p "$BIN_DIR"

sed -e 's/^%ctor {/__attribute__((constructor)) static void axs_blelogger_ctor(void) {/' \
    -e '/^%end$/d' Hooks/AxsBLELoggerMain.xm > "$BIN_DIR/Hooks.m"

BASE=(-nostdinc -isystem vendor/iosmini
      -IHeaders -ISources
      -fobjc-arc -O2 -fno-omit-frame-pointer -nostdlib
      -fuse-ld="$APPLE_LD64"
      -Wl,-platform_version,ios,15.0,15.0
      -Wl,-undefined,dynamic_lookup
      -Fvendor/tbd -Lvendor/tbd/lib)

build_arch() {
  local A=$1
  local EXTRA=()
  # 老 clang（Theos 自带的 11）默认不签指针，得显式打开；新 clang 顶到
  # arm64e triple 就自己开。用探测的方式加，免得新编译器报 unknown argument。
  if [ "$A" = "arm64e" ]; then
    for f in -fptrauth-calls -fptrauth-returns -fptrauth-indirect-gotos; do
      if echo 'int x;' | "$CLANG" -x c - -fsyntax-only "$f" >/dev/null 2>&1; then
        EXTRA+=("$f")
      fi
    done
  fi
  echo "== $A =="
  "$CLANG" -target "$A-apple-ios15.0" "${EXTRA[@]}" -Wl,-arch,"$A" "${BASE[@]}" -dynamiclib \
    -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/${TARGET_DYLIB}.dylib \
    -framework UIKit -framework Foundation -framework CoreBluetooth -framework CoreFoundation \
    -lSystem -lobjc \
    Sources/*.m "$BIN_DIR/Hooks.m" \
    -o "$BIN_DIR/${TARGET_DYLIB}_${A}.dylib"

  "$CLANG" -target "$A-apple-ios15.0" "${EXTRA[@]}" -Wl,-arch,"$A" "${BASE[@]}" -bundle \
    -framework UIKit -framework Foundation -framework CoreFoundation \
    -lSystem -lobjc \
    AxsBLELoggerPrefs/*.m \
    -o "$BIN_DIR/AxsBLELoggerPrefs_${A}"

  # 架构自证：链接器是不是真按 arm64e 出的
  local SUB
  SUB=$(python3 - "$BIN_DIR/${TARGET_DYLIB}_${A}.dylib" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ct, cs = struct.unpack('<ii', d[4:12])
print(ct, cs & 0x00FFFFFF)
PY
)
  echo "   header cputype/subtype: $SUB"
  if [ "$A" = "arm64e" ]; then
    case "$SUB" in
      "16777228 2") ;;
      *) echo "   !! ld64 没按 arm64e 输出，检查工具链"; exit 1 ;;
    esac

    # 真正的 arm64e 必须有 __AUTH / __AUTH_CONST：objc 的 class_ro_t* 这类
    # 指针要带 ptrauth 签名，缺了会在 map_images -> readClass 里认签失败，
    # Preferences 直接 SIGBUS（1.2.0 就是这么崩的）。
    SEGS=$(python3 - "$BIN_DIR/${TARGET_DYLIB}_${A}.dylib" <<'PY2'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off = 32
names = []
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        names.append(d[off + 8:off + 24].rstrip(b'\0').decode('utf-8', 'replace'))
    off += size
print(' '.join(names))
PY2
)
    echo "   段: $SEGS"
    case "$SEGS" in
      *__AUTH*) ;;
      *) echo "   !! 没有 __AUTH 段，说明编译器没生成指针认证重定位，装上会崩"; exit 1 ;;
    esac
  fi
}

build_arch arm64
build_arch arm64e

LIPO=${LIPO:-llvm-lipo}
command -v $LIPO >/dev/null 2>&1 || LIPO=lipo

$LIPO -create "$BIN_DIR/${TARGET_DYLIB}_arm64.dylib" "$BIN_DIR/${TARGET_DYLIB}_arm64e.dylib" \
      -output "$BIN_DIR/${TARGET_DYLIB}.dylib"
$LIPO -create "$BIN_DIR/AxsBLELoggerPrefs_arm64" "$BIN_DIR/AxsBLELoggerPrefs_arm64e" \
      -output "$BIN_DIR/AxsBLELoggerPrefs"

# lipo 之后原签名失效，必须先合并再签
$LDID -S "$BIN_DIR/${TARGET_DYLIB}.dylib"
$LDID -S "$BIN_DIR/AxsBLELoggerPrefs"

$LIPO -info "$BIN_DIR/${TARGET_DYLIB}.dylib"
$LIPO -info "$BIN_DIR/AxsBLELoggerPrefs"

BIN_DIR="$BIN_DIR" VER="$VER" ./scripts/package.sh
