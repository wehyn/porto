#!/bin/zsh
set -euo pipefail

script_path="${0:A}"
repo_root="${script_path:h:h}"
output_dir="${1:-$repo_root/dist}"

if [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi

derived_data="$repo_root/.build/PortoRelease"
project="$repo_root/Porto.xcodeproj"

cd "$repo_root"

command -v xcodegen >/dev/null 2>&1 || {
    print -u2 "XcodeGen is required. Install XcodeGen 2.46.0 or a compatible release."
    exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
    print -u2 "Xcode is required to build Porto."
    exit 1
}

expected_xcode_build="${PORTO_EXPECTED_XCODE_BUILD:-}"
if [[ -n "$expected_xcode_build" ]]; then
    actual_xcode_build="$(xcodebuild -version | awk '/^Build version/{print $3}')"
    [[ "$actual_xcode_build" == "$expected_xcode_build" ]] || {
        print -u2 "Unsupported Xcode build: $actual_xcode_build (expected $expected_xcode_build)"
        exit 1
    }
fi

xcodegen generate
xcodebuild \
    -project "$project" \
    -scheme Porto \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    clean build \
    CODE_SIGNING_ALLOWED=NO

app_path="$derived_data/Build/Products/Release/Porto.app"
binary_path="$app_path/Contents/MacOS/Porto"
info_plist="$app_path/Contents/Info.plist"

[[ -d "$app_path" ]] || { print -u2 "Release app was not produced: $app_path"; exit 1; }
[[ -x "$binary_path" ]] || { print -u2 "Release executable was not produced: $binary_path"; exit 1; }
[[ -f "$info_plist" ]] || { print -u2 "Release Info.plist was not produced: $info_plist"; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
[[ -n "$version" ]] || { print -u2 "Release app has no bundle version."; exit 1; }
[[ "$bundle_id" == 'dev.wayne.porto' ]] || {
    print -u2 "Unexpected bundle identifier: $bundle_id"
    exit 1
}

archs="$(lipo -archs "$binary_path")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || {
    print -u2 "Expected universal arm64+x86_64 executable; got: $archs"
    exit 1
}

mkdir -p "$output_dir"
zip_path="$output_dir/Porto-${version}-macOS-universal.zip"
checksum_path="$zip_path.sha256"

ditto --norsrc -c -k --keepParent "$app_path" "$zip_path"
unzip -tq "$zip_path"
shasum -a 256 "$zip_path" > "$checksum_path"

print "Created unsigned/ad-hoc developer release: $zip_path"
print "SHA-256 checksum: $checksum_path"
print "Architectures: $archs"
print "Bundle identifier: $bundle_id"
print "Version: $version"
