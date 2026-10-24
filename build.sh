#!/bin/bash
# Собирает DoubleMyDock.app, кладёт её в ~/Applications, запускает
# и делает установочный образ dist/DoubleMyDock.dmg.
set -e
cd "$(dirname "$0")"

NAME=DoubleMyDock
BUILD="build"
APP="$BUILD/$NAME.app"
DMG="dist/$NAME.dmg"

rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "Собираю…"
swiftc -O -target arm64-apple-macos13 -o "$BUILD/arm64" main.swift
swiftc -O -target x86_64-apple-macos13 -o "$BUILD/x86_64" main.swift
lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Делаю $DMG…"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "$CI" ]; then echo "Готово: $DMG"; exit 0; fi

echo "Устанавливаю в ~/Applications и запускаю…"
pkill -x "$NAME" 2>/dev/null || true
rm -rf "$HOME/Applications/$NAME.app"
cp -R "$APP" "$HOME/Applications/"
open "$HOME/Applications/$NAME.app"

echo "Готово."
