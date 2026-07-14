#!/bin/zsh
# SnipKey E2E: 실제 키보드 이벤트로 앱 전체를 통과시키는 UI 자동화 하네스.
#
# 유닛 테스트가 닿지 못하는 층(ExpansionEngine / TextInjector / CGEvent tap)을
# 검증한다. TextEdit에 System Events로 진짜 키를 치고, 앱이 그 키를 가로채
# 확장했는지를 (1) 문서에 남은 텍스트와 (2) ~/Library/Logs/SnipKey.log 의
# "inject start" 마커, 두 갈래로 확인한다.
#
# 안전 장치 — 이 스크립트는 사용자의 실물 데이터를 세 가지나 만진다:
#   1) 스니펫 라이브러리 : SNIPKEY_STORE_DIR로 임시 저장소에 격리한다.
#                          진짜 store.json은 열지도, 쓰지도 않는다.
#   2) 클립보드          : 시작할 때 저장하고 trap에서 되돌린다.
#   3) 실행 중인 SnipKey : 종료했다가 끝나면 원래대로 되살린다.
#
# Usage: scripts/e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

APP="/Applications/SnipKey.app"
APP_BIN="$APP/Contents/MacOS/SnipKey"
LOG=~/Library/Logs/SnipKey.log
REAL_STORE=~/Library/Application\ Support/SnipKey/store.json

# 임시 저장소. mktemp -d 라서 사용자의 라이브러리와 절대 겹치지 않는다.
TMP_DIR=$(mktemp -d /tmp/snipkey-e2e.XXXXXX)
CLIP_BACKUP="$TMP_DIR/clipboard.bak"

CLIP_SENTINEL="E2E-CLIPBOARD-SENTINEL"

SNIPKEY_PID=""
SNIPKEY_WAS_RUNNING=0

typeset -a FAILURES
FAILURES=()
typeset -a RESULTS
RESULTS=()

# ── 정리 ────────────────────────────────────────────────────────────────────
# 무슨 일이 있어도 돈다. 하네스가 중간에 죽어도 저장 안 함 모달이나 덮어쓴
# 클립보드를 남기지 않는 것이 목적이다.
cleanup() {
  local code=$?
  set +e
  echo ""
  echo "▸ Cleaning up…"

  # TextEdit: 저장하지 않고 닫는다. saving no 를 빼면 모달이 떠서 다음 실행까지 막는다.
  # 타임아웃을 반드시 건다 — 정리 단계에서 멈추는 것이 가장 나쁘다. 응답이 없으면
  # 강제 종료한다. 저장 안 한 문서는 어차피 하네스가 만든 것뿐이다.
  if ! osascript -e 'with timeout of 8 seconds' \
      -e 'tell application "TextEdit" to close every document saving no' \
      -e 'end timeout' >/dev/null 2>&1; then
    pkill -9 -x TextEdit 2>/dev/null
  else
    osascript -e 'with timeout of 8 seconds' \
      -e 'tell application "TextEdit" to quit saving no' \
      -e 'end timeout' >/dev/null 2>&1 || pkill -9 -x TextEdit 2>/dev/null
  fi

  # 하네스가 띄운 SnipKey(임시 저장소를 물고 있는 놈)를 죽인다.
  if [[ -n "$SNIPKEY_PID" ]]; then
    kill "$SNIPKEY_PID" 2>/dev/null
    wait "$SNIPKEY_PID" 2>/dev/null
  fi
  pkill -f "SnipKey.app/Contents/MacOS/SnipKey" 2>/dev/null
  sleep 1

  # 클립보드 복원. 클립보드 손실은 출시된 적 있는 버그다 — 하네스가 그걸 재현하면 안 된다.
  # 백업이 비어 있으면 복원하지 않는다. 빈 파일을 pbcopy 하면 되살리는 게 아니라
  # 지우는 것이 되기 때문이다.
  if [[ -s "$CLIP_BACKUP" ]]; then
    pbcopy < "$CLIP_BACKUP"
    echo "  클립보드 복원됨"
  fi

  rm -rf "$TMP_DIR"
  echo "  임시 저장소 삭제됨: $TMP_DIR"

  # 원래 돌고 있던 사용자의 SnipKey를 되살린다 (진짜 store.json으로).
  if [[ "$SNIPKEY_WAS_RUNNING" == "1" ]]; then
    open "$APP" 2>/dev/null
    echo "  사용자의 SnipKey 재실행됨"
  fi

  exit $code
}
trap cleanup EXIT INT TERM

