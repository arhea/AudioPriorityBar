#!/bin/bash
set -euo pipefail

# Runs the unit tests. They drive a fake CoreAudio, so they never touch your real audio
# devices or settings.
xcodebuild test \
  -scheme AudioPriorityBar \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${DERIVED_DATA:-.build}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  "$@"
