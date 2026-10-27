#!/bin/bash
set -euo pipefail
umask 077

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"
architecture="${PEEKLET_ARCH:-$(uname -m)}"
case "$architecture" in
    arm64|x86_64|universal) ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

build_dir="$project_dir/.build"
if [[ -L "$build_dir" ]]; then
    printf 'Refusing a symlinked build directory.\n' >&2; exit 1
fi
mkdir -p "$build_dir/module-cache"
stage="$(mktemp -d "$build_dir/staging.XXXXXXXX")"
stage_app="$stage/Peeklet.app"
mkdir -p "$stage_app/Contents/MacOS"
cp -X Info.plist "$stage_app/Contents/Info.plist"
plutil -lint "$stage_app/Contents/Info.plist" Entitlements.plist

compile_arch() {
    local arch="$1" output="$2"
    xcrun swiftc -parse-as-library -swift-version 5 -O -module-name Peeklet \
        -target "$arch-apple-macosx13.0" \
        -file-prefix-map "$project_dir=." -debug-prefix-map "$project_dir=." \
        -module-cache-path "$build_dir/module-cache" \
        -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers \
        Peeklet.swift PhotoLibrary.swift SelfTests.swift -o "$output"
}
if [[ "$architecture" == universal ]]; then
    compile_arch arm64 "$stage/Peeklet-arm64"
    compile_arch x86_64 "$stage/Peeklet-x86_64"
    xcrun lipo -create "$stage/Peeklet-arm64" "$stage/Peeklet-x86_64" \
        -output "$stage_app/Contents/MacOS/Peeklet"
else
    compile_arch "$architecture" "$stage_app/Contents/MacOS/Peeklet"
fi

# Remove only Finder presentation metadata from this generated app, if present.
if xattr -p com.apple.FinderInfo "$stage_app" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$stage_app"
fi
codesign --force --sign - --entitlements Entitlements.plist "$stage_app"
codesign --verify --strict "$stage_app"

destination="$build_dir/Peeklet.app"
if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" || ! -f "$destination/Contents/Info.plist" ]] || \
       [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")" != io.github.peeklet.app ]]; then
        printf 'Existing output is not a generated Peeklet app; refusing to replace it.\n' >&2
        exit 1
    fi
    # Keep the previous generated app recoverable inside this build's staging directory.
    mv "$destination" "$stage/Previous-Peeklet.app"
    if ! mv "$stage_app" "$destination"; then
        mv "$stage/Previous-Peeklet.app" "$destination"
        exit 1
    fi
else
    mv "$stage_app" "$destination"
fi
codesign --verify --strict "$destination"
printf 'Built .build/Peeklet.app (%s).\n' "$architecture"
