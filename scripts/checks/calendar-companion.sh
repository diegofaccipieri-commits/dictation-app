#!/bin/bash
# Compila o CalendarCompanion isolado e roda os cenários de instalação em pastas temporárias.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp DictationApp/CalendarCompanion.swift "$WORK/CalendarCompanion.swift"
cp scripts/checks/calendar-companion-main.swift "$WORK/main.swift"
swiftc -swift-version 5 "$WORK/CalendarCompanion.swift" "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"
