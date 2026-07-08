#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodeDerivedData"

xcodebuild \
  -project "$ROOT_DIR/Context-Dock.xcodeproj" \
  -scheme Context-Dock \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}" \
  build
# Default is SIGNED (Apple Development): unsigned ad-hoc builds have no stable
# designated requirement, so macOS re-prompts Accessibility/Keychain on every
# launch — deadly for an AX-driven app. Export CODE_SIGNING_ALLOWED=NO only for
# environments without the signing cert (CI).