# ── 유틸 ────────────────────────────────────────────────────────────────────

# 조건이 참이 될 때까지 폴링한다. 고정 sleep으로 찍는 것보다 빠르고 덜 깨진다.
# wait_for <timeout_seconds> <shell command…>
wait_for() {
  local timeout=$1; shift
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if eval "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  return 1
}

# TextEdit 문서 텍스트를 읽는다. AppleEvent 실패를 빈 문자열로 뭉개면 안 된다 —
# 그러면 "문서가 비어 있다"와 "읽지 못했다"가 구분되지 않아서, TextEdit의 일시적
# 지연(-1712)이 곧바로 테스트 실패로 둔갑한다. 읽기에 실패하면 non-zero로 알린다.
# [중요] 모든 AppleScript 호출은 `with timeout` 안에 있어야 한다.
# osascript의 기본 AppleEvent 타임아웃은 2분이다. TextEdit이 한 번 응답을 멈추면
# (실제로 그런 일이 있었다) 호출 하나가 2분씩 블록되고, wait_for의 초 단위 제한은
# 아무 의미가 없어지며 하네스가 통째로 멈춘다. 짧게 끊고 실패로 처리하는 편이 낫다.
osa() {
  local timeout_sec=$1; shift
  osascript -e "with timeout of ${timeout_sec} seconds" "$@" -e "end timeout"
}

# TextEdit 문서 텍스트를 읽는다. AppleEvent 실패를 빈 문자열로 뭉개면 안 된다 —
# 그러면 "문서가 비어 있다"와 "읽지 못했다"가 구분되지 않아서, TextEdit의 일시적
# 지연(-1712)이 곧바로 테스트 실패로 둔갑한다. 읽기에 실패하면 non-zero로 알린다.
textedit_text() {
  local out
  if ! out=$(osa 5 -e 'tell application "TextEdit" to get text of document 1' 2>&1); then
    return 1
  fi
  if [[ "$out" == *"execution error"* || "$out" == *"timed out"* || "$out" == *"시간이 초과"* ]]; then
    return 1
  fi
  printf '%s' "$out"
}

frontmost_app() {
  osa 5 -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null
}

# TextEdit이 살아 있고 AppleEvent에 응답하는지 본다. 응답하지 않으면 강제로
# 되살린다 — 죽은 TextEdit을 상대로 케이스를 돌리면 SnipKey가 멀쩡한데도
# 전부 빨갛게 뜬다.
revive_textedit() {
  echo "  TextEdit이 응답하지 않는다. 강제 재시작…"
  pkill -9 -x TextEdit 2>/dev/null || true
  sleep 2
  osa 15 -e 'tell application "TextEdit" to activate' >/dev/null 2>&1 || true
  sleep 2
}

# TextEdit에 새 문서를 열고 포커스가 실제로 갈 때까지 기다린다.
# 포커스 없이 타이핑하면 키가 엉뚱한 앱으로 날아간다.
new_document() {
  local attempt
  for attempt in 1 2; do
    # 문서 하나를 보장하고 내용만 비운다. 케이스마다 문서를 만들고 닫기를
    # 반복하면 TextEdit이 그 사이클을 못 버티고 AppleEvent가 타임아웃(-1712)
    # 나기 시작한다 — 실제로 그렇게 무너져서 케이스 전체가 빨갛게 떴다.
    # 문서를 재사용하는 편이 훨씬 안정적이다.
    if osa 15 \
        -e 'tell application "TextEdit"' \
        -e 'activate' \
        -e 'if (count of documents) is 0 then make new document' \
        -e 'set text of document 1 to ""' \
        -e 'end tell' >/dev/null 2>&1; then
      if wait_for 10 '[[ "$(frontmost_app)" == "TextEdit" ]]'; then
        # 문서 창이 키 입력을 받을 준비가 될 때까지 한 박자.
        sleep 0.4
        return 0
      fi
    fi
    [[ $attempt -eq 1 ]] && revive_textedit
  done

  echo "  ✗ TextEdit을 준비하지 못했다 (현재 최전면: $(frontmost_app))"
  return 1
}

