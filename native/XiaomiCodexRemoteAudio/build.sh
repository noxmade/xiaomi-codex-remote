#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$ROOT/.build"
SOURCE_ROOT="$WORK_DIR/BlackHole"

OUTPUT="$ROOT/MiCodexRemote2ch.driver"

PRODUCT_NAME="MiCodexRemote2ch"
BUNDLE_ID="com.micodexremote.audio2ch"
DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"MiCodexRemote\" kDevice_Name=\"MiCodexRemote\" kPlugIn_BundleID=\"com.micodexremote.audio2ch\" kNumber_Of_Channels=2'

echo "Cleaning up..."
rm -rf "$WORK_DIR" "$OUTPUT"
mkdir -p "$WORK_DIR"

if [ -n "${BLACKHOLE_SOURCE_DIR:-}" ]; then
  echo "Using supplied BlackHole source..."
  cp -R "$BLACKHOLE_SOURCE_DIR" "$SOURCE_ROOT"
else
  echo "Cloning BlackHole v0.7.1..."
  git clone --depth 1 --branch v0.7.1 https://github.com/ExistentialAudio/BlackHole.git "$SOURCE_ROOT"
fi

echo "Updating COM Plugin UUID to avoid conflicts..."
sed -i '' 's/e395c745-4eea-4d94-bb92-46224221047c/11994d37-7b40-4221-a654-ca2651b400d8/g' "$SOURCE_ROOT/BlackHole/BlackHole.plist"

echo "Building driver using xcodebuild..."
xcodebuild \
  -project "$SOURCE_ROOT/BlackHole.xcodeproj" \
  -target BlackHole \
  -configuration Release \
  -sdk macosx \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_NAME="$PRODUCT_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  GCC_PREPROCESSOR_DEFINITIONS="$DEFINITIONS" \
  build

echo "Copying built driver to $OUTPUT..."
cp -R "$SOURCE_ROOT/build/Release/$PRODUCT_NAME.driver" "$OUTPUT"
strip -S "$OUTPUT/Contents/MacOS/$PRODUCT_NAME"

echo "Signing driver (ad-hoc)..."
codesign --force --deep --sign - --timestamp=none "$OUTPUT"

# Ship the exact modified source together with its build/install scripts.
SOURCE_PACKAGE="$ROOT/MiCodexRemote-source.tar.gz"
SOURCE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/micodex-source.XXXXXX")"
trap 'rm -rf "$SOURCE_STAGE"' EXIT
mkdir -p "$SOURCE_STAGE/MiCodexRemote-source/BlackHole"
tar -C "$SOURCE_ROOT" --exclude=.git --exclude=build -cf - . | tar -C "$SOURCE_STAGE/MiCodexRemote-source/BlackHole" -xf -
cp "$ROOT/build.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$SOURCE_STAGE/MiCodexRemote-source/"
cp "$SOURCE_ROOT/LICENSE" "$ROOT/LICENSE-GPLv3.txt"
printf '%s\n' \
  'MiCodexRemote is based on BlackHole v0.7.1 (Existential Audio), licensed under GPLv3.' \
  'Modifications: driver/device names, bundle ID, two-channel build configuration, COM plugin UUID.' \
  "Source prepared: $(date -u +%Y-%m-%d)." \
  'Rebuild on macOS with Xcode: BLACKHOLE_SOURCE_DIR="$PWD/BlackHole" bash build.sh' \
  'Installation scripts are included; installation requires explicit administrator authorization.' \
  > "$SOURCE_STAGE/MiCodexRemote-source/README.txt"
cp "$SOURCE_STAGE/MiCodexRemote-source/README.txt" "$ROOT/DRIVER-NOTICE.txt"
tar -C "$SOURCE_STAGE" -czf "$SOURCE_PACKAGE" MiCodexRemote-source
(cd "$ROOT" && shasum -a 256 MiCodexRemote2ch.driver/Contents/MacOS/MiCodexRemote2ch MiCodexRemote-source.tar.gz LICENSE-GPLv3.txt DRIVER-NOTICE.txt > DriverResources.sha256)

echo "Successfully built $OUTPUT."
echo ""
echo "To install the driver, you can run:"
echo "  sudo bash \"$ROOT/install.sh\""
