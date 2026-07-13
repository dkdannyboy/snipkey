#!/bin/zsh
# Builds SnipKey.app into dist/ and optionally installs it to /Applications.
# Usage: scripts/build-app.sh [--install]
#
# 서명 방식은 키체인에 있는 인증서를 보고 자동으로 정해진다:
#
#   Developer ID Application  →  배포용. 다른 맥에서도 열리고, 공증까지 갈 수 있다.
#   Apple Development         →  로컬 개발용. 배포는 못 하지만 팀 ID가 박히므로
#                                재빌드해도 접근성 권한이 유지된다.
#   (없음)                    →  ad-hoc 폴백. 재빌드할 때마다 macOS가 다른 앱으로
#                                취급하므로 접근성 권한을 매번 다시 줘야 한다.
#
# SNIPKEY_SIGN_ID 환경변수로 특정 인증서를 강제할 수 있다.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$ROOT/dist"
APP="$DIST/SnipKey.app"
ENTITLEMENTS="$ROOT/scripts/SnipKey.entitlements"

# ── 서명 인증서 선택 ────────────────────────────────────────────────────────
# find-identity 출력 한 줄 예시:
#   1) ABC123... "Developer ID Application: Myungho Kim (Z5LK2D7ZGX)"
# 매치가 없으면 grep이 1을 반환한다. set -e/pipefail 아래에서는 그 자체로
# 스크립트를 죽이므로, 빈 문자열을 정상 결과로 삼아 폴백이 돌게 한다.
pick_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "\"$1" \
    | head -1 \
    | sed -E 's/.*"(.*)".*/\1/' \
    || true
}

SIGN_ID="${SNIPKEY_SIGN_ID:-}"

if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID=$(pick_identity "Developer ID Application")

  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID=$(pick_identity "Apple Development")
  fi

  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
  fi
fi

# tier는 인증서 이름에서 도출한다. 그래야 SNIPKEY_SIGN_ID로 Developer ID를
# 직접 지정한 경우에도 배포 빌드와 동일하게 신뢰 타임스탬프가 붙는다.
case "$SIGN_ID" in
  "Developer ID Application"*) SIGN_TIER="developer-id" ;;
  "-")                         SIGN_TIER="adhoc" ;;
  *)                           SIGN_TIER="development" ;;
esac

# ── 빌드 ────────────────────────────────────────────────────────────────────
echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/SnipKey" "$APP/Contents/MacOS/SnipKey"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"

if [[ ! -f "$DIST/AppIcon.icns" ]]; then
  echo "▸ Generating app icon…"
  swift "$ROOT/scripts/make-icon.swift" "$DIST"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ── 서명 ────────────────────────────────────────────────────────────────────
if [[ "$SIGN_TIER" == "adhoc" ]]; then
  echo "▸ Code signing (ad-hoc)…"
  codesign --force --sign - "$APP"
else
  echo "▸ Code signing ($SIGN_TIER): $SIGN_ID"
  # 하드닝 런타임은 공증의 전제 조건이다. 개발 빌드에도 똑같이 켜 두어야
  # 배포 빌드에서만 뒤늦게 터지는 런타임 차이를 만들지 않는다.
  sign_args=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID")
  # 신뢰 타임스탬프는 공증에 필수지만 네트워크를 타므로 배포 빌드에만 붙인다.
  if [[ "$SIGN_TIER" == "developer-id" ]]; then
    sign_args+=(--timestamp)
  fi
  codesign "${sign_args[@]}" "$APP"
fi

codesign --verify --strict "$APP"
echo "▸ Built: $APP"

if [[ "$SIGN_TIER" == "adhoc" ]]; then
  echo ""
  echo "  경고: 서명할 인증서가 없어 ad-hoc으로 서명했다."
  echo "  이 빌드는 재빌드할 때마다 접근성 권한이 초기화된다."
  echo "  Xcode에 Apple ID를 로그인해 인증서를 발급받으면 해결된다."
  echo ""
fi

# ── 설치 ────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications…"
  # 실행 중인 복사본을 먼저 종료해야 바이너리를 교체할 수 있다.
  osascript -e 'tell application "SnipKey" to quit' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/SnipKey.app"
  cp -R "$APP" "/Applications/SnipKey.app"
  echo "▸ Installed: /Applications/SnipKey.app"
fi
