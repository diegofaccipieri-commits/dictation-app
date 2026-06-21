#!/bin/bash

set -euo pipefail

LOG_DIR="${HOME}/Library/Logs/DictationApp"
mkdir -p "${LOG_DIR}"

SESSION_FILE="${LOG_DIR}/collector-session.log"
STREAM_FILE="${LOG_DIR}/unified-stream.log"

{
    echo "----- collector started $(date -Iseconds) -----"
    echo "user=$(id -un)"
    echo "app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/DictationApp.app/Contents/Info.plist 2>/dev/null || echo unknown)"
    echo "build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/DictationApp.app/Contents/Info.plist 2>/dev/null || echo unknown)"
    /usr/bin/pgrep -fl 'DictationApp|whisper-server' || true
} >> "${SESSION_FILE}" 2>&1

exec /usr/bin/log stream \
    --style compact \
    --predicate 'process == "DictationApp" OR process == "whisper-server" OR eventMessage CONTAINS[c] "DictationApp:"' \
    >> "${STREAM_FILE}" 2>&1
