#!/bin/bash
# Builds "Chup Setup.app" with nothing but the Command Line Tools -- no Xcode project,
# no Apple Developer account. The binary is ad-hoc signed, which is all macOS needs to
# run an app that was built here on this Mac.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
BUILD=build
rm -rf "$BUILD" dist
mkdir -p "$BUILD"

# Universal binary, so it also runs on an Intel staff Mac.
for ARCH in arm64 x86_64; do
    echo "--- building $ARCH"
    swiftc -O -parse-as-library -swift-version 5 \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos13.0" \
        -o "$BUILD/chup-setup-$ARCH" \
        Sources/*.swift
done

lipo -create -output "$BUILD/chup-setup" "$BUILD/chup-setup-arm64" "$BUILD/chup-setup-x86_64"

APP="dist/Chup Setup.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/chup-setup" "$APP/Contents/MacOS/chup-setup"
cp Info.plist "$APP/Contents/Info.plist"
cp ../tv-setup.sh "$APP/Contents/Resources/tv-setup.sh"

# What the guided steps look like on a real box, captured with adb shell screencap and cropped
# to the half of the frame that has something in it. Optional: the app shows a step without one.
if compgen -G "screenshots/*.png" >/dev/null; then
    cp screenshots/*.png "$APP/Contents/Resources/"
fi

# The icon is rendered from make-icon.swift so there is no design tool in the loop.
if swiftc -O -parse-as-library -swift-version 5 -sdk "$SDK" -target arm64-apple-macos13.0 \
        -o "$BUILD/make-icon" make-icon.swift 2>/dev/null \
    && "$BUILD/make-icon" "$BUILD/AppIcon.iconset" >/dev/null \
    && iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
then
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: could not build the app icon, carrying on without it"
fi

# Ad-hoc signature: identifies the app as-is, no certificate needed.
codesign --force --sign - "$APP"

echo
echo "Built: $PWD/$APP"
file "$APP/Contents/MacOS/chup-setup"
codesign --verify --verbose=2 "$APP"
