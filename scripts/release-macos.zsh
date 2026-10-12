#!/bin/zsh
set -eu
task_root=${0:A:h:h}
release_version=${1:-v0.1.0-alpha.1}
build_number=${2:-1}
[[ "$release_version" =~ '^v?[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$' ]]
[[ "$build_number" =~ '^[0-9]+$' ]]
version_number=${release_version#v}
release_root="$task_root/artifacts/releases/$release_version"
mkdir -p "$release_root"
xcodebuild -project "$task_root/macos/ShareMouse.xcodeproj" -scheme ShareMouse \
  -configuration Release -derivedDataPath "$release_root/macos-build" -jobs 2 \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO SWIFT_OPTIMIZATION_LEVEL=-O \
  ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO build > "$release_root/macos-build.log" 2>&1
app_bundle="$release_root/macos-build/Build/Products/Release/ShareMouse.app"
plist="$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version_number%%-alpha.*}" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Set :ShareMouseDistributionVersion $release_version" "$plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :ShareMouseDistributionVersion string $release_version" "$plist"
signing_identity=${SHAREMOUSE_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning | rg '"Developer ID Application:' | awk 'NR == 1 {print $2}' || true)
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning | rg '"Apple Development:' | awk 'NR == 1 {print $2}' || true)
fi
[[ -n "$signing_identity" ]] || signing_identity="-"
codesign --force --sign "$signing_identity" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
lipo "$app_bundle/Contents/MacOS/ShareMouse" -verify_arch arm64 x86_64
for resource in tools.json bridge.py computer_client.py keyboard-layouts.json keyboard-icons.svg; do
  [[ -f "$app_bundle/Contents/Resources/$resource" ]]
done
stage=$(mktemp -d "$release_root/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app_bundle" "$stage/ShareMouse.app"
ln -s /Applications "$stage/Applications"
cp "$task_root/packaging/INSTALLING.md" "$stage/INSTALLING.md"
hdiutil create -ov -volname "ShareMouse $release_version" -srcfolder "$stage" \
  -format UDZO -imagekey zlib-level=9 "$release_root/ShareMouse-$release_version-macos-universal.dmg"
hdiutil verify "$release_root/ShareMouse-$release_version-macos-universal.dmg"
codesign -dv --verbose=2 "$app_bundle" 2> "$release_root/macos-signature.log"
print -r -- "DMG: $release_root/ShareMouse-$release_version-macos-universal.dmg"
