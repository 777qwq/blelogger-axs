#!/bin/bash
# 把已编译好的二进制打包成 deb。build-local.sh（Linux）与
# build-macos.sh（Xcode，能出 arm64e）共用这一段，避免两份逻辑漂移。
#
# 输入：$BIN_DIR 下的 AxsBLELogger.dylib 与 AxsBLELoggerPrefs
set -e
cd "$(dirname "$0")/.."

VER=${VER:-1.4.0}
BIN_DIR=${BIN_DIR:-/tmp/axsbuild}
DEB="com.qwq.blelogger_${VER}_iphoneos-arm64.deb"

[ -f "$BIN_DIR/AxsBLELogger.dylib" ] || { echo "缺少 $BIN_DIR/AxsBLELogger.dylib"; exit 1; }
[ -f "$BIN_DIR/AxsBLELoggerPrefs" ] || { echo "缺少 $BIN_DIR/AxsBLELoggerPrefs"; exit 1; }

DL=build/var/jb/Library/MobileSubstrate/DynamicLibraries
PB=build/var/jb/Library/PreferenceBundles/AxsBLELoggerPrefs.bundle
PL=build/var/jb/Library/PreferenceLoader/Preferences
rm -rf build
mkdir -p "$DL" "$PB" "$PL" build/DEBIAN

cp "$BIN_DIR/AxsBLELogger.dylib" "$DL/AxsBLELogger.dylib"
cp AxsBLELogger.plist "$DL/AxsBLELogger.plist"
chmod 0755 "$DL/AxsBLELogger.dylib"
chmod 0644 "$DL/AxsBLELogger.plist"

cp "$BIN_DIR/AxsBLELoggerPrefs" "$PB/AxsBLELoggerPrefs"
cp AxsBLELoggerPrefs/Resources/Info.plist "$PB/Info.plist"
cp AxsBLELoggerPrefs/Resources/icon@2x.png "$PB/icon@2x.png"
# Preferences 按 "icon" 找 icon.png，直接用 @2x 那份顶上
cp AxsBLELoggerPrefs/Resources/icon@2x.png "$PB/icon.png"
chmod 0755 "$PB/AxsBLELoggerPrefs"

cp layout/Library/PreferenceLoader/Preferences/AxsBLELoggerPrefs.plist "$PL/AxsBLELoggerPrefs.plist"
chmod 0644 "$PL/AxsBLELoggerPrefs.plist"

cp control build/DEBIAN/control
sed -i.bak "s/^Version: .*/Version: $VER/" build/DEBIAN/control && rm -f build/DEBIAN/control.bak

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
echo "设置 -> BLE Logger：打开开关，填目标设备名（例如 iKF-Air Clip-APP）"
echo "插件在 SpringBoard 里自己扫描、连接、订阅，目标设备不需要有 App"
echo "改完配置 1-2 秒内生效，不用重启"
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
    rm -f /var/mobile/Library/Preferences/com.qwq.blelogger.capture.plist
    ;;
  remove)
    rm -f /var/mobile/Library/Preferences/ble-capture.log
    rm -f /var/mobile/Library/Preferences/com.qwq.blelogger.capture.plist
    ;;
esac
exit 0
EOF

chmod 0755 build/DEBIAN/postinst build/DEBIAN/postrm
chmod 0644 build/DEBIAN/control

rm -f "$DEB"
dpkg-deb --build --root-owner-group build "$DEB" >/dev/null
echo "OK -> $DEB"

# 架构自检：Settings 是 arm64e，面板缺 arm64e 切片会在设置里报
# "incompatible architecture (have 'arm64', need 'arm64e')"
if command -v llvm-lipo >/dev/null 2>&1; then
  LIPO=llvm-lipo
elif command -v lipo >/dev/null 2>&1; then
  LIPO=lipo
fi
if [ -n "$LIPO" ]; then
  for f in "$DL/AxsBLELogger.dylib" "$PB/AxsBLELoggerPrefs"; do
    INFO=$($LIPO -info "$f" 2>&1)
    echo "  $(basename "$f"): ${INFO#*are: }"
    case "$INFO" in
      *arm64e*) ;;
      *) echo "  !! 警告：$(basename "$f") 没有 arm64e 切片，arm64e 设备上会加载失败" ;;
    esac
  done
fi
