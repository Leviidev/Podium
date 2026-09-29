#!/bin/zsh
# Builds podium_syncd for the guest (armv7, iOS 6) and writes it to
# Podium/Resources/GuestTools/podium_syncd.bin, which the app installs into
# the root file system it prepares. Built and signed like keybag_bootstrap
# (see its build.sh for why).
set -e
cd "$(dirname "$0")"
OUT=../../Podium/Resources/GuestTools/podium_syncd.bin
TMP=$(mktemp -d)
xcrun --sdk iphoneos clang -target armv7-apple-ios6.0 -marm -Os -c podium_syncd.c -o "$TMP/podium_syncd.o"
xcrun ld -arch armv7 -platform_version ios 6.0 6.0 -e _main "$TMP/podium_syncd.o" libSystem.tbd -o "$TMP/podium_syncd.unsigned"
xcrun codesign_allocate -i "$TMP/podium_syncd.unsigned" -a armv7 4096 -o "$TMP/podium_syncd"
python3 ../keybag_bootstrap/legacy_adhoc_sign.py "$TMP/podium_syncd" com.podium.syncd entitlements.plist
cp "$TMP/podium_syncd" "$OUT"
rm -rf "$TMP"
echo "wrote $OUT"
