#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
flutter pub get
flutter analyze
flutter test
flutter build ipa --release --no-codesign

echo "iOS 构建完成：build/ios/archive/Runner.xcarchive"
