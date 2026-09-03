#!/usr/bin/env bash
# ConnorPet release 빌드를 독립 실행형 .app 번들로 감싸서 설치한다.
#
# `swift run`은 바이너리를 셸의 자식 프로세스로 띄우기 때문에 터미널을 닫으면
# 펫도 같이 죽는다. 이 스크립트로 만든 .app은 Finder/Spotlight에서 실행하는
# 일반 앱이라 터미널과 무관하게 계속 떠 있다.
#
#   ./scripts/make_app.sh              # ~/Applications 에 설치 (기본값)
#   ./scripts/make_app.sh /Applications  # 설치 위치 지정
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/ConnorPet"
INSTALL_DIR="${1:-$HOME/Applications}"
APP="$INSTALL_DIR/ConnorPet.app"

BUNDLE_ID="io.github.pet-egg.connorpet"

echo "▸ release 빌드"
swift build -c release --package-path "$PACKAGE_DIR"
BIN_DIR="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)"

# 리소스는 Bundle.module로 읽으므로 SwiftPM이 만든 리소스 번들을 반드시 같이
# 넣어야 한다. 바이너리만 복사하면 스프라이트를 못 찾아 실행 즉시 죽는다.
RESOURCE_BUNDLE="$BIN_DIR/ConnorPet_ConnorPet.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "✗ 리소스 번들을 찾을 수 없음: $RESOURCE_BUNDLE" >&2
  exit 1
fi

# 교체 대상이 실행 중이면 먼저 종료 (실행 중인 번들을 덮어쓰면 앱이 이상해진다)
if pgrep -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' >/dev/null; then
  echo "▸ 실행 중인 ConnorPet 종료"
  pkill -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' || true
  # 프로세스가 완전히 빠지기를 잠깐 기다린다
  for _ in 1 2 3 4 5; do
    pgrep -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' >/dev/null || break
    sleep 0.3
  done
fi

echo "▸ 번들 생성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ConnorPet" "$APP/Contents/MacOS/ConnorPet"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ConnorPet</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>ConnorPet</string>
	<key>CFBundleDisplayName</key>
	<string>ConnorPet</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<!-- Dock/앱 스위처에 안 뜨는 메뉴바 유틸리티 (코드의 .accessory 정책과 동일 의도) -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# 번들을 복사·이동해도 "손상된 앱" 경고가 뜨지 않도록 ad-hoc 서명.
# 로컬 전용이라 Developer ID 서명·notarization은 필요 없다.
echo "▸ ad-hoc 서명"
codesign --force --sign - "$APP"

echo
echo "✓ 설치 완료: $APP"
echo "  실행: open -a \"$APP\""
echo "  종료: 메뉴바 포켓볼 아이콘 → Quit"
