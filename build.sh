#!/bin/bash
set -euo pipefail

echo "Building AudioPriorityBar..."

# Ad-hoc sign ("-") instead of shipping unsigned: the hardened runtime only applies to signed
# code, and macOS attaches notification permission to the app's code signature.
xcodebuild -scheme AudioPriorityBar \
  -configuration Release \
  -derivedDataPath .build \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build

mkdir -p dist
rm -rf dist/AudioPriorityBar.app
cp -R .build/Build/Products/Release/AudioPriorityBar.app dist/

codesign --verify --strict dist/AudioPriorityBar.app

echo ""
echo "Build complete: dist/AudioPriorityBar.app"
