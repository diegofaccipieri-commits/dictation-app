#!/bin/bash
# Usage: ./scripts/release.sh 1.5
# Builds, zips, creates GitHub release, and installs locally.

set -e

VERSION=${1:?Usage: ./scripts/release.sh VERSION}

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DictationApp"
ZIP_NAME="${APP_NAME}_v${VERSION}.zip"

echo "==> Building v${VERSION}..."

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${PROJECT_DIR}/${APP_NAME}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION//./}" \
    "${PROJECT_DIR}/${APP_NAME}/Info.plist"

# Build
xcodebuild -scheme "${APP_NAME}" -configuration Release \
    -derivedDataPath "${PROJECT_DIR}/build" \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    > /dev/null 2>&1

APP_PATH="${PROJECT_DIR}/build/Build/Products/Release/${APP_NAME}.app"

echo "==> Zipping..."
cd "${PROJECT_DIR}/build/Build/Products/Release"
zip -qr "${PROJECT_DIR}/${ZIP_NAME}" "${APP_NAME}.app"
cd "${PROJECT_DIR}"

echo "==> Installing locally to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_PATH}" "/Applications/${APP_NAME}.app"

echo "==> Committing version bump..."
git add "${APP_NAME}/Info.plist"
git commit -m "Bump version to ${VERSION}"
git push

echo "==> Creating GitHub Release v${VERSION}..."
gh release create "v${VERSION}" \
    "${ZIP_NAME}" \
    --title "DictationApp v${VERSION}" \
    --notes "Release v${VERSION}"

rm -f "${ZIP_NAME}"

echo ""
echo "✓ Released v${VERSION} — users will be prompted to update automatically."