# System Events로 한 글자씩 친다. 통째로 keystroke 하면 이벤트 탭이
# 놓칠 만큼 빨리 흘러가므로, 사람 타이핑 속도로 간격을 준다.
type_text() {
  local text="$1"
  # `|| true` 필수. 타이핑이 실패하면 set -e가 하네스를 죽이는데, 그건 어설션이
  # 잡아야 할 일이다. 키가 도달하지 않으면 각 케이스의 positive control이 잡는다.
  osascript >/dev/null 2>&1 <<EOF || true
with timeout of 60 seconds
  tell application "System Events"
    repeat with c in characters of "$text"
      keystroke (c as text)
      delay 0.05
    end repeat
  end tell
end timeout
EOF
}

# 엔진의 키 버퍼를 비운다. Escape는 ExpansionEngine이 buffer=""로 처리하는 키다.
# 케이스 사이에 앞 케이스의 잔여 버퍼가 새어 들어가는 것을 막는다.
clear_engine_buffer() {
  osa 5 -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  sleep 0.3
}

log_lines() {
  wc -l < "$LOG" 2>/dev/null | tr -d ' ' || echo 0
}

# 지정한 줄 번호 이후로 로그에 패턴이 등장했는지 본다.
log_since() {
  local from=$1
  tail -n "+$(( from + 1 ))" "$LOG" 2>/dev/null
}

pass() { RESULTS+=("PASS  $1"); echo "  ✓ $1"; }
fail() { RESULTS+=("FAIL  $1"); FAILURES+=("$1"); echo "  ✗ $1"; echo "        $2"; }

# ── 1. 사전 점검 ────────────────────────────────────────────────────────────
echo "▸ Preflight…"

if [[ ! -d "$APP" ]]; then
  echo "  ✗ $APP 가 없다. 먼저 설치해라:"
  echo "      scripts/build-app.sh --install"
  exit 1
fi
echo "  앱 확인: $APP"

# 사용자의 진짜 저장소는 손대지 않는다는 것을 눈으로 확인시켜 준다.
if [[ -f "$REAL_STORE" ]]; then
  echo "  실 저장소는 건드리지 않음: $REAL_STORE ($(wc -c < "$REAL_STORE" | tr -d ' ') bytes)"
fi

# 클립보드부터 저장한다. 이 줄 앞에서 죽으면 잃을 게 없고, 뒤에서 죽으면 trap이 되살린다.
pbpaste > "$CLIP_BACKUP" 2>/dev/null || : > "$CLIP_BACKUP"

# pbpaste/pbcopy는 평문만 왕복시킨다. 이미지·RTF 같은 비텍스트 클립보드는
# pbpaste가 빈 문자열로 돌려주므로, 그대로 진행하면 하네스가 사용자의 클립보드를
# 확장 텍스트로 덮어쓰고 되돌리지 못한다 — 잡으려던 바로 그 버그를 하네스가 저지르는 꼴이다.
# 되살릴 수 없는 내용이 올라와 있으면 차라리 멈춘다.
if [[ ! -s "$CLIP_BACKUP" ]] && osascript -e 'clipboard info' 2>/dev/null | grep -q .; then
  if [[ "${SNIPKEY_E2E_ALLOW_CLIPBOARD_LOSS:-0}" != "1" ]]; then
    echo "  ✗ 클립보드에 텍스트가 아닌 내용(이미지/RTF 등)이 있다."
    echo "    이 하네스는 평문만 복원할 수 있어서, 그대로 진행하면 잃어버린다."
    echo "    아무 텍스트나 복사해 두고 다시 실행해라."
    echo "    (버려도 좋다면: SNIPKEY_E2E_ALLOW_CLIPBOARD_LOSS=1 scripts/e2e.sh)"
    exit 1
  fi
  echo "  경고: 비텍스트 클립보드를 버리고 진행한다 (사용자가 허용함)"
