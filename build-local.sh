#!/bin/bash
# 本地构建（Linux，无 Theos）：把 skill 工程编译成 deb 并检查产物。
# Theos 环境用同目录的 build.sh。
set -e
cd "$(dirname "$0")"

VER=${VER:-1.2.0}
TARGET_DYLIB=AxsBLELogger

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

rm -rf /tmp/axsbuild && mkdir -p /tmp/axsbuild

# Logos 只有 %ctor，本地直接换成构造函数，不引入 logos.pl
sed -e 's/^%ctor {/__attribute__((constructor)) static void axs_blelogger_ctor(void) {/' \
    -e '/^%end$/d' Hooks/AxsBLELoggerMain.xm > /tmp/axsbuild/Hooks.m

echo "== tweak =="
clang "${CFLAGS[@]}" -dynamiclib \
  -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/${TARGET_DYLIB}.dylib \
  -framework UIKit -framework Foundation -framework CoreBluetooth -framework CoreFoundation \
  -lSystem -lobjc \
  Sources/*.m /tmp/axsbuild/Hooks.m \
  -o /tmp/axsbuild/${TARGET_DYLIB}.dylib

echo "== prefs bundle =="
clang "${CFLAGS[@]}" -bundle \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -lSystem -lobjc \
  AxsBLELoggerPrefs/*.m \
  -o /tmp/axsbuild/AxsBLELoggerPrefs

echo "== package =="
DL=build/var/jb/Library/MobileSubstrate/DynamicLibraries
PB=build/var/jb/Library/PreferenceBundles/AxsBLELoggerPrefs.bundle
PL=build/var/jb/Library/PreferenceLoader/Preferences
rm -rf build
mkdir -p "$DL" "$PB" "$PL" build/DEBIAN

cp /tmp/axsbuild/${TARGET_DYLIB}.dylib "$DL/${TARGET_DYLIB}.dylib"
cp AxsBLELogger.plist "$DL/${TARGET_DYLIB}.plist"
chmod 0755 "$DL/${TARGET_DYLIB}.dylib"
chmod 0644 "$DL/${TARGET_DYLIB}.plist"

cp /tmp/axsbuild/AxsBLELoggerPrefs "$PB/AxsBLELoggerPrefs"
cp AxsBLELoggerPrefs/Resources/Info.plist "$PB/Info.plist"
cp AxsBLELoggerPrefs/Resources/AxsBLELoggerRoot.plist "$PB/AxsBLELoggerRoot.plist"
cp AxsBLELoggerPrefs/Resources/icon@2x.png "$PB/icon@2x.png"
# Preferences 按 "icon" 找 icon.png，直接用 @2x 那份顶上
cp AxsBLELoggerPrefs/Resources/icon@2x.png "$PB/icon.png"
chmod 0755 "$PB/AxsBLELoggerPrefs"

cp layout/Library/PreferenceLoader/Preferences/AxsBLELoggerPrefs.plist "$PL/AxsBLELoggerPrefs.plist"
chmod 0644 "$PL/AxsBLELoggerPrefs.plist"

cp control build/DEBIAN/control
sed -i "s/^Version: .*/Version: $VER/" build/DEBIAN/control
mkdir -p build/DEBIAN
cat > build/DEBIAN/postinst <<EOF
#!/bin/sh
set -e
# 旧版（1.0/1.1）用 BLELogger.* 这套文件名，升级时清掉，避免两个 dylib 同时注入
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/BLELogger.dylib
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/BLELogger.plist
rm -rf /var/jb/Library/PreferenceBundles/BLELoggerPrefs.bundle
rm -f /var/jb/Library/PreferenceLoader/Preferences/BLELogger.plist
killall -9 Preferences 2>/dev/null || true
echo ""
echo "=== BLE Logger ${VER} ==="
echo "设置 -> BLE Logger：打开总开关，勾选要抓包的 App（不勾 = 全部）"
echo "RootHide 用户：把目标 App 加进 RootHide 注入白名单"
echo "然后从后台划掉目标 App，重新打开"
echo ""
exit 0
EOF
cat > build/DEBIAN/postrm <<'EOF'
#!/bin/sh
set -e
case "$1" in
  purge)
    rm -f /var/mobile/Library/Preferences/ble-capture.log
    rm -f /var/mobile/Library/Preferences/com.qwq.blelogger.plist
    ;;
  remove)
    rm -f /var/mobile/Library/Preferences/ble-capture.log
    ;;
esac
exit 0
EOF
chmod 0755 build/DEBIAN/postinst build/DEBIAN/postrm
chmod 0644 build/DEBIAN/control

dpkg-deb --build --root-owner-group build "com.qwq.blelogger_${VER}_iphoneos-arm64.deb"
echo "OK -> com.qwq.blelogger_${VER}_iphoneos-arm64.deb"
