#!/usr/bin/env bash
#
# install.sh - Build Dandelion and install it into /Applications.
#
# There's no signed/notarized release or Homebrew Cask yet, so this script
# is the local equivalent: it regenerates the Xcode project, builds a
# Release configuration, copies the resulting Dandelion.app into
# /Applications, and launches it.
#
# Usage:
#   ./install.sh
#
# Since the build isn't notarized, the first launch may need a right-click
# -> Open (or an allow in System Settings -> Privacy & Security) to bypass
# Gatekeeper.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Generating Xcode project (xcodegen)..."
xcodegen generate

echo "==> Building Dandelion (Release)..."
xcodebuild -project Dandelion.xcodeproj -scheme Dandelion -configuration Release build

echo "==> Installing Dandelion.app to /Applications..."
# Quit any running instance and remove the previous bundle outright rather
# than letting `cp -R` merge into it - merging into an existing app bundle
# leaves stale files behind that don't match the freshly-sealed code
# signature, which macOS then kills on launch with a
# "SIGKILL (Code Signature Invalid)" crash.
pkill -x Dandelion 2>/dev/null || true
rm -rf /Applications/Dandelion.app
cp -R ~/Library/Developer/Xcode/DerivedData/Dandelion-*/Build/Products/Release/Dandelion.app /Applications/

echo "==> Launching Dandelion..."
open /Applications/Dandelion.app

echo "==> Done."