fi
echo "  클립보드 저장됨 ($(wc -c < "$CLIP_BACKUP" | tr -d ' ') bytes)"

# 사용자의 SnipKey가 돌고 있으면 종료한다. 그대로 두면 그 인스턴스가
# 진짜 저장소로 키를 가로채서, 테스트가 거짓으로 통과하거나 깨진다.
if pgrep -f "SnipKey.app/Contents/MacOS/SnipKey" >/dev/null 2>&1; then
  SNIPKEY_WAS_RUNNING=1
  echo "  실행 중인 SnipKey 종료 (끝나고 되살림)"
  pkill -f "SnipKey.app/Contents/MacOS/SnipKey" 2>/dev/null || true
  sleep 1.5
fi

# ── 2. 임시 저장소 시딩 ─────────────────────────────────────────────────────
echo "▸ Seeding isolated store at $TMP_DIR…"

# didFinishOnboarding 은 반드시 true여야 한다. false면 앱이 온보딩 창을 띄우고
# NSApp.activate(ignoringOtherApps:)로 포커스를 뺏어가 타이핑이 전부 빗나간다.
# playSoundOnExpand 는 false — 확장마다 소리를 낼 이유가 없다.
cat > "$TMP_DIR/store.json" <<'EOF'
{
  "version": 1,
  "expansionCount": 0,
  "macros": [],
  "settings": {
    "expansionEnabled": true,
    "playSoundOnExpand": false,
    "didFinishOnboarding": true,
    "clipboardRestoreDelay": 0.35,
    "inlineSearchEnabled": false,
    "inlineSearchKeyCode": 44,
    "inlineSearchModifiers": 256
  },
  "groups": [
    {
      "id": "E2E0A000-0000-4000-8000-000000000001",
      "name": "E2E",
      "enabled": true,
      "snippets": [
        {
          "id": "E2E5A000-0000-4000-8000-000000000001",
          "abbreviation": ";e2e",
          "content": "expanded-ok",
          "label": "plain expansion",
          "caseSensitive": true,
          "enabled": true,
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z"
        },
        {
          "id": "E2E5A000-0000-4000-8000-000000000002",
          "abbreviation": ";cb",
          "content": "clip=[%clipboard]",
          "label": "clipboard macro",
          "caseSensitive": true,
          "enabled": true,
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z"
        },
        {
          "id": "E2E5A000-0000-4000-8000-000000000003",
          "abbreviation": "sig",
          "content": "SIGNATURE-BLOCK",
          "label": "bare-word abbreviation",
          "caseSensitive": true,
          "enabled": true,
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z"
        }
      ]
    }
  ]
}
EOF
echo "  스니펫 3개 시딩: ';e2e' → expanded-ok, ';cb' → clip=[%clipboard], 'sig' → SIGNATURE-BLOCK"

# ── 3. 격리된 저장소로 SnipKey 실행 ─────────────────────────────────────────
echo "▸ Launching SnipKey against the temp store…"

# `open`은 환경변수를 넘길 수 없으므로 번들 바이너리를 직접 실행한다.
# 번들 안에서 실행되므로 TCC/코드서명 관점에서는 같은 앱이다.
: > "$LOG"
SNIPKEY_STORE_DIR="$TMP_DIR" "$APP_BIN" >/dev/null 2>&1 &
SNIPKEY_PID=$!

