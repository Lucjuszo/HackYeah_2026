#!/usr/bin/env bash
# Build Flutter web na Renderze (Static Site nie ma Fluttera, więc pobieramy SDK).
set -euo pipefail

FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.6}"
API_URL="${API_URL:?Ustaw API_URL na adres backendu}"
FLUTTER_DIR="$HOME/flutter-$FLUTTER_VERSION"

if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"

flutter --disable-analytics
flutter config --enable-web
flutter pub get
flutter build web --release --dart-define=API_URL="$API_URL"
