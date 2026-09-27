#!/bin/zsh
# Builds keybag_bootstrap for the guest (armv7, iOS 6) and writes it to
# Podium/Resources/GuestTools/keybag_bootstrap.bin, which the app installs
# into the root filesystem it prepares (see RootFilesystemRecipe).
#
# The current SDK has no armv7 slices, hence the hand-written libSystem
# stub; it's built as ARM code because the new linker drops the Thumb bit
# from LC_MAIN, and dyld would enter a Thumb main in ARM state. iOS 6's
# AMFI can't read modern codesign output, so it's signed the old way.
set -e
cd "$(dirname "$0")"
OUT=../../Podium/Resources/GuestTools/keybag_bootstrap.bin
TMP=$(mktemp -d)
xcrun --sdk iphoneos clang -target armv7-apple-ios6.0 -marm -Os -c keybag_bootstrap.c -o "$TMP/keybag_bootstrap.o"
xcrun ld -arch armv7 -platform_version ios 6.0 6.0 -e _main "$TMP/keybag_bootstrap.o" libSystem.tbd -o "$TMP/keybag_bootstrap.unsigned"
xcrun codesign_allocate -i "$TMP/keybag_bootstrap.unsigned" -a armv7 4096 -o "$TMP/keybag_bootstrap"
python3 legacy_adhoc_sign.py "$TMP/keybag_bootstrap" com.podium.keybag_bootstrap entitlements.plist
cp "$TMP/keybag_bootstrap" "$OUT"
rm -rf "$TMP"
echo "wrote $OUT"
