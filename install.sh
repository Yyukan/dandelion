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
cp -R ~/Library/Developer/Xcode/DerivedData/Dandelion-*/Build/Products/Release/Dandelion.app /Applications/

echo "==> Launching Dandelion..."
open /Applications/Dandelion.app

echo "==> Done."
