#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodebuild >/dev/null || { echo "Install Xcode on a Mac first." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Install XcodeGen (brew install xcodegen)." >&2; exit 1; }
xcodegen generate
xcodebuild -project Podium.xcodeproj -scheme Podium -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build-8gib \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' build
app="$PWD/build-8gib/Build/Products/Release-iphoneos/Podium.app"
test -d "$app"
package_dir="$(mktemp -d "$PWD/build-8gib/package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir "$package_dir/Payload"
ditto "$app" "$package_dir/Payload/Podium.app"
ditto -c -k --keepParent "$package_dir/Payload" "$PWD/Podium-0.1.0-8GiB-unsigned.ipa"
echo "Created $PWD/Podium-0.1.0-8GiB-unsigned.ipa; sign it with your sideloading tool before installing."
