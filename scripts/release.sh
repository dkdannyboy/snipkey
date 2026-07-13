#!/bin/zsh
# 배포용 SnipKey.dmg를 만든다: Developer ID 서명 → Apple 공증 → 티켓 스테이플.
# Usage: scripts/release.sh
#
# 결과물(dist/SnipKey-<버전>.dmg)은 아무 맥에나 복사해서 열 수 있다.
# Gatekeeper 경고도, "확인되지 않은 개발자" 우회도 필요 없다.
#
# 전제 조건 두 가지:
#
#   1. 키체인에 "Developer ID Application" 인증서가 있을 것
#      (Apple Developer Program 유료 멤버십 필요)
#
#   2. 공증 자격증명이 키체인 프로파일로 저장되어 있을 것. 최초 1회:
#
#        xcrun notarytool store-credentials snipkey-notary \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID" \
#          --password "app-specific-password"
#
#      앱 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호에서 발급한다.
#      Apple ID 본 암호가 아니다.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$ROOT/dist"
APP="$DIST/SnipKey.app"
STAGE="$DIST/dmg-stage"
NOTARY_PROFILE="${SNIPKEY_NOTARY_PROFILE:-snipkey-notary}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/scripts/Info.plist")
DMG="$DIST/SnipKey-$VERSION.dmg"

# ── 전제 조건 확인 ──────────────────────────────────────────────────────────
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)

if [[ -z "$SIGN_ID" ]]; then
  echo "✗ 키체인에 Developer ID Application 인증서가 없다."
  echo ""
  echo "  이 인증서는 앱스토어 밖으로 앱을 배포할 때 쓰는 유일한 수단이며,"
  echo "  Apple Developer Program 유료 멤버십이 있어야 발급된다."
  echo ""
  echo "  발급: Xcode → Settings → Accounts → 계정 선택 →"
  echo "        Manage Certificates → + → Developer ID Application"
  echo ""
  echo "  이미 다른 맥에서 발급받았다면 그 맥의 '키체인 접근'에서 해당 인증서를"
  echo "  개인 키까지 포함해 .p12로 내보낸 뒤 이 맥에서 열면 된다."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ 공증 자격증명 프로파일 '$NOTARY_PROFILE'을 찾을 수 없다."
  echo ""
  echo "  최초 1회 저장이 필요하다:"
  echo ""
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "      --apple-id \"<Apple ID 이메일>\" \\"
  echo "      --team-id \"<팀 ID>\" \\"
  echo "      --password \"<앱 암호>\""
  echo ""
  echo "  앱 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호에서 발급한다."
  exit 1
fi

echo "▸ Developer ID: $SIGN_ID"
echo "▸ 버전: $VERSION"

# ── 1. Developer ID로 빌드 ──────────────────────────────────────────────────
# build-app.sh가 인증서 이름에서 tier를 도출하므로, Developer ID를 넘기면
# 하드닝 런타임 + entitlements + 신뢰 타임스탬프가 모두 붙는다. 공증의 전제다.
SNIPKEY_SIGN_ID="$SIGN_ID" zsh "$ROOT/scripts/build-app.sh"

# ── 2. 앱 공증 ──────────────────────────────────────────────────────────────
# 공증은 아카이브만 받는다. 앱 자체에 티켓을 박아야 오프라인에서도 검증된다.
ZIP="$DIST/SnipKey-notarize.zip"
rm -f "$ZIP"
echo "▸ 공증용 아카이브 생성…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ 앱 공증 요청 (Apple 서버 응답까지 몇 분 걸린다)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

echo "▸ 앱에 공증 티켓 스테이플…"
xcrun stapler staple "$APP"

# ── 3. DMG 생성 ─────────────────────────────────────────────────────────────
echo "▸ DMG 생성…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/SnipKey.app"
# 드래그 앤 드롭 설치를 위한 /Applications 바로가기.
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "SnipKey" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

# ── 4. DMG 서명 및 공증 ─────────────────────────────────────────────────────
# DMG 자체에도 티켓이 있어야 내려받은 이미지를 열 때 경고가 뜨지 않는다.
echo "▸ DMG 서명…"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "▸ DMG 공증 요청…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ DMG에 공증 티켓 스테이플…"
xcrun stapler staple "$DMG"

# ── 5. 최종 검증 ────────────────────────────────────────────────────────────
echo ""
echo "▸ Gatekeeper 검증…"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo ""
echo "✓ 배포 준비 완료: $DMG"
echo "  이 파일은 어느 맥에 옮겨도 경고 없이 열린다."