# 접근성 권한이 살아 있어야만 이벤트 탭이 뜨고 "engine started"가 찍힌다.
# 탭이 죽은 채로 초록불이 뜨는 것은 빨간불보다 나쁘다 — 여기서 끊는다.
if ! wait_for 20 'grep -q "engine started" "$LOG"'; then
  echo ""
  echo "  ✗ 이벤트 탭이 뜨지 않았다 ('engine started' 로그 없음)."
  echo "    접근성 권한이 죽어 있다. 재빌드하면 조용히 무효화된다."
  echo ""
  echo "    고치는 법:  scripts/dev-grant-accessibility.sh"
  echo ""
  echo "    ── $LOG ──"
  sed 's/^/    /' "$LOG" 2>/dev/null || echo "    (로그 비어 있음)"
  echo "    ──────────"
  exit 1
fi
echo "  엔진 기동 확인 ('engine started', pid=$SNIPKEY_PID)"
grep -q "accessibility trusted: true" "$LOG" && echo "  접근성 권한 살아 있음"

# ── 4. 타이핑 경로 자체가 동작하는지 확인 ───────────────────────────────────
# System Events 키 입력에는 이 스크립트를 부른 터미널의 접근성 권한이 필요하다.
# 그게 없으면 모든 케이스가 "확장 안 됨"으로 빨갛게 뜬다 — 앱 탓이 아닌데도.
# 앱 실패와 하네스 환경 실패를 구분하기 위해 먼저 친다.
echo "▸ Verifying the harness can actually type…"
new_document
type_text "ping"
if ! wait_for 5 '[[ "$(textedit_text)" == *"ping"* ]]'; then
  echo "  ✗ TextEdit에 글자가 들어가지 않는다. 앱 문제가 아니라 하네스 환경 문제다."
  echo "    이 스크립트를 실행한 터미널에 '손쉬운 사용' 권한이 필요하다:"
  echo "    시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → 터미널 허용"
  exit 1
fi
echo "  타이핑 경로 정상"
# `|| true` 필수. 이 정리 한 줄이 실패하면 set -e가 하네스를 통째로 죽여서,
# 케이스가 하나도 돌지 않은 채 조용히 끝난다. 실제로 그렇게 당했다.
osa 8 -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true

# ── 5. 케이스 ───────────────────────────────────────────────────────────────
echo ""
echo "▸ Running cases…"

# ── (a) 평범한 약어가 확장된다 ─────────────────────────────────────────────
run_case_plain_expansion() {
  local name="(a) plain abbreviation expands"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)
  type_text ";e2e"

  # 확장은 비동기다(엔진 → 메인 큐 → injector 큐 → 백스페이스 → 붙여넣기).
  wait_for 8 '[[ "$(textedit_text)" == *"expanded-ok"* ]]' || true
  local text=$(textedit_text)
  local logged=$(log_since "$mark")

  # 텍스트만 믿지 않는다. 엔진이 진짜로 발화했는지 로그로 교차 확인한다.
  if [[ "$text" != *"expanded-ok"* ]]; then
    fail "$name" "문서=[$text] — 기대: 'expanded-ok' 포함. 로그: $(echo "$logged" | tr '\n' ' ')"
  elif ! echo "$logged" | grep -q "inject start"; then
    fail "$name" "텍스트는 맞지만 'inject start' 로그가 없다 — 엔진이 발화하지 않았다"
  elif [[ "$text" == *";e2e"* ]]; then
    fail "$name" "문서=[$text] — 약어가 지워지지 않았다 (백스페이스 실패)"
  else
    pass "$name  문서=[$text]"
  fi
}

