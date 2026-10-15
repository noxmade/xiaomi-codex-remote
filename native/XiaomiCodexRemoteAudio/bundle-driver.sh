#!/usr/bin/env bash
set -euo pipefail

DRIVER_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_DEST="${1:?Usage: bundle-driver.sh APP_RESOURCES_DIRECTORY}"

# A release must not silently omit the voice dependency or corresponding source.
for resource in MiCodexRemote2ch.driver MiCodexRemote-source.tar.gz LICENSE-GPLv3.txt DRIVER-NOTICE.txt DriverResources.sha256; do
  if [ ! -e "$DRIVER_ROOT/$resource" ]; then
    bash "$DRIVER_ROOT/build.sh"
    break
  fi
done
(cd "$DRIVER_ROOT" && shasum -a 256 -c DriverResources.sha256)
codesign --verify --deep --strict "$DRIVER_ROOT/MiCodexRemote2ch.driver"
tar -tzf "$DRIVER_ROOT/MiCodexRemote-source.tar.gz" >/dev/null
mkdir -p "$RESOURCE_DEST"
if [ -d "$RESOURCE_DEST/MiCodexRemote2ch.driver" ]; then
  # Validated exact driver destination, never the containing Resources directory.
  rm -rf "$RESOURCE_DEST/MiCodexRemote2ch.driver"
fi
cp -R "$DRIVER_ROOT/MiCodexRemote2ch.driver" "$RESOURCE_DEST/"
cp "$DRIVER_ROOT/MiCodexRemote-source.tar.gz" "$DRIVER_ROOT/LICENSE-GPLv3.txt" "$DRIVER_ROOT/DRIVER-NOTICE.txt" "$DRIVER_ROOT/DriverResources.sha256" "$RESOURCE_DEST/"
