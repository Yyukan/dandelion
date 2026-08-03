#!/usr/bin/env bash
#
# release.sh - Build a Release Dandelion.app and package it for a GitHub Release.
#
# Builds a Release configuration and zips Dandelion.app into Dandelion.zip
# in the repo root, then prints its sha256 - the two things needed to
# publish a GitHub Release that Casks/dandelion.rb can install via Homebrew:
#
#   1. Create a GitHub Release tagged v<version> (matching `version` in
#      Casks/dandelion.rb) and attach the generated Dandelion.zip to it.
#   2. Replace `sha256 :no_check` in Casks/dandelion.rb with the printed hash.
#
# Usage:
#   ./release.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Generating Xcode project (xcodegen)..."
xcodegen generate

echo "==> Building Dandelion (Release)..."
xcodebuild -project Dandelion.xcodeproj -scheme Dandelion -configuration Release build

APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Dandelion-*/Build/Products/Release/Dandelion.app | head -n 1)

echo "==> Zipping ${APP_PATH}..."
rm -f Dandelion.zip
# ditto (not zip -r) preserves the app bundle's code signature, symlinks and
# resource forks, which a plain zip of the directory would mangle.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" Dandelion.zip

echo "==> sha256 (put this in Casks/dandelion.rb):"
shasum -a 256 Dandelion.zip

echo "==> Done. Attach Dandelion.zip to a GitHub Release tagged to match"
echo "    the Cask's version, then update sha256 in Casks/dandelion.rb."