# ── (b) 약어를 부분 문자열로 품은 단어는 확장되면 안 된다 ──────────────────
# 출시된 적 있는 '오확장' 계열 버그. 'sig' 스니펫을 둔 채 'design'을 치면
# 사용자가 원한 것은 단어 'design'이지 서명 블록이 아니다.
run_case_substring_no_expansion() {
  local name="(b) word containing an abbreviation does NOT expand"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)

  # 'sig' 스니펫이 시딩돼 있으므로, 단어 경계 규칙이 없으면 버퍼가 'desig'가 되는
  # 순간 확장이 터진다. 그게 이 케이스가 잡으려는 회귀다.
  type_text "design"
  sleep 2

  # 이어서 확장되는 약어를 친다. 이건 positive control이다. 이게 확장돼야만
  # '키 입력이 실제로 엔진까지 도달했다'가 증명된다. 없으면, 타이핑이 아무 데도
  # 가지 않았는데 로그가 조용하다는 이유로 통과하는 위양성이 생긴다.
  type_text " ;e2e"
  sleep 3

  # 판정은 전적으로 엔진 로그로 한다. 문서 텍스트로 판정하면 TextEdit의 간헐적
  # AppleEvent 지연이 SnipKey 결함으로 오보된다 — 실제로 그 오보를 겪었다.
  # 우리가 검증하려는 건 SnipKey의 동작이지 TextEdit의 응답성이 아니다.
  local logged
  logged=$(log_since "$mark")

  local sig_matched=0
  echo "$logged" | grep -q "matched 'sig'" && sig_matched=1

  local injects
  injects=$(echo "$logged" | grep -c "inject start" || true)

  if [[ "$sig_matched" -eq 1 ]]; then
    fail "$name" "'design' 도중 'sig'가 매치됐다 — 부분 문자열 오확장 재발. 로그: $(echo "$logged" | grep -E "matched|inject start" | tr '\n' ' ')"
  elif [[ "$injects" -ne 1 ]]; then
    # 확장이 정확히 1회(;e2e)여야 한다. 0회면 타이핑이 도달하지 않은 것이고,
    # 2회 이상이면 'sig'가 어떤 형태로든 끼어든 것이다. 둘 다 통과시키면 안 된다.
    fail "$name" "타이핑 도달 확인 실패 — 'inject start' ${injects}회 (기대: ;e2e 확장 1회). 측정을 신뢰할 수 없다."
  else
    pass "$name  ('sig' 미발화, ';e2e'만 확장되어 타이핑 도달 확인됨)"
  fi
}

# ── (c) 클립보드 매크로를 써도 사용자 클립보드가 살아남는다 ────────────────
run_case_clipboard_preserved() {
  local name="(c) clipboard survives a clipboard-macro expansion"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  printf '%s' "$CLIP_SENTINEL" | pbcopy
  sleep 0.3

  local mark=$(log_lines)
  type_text ";cb"

  wait_for 8 '[[ "$(textedit_text)" == *"clip=["* ]]' || true
  local text=$(textedit_text)
  local logged=$(log_since "$mark")

  # 붙여넣기용으로 클립보드를 잠깐 덮어쓴 뒤 되돌리므로, 복원까지 기다린다.
  sleep 2
  local clip=$(pbpaste)

  if [[ "$text" != *"clip=[$CLIP_SENTINEL]"* ]]; then
    fail "$name" "문서=[$text] — 기대: 'clip=[$CLIP_SENTINEL]'. 로그: $(echo "$logged" | tr '\n' ' ')"
  elif ! echo "$logged" | grep -q "inject start"; then
    fail "$name" "'inject start' 로그 없음 — 엔진이 발화하지 않았다"
  elif [[ "$clip" != "$CLIP_SENTINEL" ]]; then
    fail "$name" "확장은 됐지만 클립보드가 [$clip] 로 덮였다 — 기대: [$CLIP_SENTINEL]"
  else
    pass "$name  문서=[$text], 클립보드=[$clip]"
  fi
}

run_case_plain_expansion
run_case_substring_no_expansion
run_case_clipboard_preserved

# ── 6. 요약 ─────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "──────────────────────────────────────────────"

if (( ${#FAILURES[@]} > 0 )); then
  echo "  ${#FAILURES[@]} / ${#RESULTS[@]} FAILED"
  exit 1
fi
echo "  ${#RESULTS[@]} / ${#RESULTS[@]} PASSED"
