#!/bin/bash
set -euo pipefail

# Signing and notarization are driven by environment variables:
#
#   DEVELOPER_ID_TEAM   Apple team ID. When set, signs with the "Developer ID Application"
#                       certificate for that team; otherwise the build is ad-hoc signed.
#   NOTARY_PROFILE      notarytool keychain profile (from `xcrun notarytool store-credentials`), or
#   NOTARY_KEY_PATH     App Store Connect API key (.p8) plus NOTARY_KEY_ID and NOTARY_ISSUER_ID.
#                       Either one notarizes and staples the app. Requires DEVELOPER_ID_TEAM.

APP="dist/AudioPriorityBar.app"
TEAM="${DEVELOPER_ID_TEAM:-}"

NOTARY_MODE=""
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_MODE="profile"
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_MODE="key"
fi
if [[ -n "$NOTARY_MODE" && -z "$TEAM" ]]; then
  echo "error: notarization needs a Developer ID build; set DEVELOPER_ID_TEAM" >&2
  exit 1
fi

if [[ -n "$TEAM" ]]; then
  echo "Building AudioPriorityBar (Developer ID, team $TEAM)..."
  SIGN_IDENTITY="Developer ID Application"
  SIGN_FLAGS="--timestamp"
else
  echo "Building AudioPriorityBar (ad-hoc signed)..."
  # Ad-hoc ("-") rather than unsigned: the hardened runtime only applies to signed code, and
  # macOS attaches notification permission to the app's code signature.
  SIGN_IDENTITY="-"
  SIGN_FLAGS=""
fi

xcodebuild -scheme AudioPriorityBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  build

mkdir -p dist
rm -rf "$APP"
cp -R .build/Build/Products/Release/AudioPriorityBar.app dist/

codesign --verify --strict "$APP"

if [[ -n "$NOTARY_MODE" ]]; then
  echo "Submitting for notarization..."
  SUBMISSION="dist/AudioPriorityBar-notarize.zip"
  ditto -c -k --keepParent "$APP" "$SUBMISSION"

  # Keep going on a failed submission so the output (and its ID, for `notarytool log`) is shown.
  if [[ "$NOTARY_MODE" == "profile" ]]; then
    RESULT=$(xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" \
      --wait --timeout 30m --output-format json) || true
  else
    RESULT=$(xcrun notarytool submit "$SUBMISSION" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json) || true
  fi
  rm -f "$SUBMISSION"
  echo "$RESULT"

  STATUS=$(plutil -extract status raw -o - - <<<"$RESULT" 2>/dev/null || true)
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization was not accepted; run \`xcrun notarytool log <id>\` for details" >&2
    exit 1
  fi

  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo ""
echo "Build complete: $APP"
