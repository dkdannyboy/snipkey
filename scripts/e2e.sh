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

# TextEdit이 하네스 실행 전부터 떠 있었는지. 하네스가 직접 띄운 경우에만 끝나고
# 종료해도 되고, 사용자가 쓰던 것이라면 손대면 안 된다.
TEXTEDIT_WAS_RUNNING=0

# TextEdit을 건드려도 되는지. preflight가 "열린 문서 0개"를 확인해야 1이 된다.
# 0인 동안 cleanup은 TextEdit에 손대지 않는다 — 이게 없으면, 사용자 문서를 발견하고
# exit 하는 가드가 trap을 통해 cleanup을 부르고, cleanup이 바로 그 문서를 닫아버린다.
# 가드가 지키려던 것을 가드 때문에 잃는 꼴이 된다.
TEXTEDIT_SAFE=0

# 하네스가 소유하는 문서. 임시 파일을 열어서 만들기 때문에 이름으로 정확히 지목할 수
# 있고, 그래서 "우리 문서만" 건드릴 수 있다.
#
# preflight의 "문서 0개" 검사만으로는 부족하다. 그건 한 순간의 스냅샷일 뿐이라,
# 하네스가 도는 중에 사용자가 TextEdit 문서를 새로 열면 `document 1`이 그 문서를
# 가리키게 되고, 내용이 지워지거나 저장 없이 닫힌다. 이름으로 소유를 고정하면 그
# 경합 자체가 성립하지 않는다.
E2E_DOC_NAME="snipkey-e2e-scratch.txt"
E2E_DOC_PATH="$TMP_DIR/$E2E_DOC_NAME"

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

  # TextEdit 정리.
  #
  # 여기서 닫는 문서는 전부 하네스가 만든 것이어야 한다. 그 보장은 preflight가
  # 한다 — 열린 문서가 하나라도 있으면 아예 실행을 거부하므로, 이 시점에 존재하는
  # 문서는 하네스가 만든 것뿐이다. 그 가드가 없으면 `close ... saving no`가
  # 사용자의 저장 안 된 원고를 되돌릴 수 없게 날린다. 클립보드는 그렇게 조심스럽게
  # 지켜놓고 남의 문서를 파괴하면 앞뒤가 맞지 않는다.
  #
  # `pkill -9`도 preflight 가드에 기대고 있다. 문서가 0개임이 보장된 경우에만
  # 안전하며, 그마저도 하네스가 직접 띄운 TextEdit에만 쓴다.
  if [[ "$TEXTEDIT_SAFE" -eq 1 ]]; then
    # 우리 문서만 닫는다. `close every document saving no`는 절대 쓰지 않는다 —
    # 하네스가 도는 중에 사용자가 연 문서까지 저장 없이 날려버린다.
    osascript -e 'with timeout of 8 seconds' \
      -e "tell application \"TextEdit\" to close (every document whose name is \"$E2E_DOC_NAME\") saving no" \
      -e 'end timeout' >/dev/null 2>&1 || true

    if [[ "$TEXTEDIT_WAS_RUNNING" -eq 0 ]]; then
      # 하네스가 띄운 TextEdit이다. 원래 없던 것이니 되돌려 놓는다.
      # 단, 그새 사용자가 문서를 열어뒀다면 종료하지 않는다. 남의 작업을 닫는 것보다
      # TextEdit이 하나 더 떠 있는 편이 낫다.
      local remaining
      remaining=$(osascript -e 'with timeout of 5 seconds' \
        -e 'tell application "TextEdit" to count documents' \
        -e 'end timeout' 2>/dev/null) || remaining=1

      if [[ "$remaining" == "0" ]]; then
        osascript -e 'with timeout of 8 seconds' \
          -e 'tell application "TextEdit" to quit' \
          -e 'end timeout' >/dev/null 2>&1 || true
      else
        echo "  TextEdit에 다른 문서가 열려 있어 종료하지 않는다"
      fi
    fi
    # 사용자가 원래 쓰던 TextEdit이면 종료하지 않는다. 켜 둔 채로 돌려준다.
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

# [중요] 모든 AppleScript 호출은 `with timeout` 안에 있어야 한다.
# osascript의 기본 AppleEvent 타임아웃은 2분이다. TextEdit이 한 번 응답을 멈추면
# (실제로 그런 일이 있었다) 호출 하나가 2분씩 블록되고, wait_for의 초 단위 제한은
# 아무 의미가 없어지며 하네스가 통째로 멈춘다. 짧게 끊고 실패로 처리하는 편이 낫다.
osa() {
  local timeout_sec=$1; shift
  osascript -e "with timeout of ${timeout_sec} seconds" "$@" -e "end timeout"
}

# 하네스가 소유한 문서의 텍스트를 읽는다. `document 1`(최전면)이 아니라 이름으로
# 지목한다 — 사용자가 그 사이 문서를 열었더라도 남의 문서를 읽지 않기 위해서다.
#
# AppleEvent 실패를 빈 문자열로 뭉개면 안 된다. 그러면 "문서가 비어 있다"와
# "읽지 못했다"가 구분되지 않아서, TextEdit의 일시적 지연(-1712)이 곧바로 테스트
# 실패로 둔갑한다. 읽기에 실패하면 non-zero로 알린다.
textedit_text() {
  local out
  if ! out=$(osa 5 -e "tell application \"TextEdit\" to get text of document \"$E2E_DOC_NAME\"" 2>&1); then
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

# 최전면 문서가 하네스 소유인지 본다. 아니라면 타이핑하면 안 된다 — 사용자가
# 방금 연 문서에 키를 쏟아붓게 된다.
front_doc_is_ours() {
  local n
  n=$(osa 5 -e 'tell application "TextEdit" to get name of document 1' 2>/dev/null) || return 1
  [[ "$n" == "$E2E_DOC_NAME" ]]
}

# TextEdit이 응답하지 않을 때 되살린다. 죽은 TextEdit을 상대로 케이스를 돌리면
# SnipKey가 멀쩡한데도 전부 빨갛게 뜬다.
#
# preflight가 TextEdit을 종료시키므로, 여기서 도는 TextEdit은 하네스가 띄운 것이다.
# 그래도 강제 종료 전에 남의 문서가 생기지 않았는지 확인한다 — 하네스가 도는 중에
# 사용자가 문서를 열었다면 kill -9는 그 작업을 파괴한다.
#
# 문서를 셀 수 있고 우리 것(0개 또는 1개) 뿐이면 강제 종료해도 잃을 게 없다.
# 응답조차 없으면 셀 수도 없는데, 그땐 하네스를 계속할 방법이 없으므로 재시작한다.
# preflight가 시작 시점의 문서 0개를 보장했고 하네스가 키보드를 점유한 채 도는
# 짧은 시간이라, 그 사이 남의 문서가 생겼을 가능성은 사실상 없다.
revive_textedit() {
  local docs
  docs=$(osa 5 -e 'tell application "TextEdit" to count documents' 2>/dev/null) || docs="unknown"

  if [[ "$docs" != "unknown" && "$docs" -gt 1 ]]; then
    echo "  TextEdit이 응답하지 않지만 다른 문서가 열려 있다 — 강제 종료하지 않는다."
    return 1
  fi

  echo "  TextEdit이 응답하지 않는다. 강제 재시작…"
  pkill -9 -x TextEdit 2>/dev/null || true
  sleep 2
  osa 15 -e 'tell application "TextEdit" to activate' >/dev/null 2>&1 || true
  sleep 2
}

# 하네스 소유 문서를 열고(없으면), 내용을 비우고, 최전면으로 가져온다.
#
# 임시 파일을 열어서 문서를 만든다. 그래야 이름으로 정확히 지목할 수 있고,
# 사용자가 그 사이 다른 문서를 열어도 그쪽은 절대 건드리지 않는다. `document 1`
# (최전면)을 쓰면 그 보장이 사라진다 — 사용자가 방금 연 문서가 최전면일 수 있다.
#
# 케이스마다 문서를 만들고 닫기를 반복하면 TextEdit이 그 사이클을 못 버티고
# AppleEvent가 타임아웃(-1712)나기 시작한다. 그래서 문서 하나를 열어두고 재사용한다.
new_document() {
  local attempt
  for attempt in 1 2; do
    # 파일은 없을 때만 만든다. TextEdit이 열어둔 파일을 셸에서 truncate하면
    # 문서 상태가 꼬여서 이후 AppleScript 호출이 통째로 실패한다 — 실제로 그렇게
    # 케이스가 전부 "TextEdit 준비 실패"로 떨어졌다. 내용은 AppleScript로 비운다.
    [[ -f "$E2E_DOC_PATH" ]] || : > "$E2E_DOC_PATH"

    # `set index of window 1 to 1`은 넣지 않는다. 이미 1인 창에 대해 에러를 던져
    # 블록 전체를 실패시킬 수 있고, 문서를 열면 어차피 그 창이 앞으로 나온다.
    if osa 15 \
        -e 'tell application "TextEdit"' \
        -e 'activate' \
        -e "if not (exists document \"$E2E_DOC_NAME\") then open POSIX file \"$E2E_DOC_PATH\"" \
        -e "set text of document \"$E2E_DOC_NAME\" to \"\"" \
        -e 'end tell' >/dev/null 2>&1; then

      # 최전면이 TextEdit이고, 그 안에서도 최전면 문서가 우리 것이어야 한다.
      # 앱만 확인하면, 사용자가 열어둔 다른 문서에 키를 쏟아부을 수 있다.
      if wait_for 10 '[[ "$(frontmost_app)" == "TextEdit" ]]' && wait_for 5 'front_doc_is_ours'; then
        # 문서 창이 키 입력을 받을 준비가 될 때까지 한 박자.
        sleep 0.4
        return 0
      fi
    fi
    [[ $attempt -eq 1 ]] && { revive_textedit || return 1; }
  done

  echo "  ✗ 하네스 문서를 최전면으로 가져오지 못했다 (최전면 앱: $(frontmost_app))"
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

# 키코드 하나를 보낸다. Return(36)·Tab(48)처럼 `keystroke`로는 칠 수 없는 키용.
# `|| true` 필수 — 실패는 어설션이 잡아야지 set -e가 하네스를 죽여서는 안 된다.
send_key_code() {
  osa 10 -e "tell application \"System Events\" to key code $1" >/dev/null 2>&1 || true
  sleep 0.3
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

# TextEdit에 열린 문서가 하나라도 있으면 실행을 거부한다.
#
# 하네스는 문서 내용을 비우고(set text to "") 끝나면 저장 없이 닫는다. 그 대상이
# 사용자의 저장하지 않은 원고라면 되돌릴 수 없이 파괴된다. 클립보드는 백업해서
# 되살리지만, 문서는 되살릴 방법이 없다. 그러므로 유일한 방어는 아예 시작하지
# 않는 것이다. 이 가드가 곧 cleanup의 "여기 있는 문서는 전부 하네스 것"이라는
# 전제를 성립시킨다.
if pgrep -x TextEdit >/dev/null 2>&1; then
  TEXTEDIT_WAS_RUNNING=1

  DOC_COUNT=$(osa 8 -e 'tell application "TextEdit" to count documents' 2>/dev/null || echo "unknown")

  if [[ "$DOC_COUNT" == "unknown" || -z "$DOC_COUNT" ]]; then
    echo "  ✗ TextEdit이 응답하지 않아 열린 문서가 있는지 확인할 수 없다."
    echo "    확인하지 못한 채로 진행하면 저장 안 된 작업을 파괴할 수 있다."
    echo "    TextEdit을 종료하고 다시 실행해라."
    exit 1
  fi

  if [[ "$DOC_COUNT" -ne 0 ]]; then
    echo "  ✗ TextEdit에 문서 ${DOC_COUNT}개가 열려 있다."
    echo "    이 하네스는 TextEdit 문서를 비우고 저장 없이 닫으므로, 저장하지 않은"
    echo "    작업이 있으면 되돌릴 수 없이 사라진다."
    echo "    문서를 저장하고 닫은 뒤 다시 실행해라."
    echo "    (클립보드와 달리 문서는 복원할 수단이 없어서 우회 옵션을 두지 않았다.)"
    exit 1
  fi

  # 문서가 없음을 확인했으니 안전하게 종료한다. 그냥 두면 안 되는 이유가 있다:
  # TextEdit은 실행 직후 상태 복원 때문에 잠깐 유령 문서를 띄우는데, 그러면
  # `document 1`이 우리 것이 아니게 되어 하네스가 자기 문서를 찾지 못한다. 게다가
  # 사용자가 띄운 TextEdit은 강제 재시작(revive) 대상이 아니라서 스스로 회복하지도
  # 못하고 그대로 전부 실패한다. 하네스가 직접 띄운 TextEdit만 상대하는 편이 낫다.
  echo "  TextEdit 실행 중이지만 열린 문서 없음 — 종료하고 하네스가 다시 띄운다"
  osa 10 -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || pkill -9 -x TextEdit 2>/dev/null || true
  sleep 1.5
else
  TEXTEDIT_WAS_RUNNING=0
  echo "  TextEdit 미실행 — 하네스가 띄우고 끝나면 종료한다"
fi

# 여기까지 왔으면 TextEdit에 파괴할 사용자 문서가 없다. 이제 cleanup이 손대도 된다.
TEXTEDIT_SAFE=1

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
        },
        {
          "id": "E2E5A000-0000-4000-8000-000000000004",
          "abbreviation": ";fill",
          "content": "FILLED-[%filltext:name=v%]",
          "label": "fill-in snippet",
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
echo "  스니펫 4개 시딩: ';e2e' → expanded-ok, ';cb' → clip=[%clipboard], 'sig' → SIGNATURE-BLOCK, ';fill' → FILLED-[…]"

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
# 문서를 닫지 않고 내용만 비운다. 각 케이스가 new_document로 다시 비우므로 굳이
# 닫을 이유가 없고, 여기서 `close every document`를 쓰면 사용자가 그새 연 문서까지
# 저장 없이 날아간다.
#
# `|| true` 필수. 이 정리 한 줄이 실패하면 set -e가 하네스를 통째로 죽여서,
# 케이스가 하나도 돌지 않은 채 조용히 끝난다. 실제로 그렇게 당했다.
osa 8 -e "tell application \"TextEdit\" to set text of document \"$E2E_DOC_NAME\" to \"\"" >/dev/null 2>&1 || true

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

# ── (d) 약어를 '접두사'로 가진 더 긴 단어를 칠 수 있어야 한다 ───────────────
# (b)의 자매 케이스이자, (b)를 고친 커밋이 놓친 나머지 절반.
#
# (b)는 약어가 단어 '안쪽'에 있는 경우('design' 안의 sig)를 막았다. 하지만 약어가
# 단어 '머리'에 있는 경우('signal'의 sig)는 여전히 터졌다. s·i·g가 들어온 순간
# 버퍼가 'sig'가 되고 바로 앞은 경계(공백/문서 시작)이므로 엔진이 즉시 발화한다.
# 백스페이스 3번과 주입이 나가는 동안 n·a·l이 계속 도착해 'SIGNATURE-BLOCKnal'이
# 된다 — 사용자는 'signal'이라는 단어를 아예 칠 수 없다.
#
# 이제 맨몸 약어는 종결자를 기다리므로 'signal'은 조용히 지나가야 한다.
run_case_word_prefix_no_expansion() {
  local name="(d) longer word starting with an abbreviation does NOT expand"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)

  # 'sig' 스니펫이 시딩돼 있다. 종결자 규칙이 없으면 'sig'까지 친 순간 발화한다.
  type_text "signal"
  sleep 2

  # positive control. 이게 확장돼야만 '키가 실제로 엔진까지 도달했다'가 증명된다.
  # 없으면 타이핑이 아무 데도 가지 않았는데 로그가 조용하다는 이유로 통과한다.
  type_text " ;e2e"
  sleep 3

  # 판정은 엔진 로그로만 한다. 문서 텍스트로 판정하면 TextEdit의 간헐적
  # AppleEvent 지연이 SnipKey 결함으로 오보된다.
  local logged
  logged=$(log_since "$mark")

  local sig_matched=0
  echo "$logged" | grep -q "matched 'sig'" && sig_matched=1

  local injects
  injects=$(echo "$logged" | grep -c "inject start" || true)

  if [[ "$sig_matched" -eq 1 ]]; then
    fail "$name" "'signal' 도중 'sig'가 매치됐다 — 접두 오확장 재발. 로그: $(echo "$logged" | grep -E "matched|inject start" | tr '\n' ' ')"
  elif [[ "$injects" -ne 1 ]]; then
    fail "$name" "타이핑 도달 확인 실패 — 'inject start' ${injects}회 (기대: ;e2e 확장 1회). 측정을 신뢰할 수 없다."
  else
    pass "$name  ('sig' 미발화, ';e2e'만 확장되어 타이핑 도달 확인됨)"
  fi
}

# ── (e) 종결된 맨몸 약어는 확장되고, 종결자는 살아남는다 ────────────────────
# (d)의 반대편. 종결자를 기다리게 만든 대가로 맨몸 약어가 아예 죽어버리면 안 된다.
# 'sig '를 치면 확장되어야 하고, 이때 종결자(스페이스)는 이미 화면에 있으므로
# 약어와 함께 지웠다가(backspaces=4) 확장 내용 뒤에 다시 찍어야 한다.
run_case_terminated_bare_word_expands() {
  local name="(e) terminated bare-word abbreviation expands, terminator survives"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)
  type_text "sig "
  sleep 3

  local logged
  logged=$(log_since "$mark")

  # 판정은 로그로 한다. backspaces=4 는 '약어 3 + 종결자 1'이라는 계약 그 자체다.
  # 3이면 종결자를 지우지 않은 것이고, 그러면 확장 내용이 스페이스 앞에 끼어든다.
  if ! echo "$logged" | grep -q "matched 'sig'"; then
    fail "$name" "'sig ' 를 쳤는데 매치되지 않았다 — 종결자 규칙이 맨몸 약어를 죽였다. 로그: $(echo "$logged" | tr '\n' ' ')"
    return
  fi
  if ! echo "$logged" | grep -q "inject start (backspaces=4)"; then
    fail "$name" "백스페이스 수가 4가 아니다 (약어 3 + 종결자 1). 로그: $(echo "$logged" | grep "inject start" | tr '\n' ' ')"
    return
  fi

  # 여기까지 왔으면 엔진은 올바르게 동작했다. 문서 텍스트는 '보조' 확인일 뿐이다.
  # TextEdit이 응답하지 않으면 SnipKey 결함이 아니므로 실패시키지 않고 알리기만 한다.
  local text
  if text=$(textedit_text); then
    if [[ "$text" != *"SIGNATURE-BLOCK "* ]]; then
      fail "$name" "엔진은 발화했지만 문서=[$text] — 기대: 'SIGNATURE-BLOCK ' (종결자 스페이스가 확장 내용 뒤에 남아야 함)"
      return
    fi
    pass "$name  문서=[$text]"
  else
    pass "$name  (엔진 로그 확인됨; TextEdit이 응답하지 않아 문서 확인은 생략)"
  fi
}

# ── (f)(g) Return·Tab은 종결자가 아니다 ────────────────────────────────────
# 종결자로 안전한 키는 '글자를 넣는 것 말고는 아무 일도 하지 않는 키'뿐이다.
# 이벤트 탭이 .listenOnly라 키는 앱에 먼저 도착한다. 스페이스라면 공백 한 칸이
# 들어갈 뿐이라 지우고 확장한 뒤 다시 찍으면 그만이다.
#
# Return과 Tab에는 부작용이 있다:
#   - Slack·메시지·검색창에서 Return은 '전송'이다. 종결자로 받으면 'sig'가 그대로
#     전송된 뒤 서명이 비어버린 입력창에 붙는다.
#   - 폼에서 Tab은 '다음 필드로 포커스 이동'이다. 백스페이스와 붙여넣기가 나갈 때
#     커서는 이미 옆 칸에 있어서, 서명이 엉뚱한 칸에 박힌다.
# 확장이 안 되는 것보다 잘못된 곳에 확장되는 것이 나쁘다. 그래서 이 두 키는
# 버퍼를 비우기만 한다.
#
# 이 케이스는 그 결정을 못 박는다. 누군가 "Return으로도 확장되면 편할 텐데"라며
# 되돌리면 여기서 잡힌다. (TextEdit에서는 Return이 그냥 개행이라 잘 도는 것처럼
# 보이는데, 그래서 더더욱 자동 검증이 필요하다.)
run_case_side_effect_key_does_not_expand() {
  local name="$1" keycode="$2"

  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)
  type_text "sig"
  send_key_code "$keycode"
  sleep 2

  # positive control. 이 키가 확장을 발화시키지 '않는다'를 검증하는 케이스이므로,
  # 로그가 조용한 것이 '키가 아예 도달하지 않아서'일 수도 있다. 확실히 확장되는
  # 약어를 이어 쳐서 타이핑 경로가 살아 있음을 증명한다.
  type_text " ;e2e"
  sleep 3

  local logged
  logged=$(log_since "$mark")

  local sig_matched=0
  echo "$logged" | grep -q "matched 'sig'" && sig_matched=1

  local injects
  injects=$(echo "$logged" | grep -c "inject start" || true)

  if [[ "$sig_matched" -eq 1 ]]; then
    fail "$name" "'sig' + key code $keycode 로 확장이 발화했다 — 이 키는 부작용(전송/포커스이동)이 먼저 일어나므로 종결자로 쓰면 안 된다. 로그: $(echo "$logged" | grep -E "matched|inject start" | tr '\n' ' ')"
  elif [[ "$injects" -ne 1 ]]; then
    fail "$name" "타이핑 도달 확인 실패 — 'inject start' ${injects}회 (기대: ;e2e 확장 1회). 측정을 신뢰할 수 없다."
  else
    pass "$name  ('sig' 미발화, ';e2e'만 확장되어 타이핑 도달 확인됨)"
  fi
}

run_case_return_terminator() {
  run_case_side_effect_key_does_not_expand \
    "(f) Return does NOT terminate a bare-word abbreviation" 36
}

# ── (h) 종결자 뒤로 타이핑을 이어가면 확장을 버린다 ─────────────────────────
# (e)의 어두운 쌍둥이. (e)는 'sig ' 를 치고 `sleep 3` 으로 기다린다 — 사람이 확장을
# 기다리며 멈춰 선 상황이다. 그래서 (e)는 이 버그를 볼 수 없었다.
#
# 실제로는 아무도 그렇게 치지 않는다. 'sig ' 뒤에 스페이스를 쳤다는 것은 문장을
# 이어 쓰겠다는 뜻이고, 사용자는 바로 'next'를 친다. 확장은 비동기이고 느리다
# (백스페이스·붙여넣기 사이의 sleep 때문에 100~300ms). 이벤트 탭은 .listenOnly라
# 'next'는 우리보다 먼저 TextEdit에 도착한다. 그 뒤에 백스페이스 4번이 나가면
# 지워지는 것은 'sig '가 아니라 'next'다 — 사용자가 방금 쓴 글자가 조용히 사라진다.
#
# 그래서 엔진은 매치 시점의 키 카운터를 기억했다가, 첫 백스페이스가 나가기 직전에
# 다시 본다. 하나라도 늘었으면 확장을 통째로 버린다. 잘못된 자리에서 확장되는 것보다
# 확장이 안 되는 편이 낫다.
#
# 타이핑은 반드시 한 번의 type_text로 'sig next'를 통째로 친다. 종결자와 다음 단어
# 사이에 sleep을 넣는 순간 이 케이스는 (e)가 되어버리고, 잡으려던 경합이 사라진다.
run_case_typing_ahead_aborts_expansion() {
  local name="(h) typing through the terminator aborts the expansion (no corruption)"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)

  # 끊지 않고 이어서 친다. 'sig ' 로 매치가 걸린 직후에도 n·e·x·t 가 계속 도착한다.
  type_text "sig next"

  # 확장(또는 취소)이 결론까지 가도록 기다린다.
  sleep 3

  # positive control. 이 케이스는 '확장이 일어나지 않았음'을 주장하므로, 로그가
  # 조용한 이유가 '키가 엔진에 도달하지 않아서'일 수 있다. 확실히 확장되는 약어를
  # 이어 쳐서 타이핑 경로가 살아 있음을 증명한다. 앞에 스페이스를 두어 단어 경계를 만든다.
  type_text " ;e2e"
  sleep 3

  local logged
  logged=$(log_since "$mark")

  # 판정은 엔진 로그로 한다.
  #   1) "matched 'sig'"                : 키가 엔진에 도달했고 매치까지 갔다.
  #   2) "expansion cancelled — user kept typing" : 가드가 그 확장을 버렸다.
  #   3) "inject done" 정확히 1회       : 실제로 주입된 것은 positive control(;e2e)뿐이다.
  #      ('inject start'가 아니라 'inject done'을 센다. 'inject start'는 엔진이 주입을
  #       '결정'한 시점에 찍히고, 가드는 그 뒤 인젝터 큐에서 판정하기 때문이다.
  #       실제로 키가 나갔는지를 말해주는 것은 'inject done' 쪽이다.)
  local sig_matched=0
  echo "$logged" | grep -q "matched 'sig'" && sig_matched=1

  local aborted=0
  echo "$logged" | grep -q "expansion cancelled — user kept typing" && aborted=1

  local done_count
  done_count=$(echo "$logged" | grep -c "inject done" || true)

  if [[ "$sig_matched" -eq 0 ]]; then
    fail "$name" "'sig ' 가 매치되지 않았다 — 키가 엔진에 도달하지 않았거나 매처가 죽었다. 측정을 신뢰할 수 없다. 로그: $(echo "$logged" | tr '\n' ' ')"
    return
  fi
  if [[ "$aborted" -eq 0 ]]; then
    fail "$name" "매치 후 타이핑을 이어갔는데도 확장이 취소되지 않았다 — 파괴적 경합 재발. 로그: $(echo "$logged" | grep -E "matched|inject|cancelled" | tr '\n' ' ')"
    return
  fi
  if [[ "$done_count" -ne 1 ]]; then
    fail "$name" "'inject done' ${done_count}회 (기대: positive control ;e2e 1회뿐). 로그: $(echo "$logged" | grep -E "matched|inject|cancelled" | tr '\n' ' ')"
    return
  fi

  # 문서 확인. 로그가 이미 '백스페이스가 한 번도 나가지 않았다'를 증명하므로 이건
  # 보조 확인이지만, 이 케이스의 요점('next'가 먹히지 않았다)을 눈으로 못 박는다.
  # 기대: "sig next expanded-ok" — 'sig '는 확장되지 않고 그대로 남고, 'next'는 온전하다.
  #
  # 대소문자는 무시하고 비교한다. TextEdit이 스페이스로 단어가 끝나는 순간 문장 첫
  # 단어를 자동 대문자화해서 's'가 'S'로 바뀌기 때문이다(macOS의 '자동으로 단어 대문자화').
  # SnipKey가 한 일이 아니고, 엔진 로그가 백스페이스 0회를 증명한다. 글자가 먹히는 것과는
  # 무관한 변형이므로 이것만 흡수한다 — 글자 수·순서는 그대로 못 박는다. 문서 '전체'를
  # 기대값과 통째로 맞춰보므로, 한 글자라도 사라지면 여기서 걸린다.
  local text
  if text=$(textedit_text); then
    if [[ "${text:l}" != "sig next expanded-ok" ]]; then
      fail "$name" "엔진은 취소했지만 문서=[$text] — 기대(대소문자 무시): 'sig next expanded-ok'. 사용자가 친 글자가 먹혔거나 엉뚱한 것이 들어갔다."
      return
    fi
    pass "$name  문서=[$text]"
  else
    pass "$name  (엔진 로그로 취소 확인됨; TextEdit이 응답하지 않아 문서 확인은 생략)"
  fi
}

run_case_tab_terminator() {
  run_case_side_effect_key_does_not_expand \
    "(g) Tab does NOT terminate a bare-word abbreviation" 48
}

# ── (i) 필인 패널을 닫자마자 대상 앱에 타이핑하면 확장을 버린다 ────────────
# Codex가 찾아낸 파괴 경로. (h)가 '종결자 뒤로 계속 치는 경우'를 막았지만, 필인 경로는
# 지우기가 패널이 닫힌 '뒤'에 나가기 때문에 창이 하나 더 있다:
#
#   패널 닫힘 → 대상 앱으로 포커스 반환 → (0.25초 + 인젝터 정착) → 백스페이스
#
# 그 사이에 사용자가 대상 앱에 타이핑하면, 뒤늦게 나가는 백스페이스가 약어가 아니라
# 방금 친 글자를 먹는다. 카운터 모델은 포커스를 돌려준 '뒤'에 기준값을 다시 떠서 이
# 글자들을 '타이핑한 적 없는 것'으로 흡수해 버렸다 — 그래서 못 잡았다.
#
# 이제 가드는 '패널이 닫히는 순간'에 무장하고, 그 뒤에 도착한 키가 하나라도 있으면
# 확장을 버린다. 사용자가 치고 나서 '멈춰도' 잡힌다 — 정숙 여부가 아니라 '무장 이후에
# 왔는가'로 묻기 때문이다.
#
# 타이밍이 이 케이스의 전부다:
#   - Return 뒤 0.1초에 치기 시작한다. 그보다 빠르면 포커스가 아직 패널에서 TextEdit으로
#     넘어오는 중이라 키가 유실된다(실측: 첫 글자가 통째로 사라졌다). 그러면 '먹혔는지'를
#     문서로 판별할 수 없게 된다.
#   - 세 글자를 40ms 간격으로 몰아친다. 마지막 키가 Return + 0.18초쯤에 떨어져서, 파괴
#     구간(닫힘 → +0.25초 예약 → +0.16초 정착 → 백스페이스) 안에 완전히 들어간다.
#     예전 카운터 모델이 기준값에 흡수해 버리던 바로 그 구간이다.
#   - 그래서 이 케이스는 카운터 모델 바이너리에서 반드시 실패한다(비-공허성 확인 완료).
run_case_fill_in_typing_after_panel_aborts() {
  local name="(i) typing right after the fill-in panel closes aborts the expansion"
  new_document || { fail "$name" "TextEdit 준비 실패"; return; }
  clear_engine_buffer

  local mark=$(log_lines)

  # 구두점 시작 약어라 종결자를 기다리지 않고 즉시 발화한다 → 필인 패널이 뜬다.
  type_text ";fill"

  # 패널이 실제로 떠야 이 케이스가 성립한다. 안 뜨면 측정할 것이 없다.
  if ! wait_for 8 'grep -q "fill panel presented" "$LOG"'; then
    fail "$name" "필인 패널이 뜨지 않았다 — 이 경로를 측정할 수 없다. 로그: $(log_since "$mark" | tr '\n' ' ')"
    return
  fi

  # 필드에 값을 채우고 Return으로 닫은 '직후' 곧바로 대상 앱에 타이핑한다.
  # Return과 'keepme' 사이에 어떤 지연도 두지 않는 것이 이 케이스의 전부다.
  # `|| true` 필수 — 실패는 어설션이 잡아야지 set -e가 하네스를 죽여서는 안 된다.
  osascript >/dev/null 2>&1 <<'EOF' || true
with timeout of 60 seconds
  tell application "System Events"
    repeat with c in characters of "VAL"
      keystroke (c as text)
      delay 0.05
    end repeat
    key code 36
    delay 0.1
    repeat with c in characters of "abc"
      keystroke (c as text)
      delay 0.04
    end repeat
  end tell
end timeout
EOF

  # 확장(또는 취소)이 결론까지 가도록 기다린다.
  sleep 3

  # 문서를 '지금' 읽는다 — positive control(' ;e2e')을 치기 전에.
  # 스페이스로 단어가 끝나는 순간 TextEdit이 자동 수정/대문자화로 텍스트를 다시 쓴다
  # ('filleepme' → 'filled-me' 로 바뀌는 것을 실제로 봤다). 아직 단어가 끝나지 않은
  # 이 시점의 텍스트가 사용자가 실제로 친 것에 가장 가깝다.
  local typed_state
  typed_state=$(textedit_text) || typed_state="<읽기 실패>"

  # positive control. 키 입력 경로가 살아 있음을 증명한다.
  type_text " ;e2e"
  sleep 3

  local logged
  logged=$(log_since "$mark")

  local matched=0
  echo "$logged" | grep -q "matched ';fill'" && matched=1

  local aborted=0
  echo "$logged" | grep -q "expansion cancelled — user kept typing" && aborted=1

  # 'inject done'을 센다. 'inject start'는 엔진이 주입을 '결정'한 시점에 찍히고,
  # 가드는 그 뒤 인젝터 큐에서 판정하므로 실제로 키가 나갔는지를 말해주지 않는다.
  local done_count
  done_count=$(echo "$logged" | grep -c "inject done" || true)

  if [[ "$matched" -eq 0 ]]; then
    fail "$name" "';fill' 이 매치되지 않았다 — 측정을 신뢰할 수 없다. 로그: $(echo "$logged" | tr '\n' ' ')"
    return
  fi
  if [[ "$aborted" -eq 0 ]]; then
    fail "$name" "패널을 닫자마자 타이핑했는데 확장이 취소되지 않았다 — 필인 파괴 경로 재발. 로그: $(echo "$logged" | grep -E "matched|inject|cancelled|panel" | tr '\n' ' ')"
    return
  fi
  if [[ "$done_count" -ne 1 ]]; then
    fail "$name" "'inject done' ${done_count}회 (기대: positive control ;e2e 1회뿐). 필인이 주입됐다면 백스페이스가 나갔다는 뜻이다. 로그: $(echo "$logged" | grep -E "matched|inject|cancelled" | tr '\n' ' ')"
    return
  fi

  # 문서 확인. 로그가 이미 '백스페이스가 한 번도 나가지 않았다'를 증명하지만, 이 케이스의
  # 요점(사용자가 친 글자가 먹히지 않았다)을 눈으로 못 박는다.
  #
  # 기대: ";fillabc" — 약어 ';fill' 이 그대로 남고, 패널을 닫은 뒤 친 'abc'도 온전하고,
  # 확장 결과(FILLED-)는 없다.
  #
  # 가드가 없으면 백스페이스 5개가 문서 끝에서부터 먹는다: ';fillabc' → ';fi' 가 되고
  # 그 뒤에 'FILLED-[VAL]'이 붙는다. 즉 'abc'도 ';fill'도 함께 파괴된다. 아래 세 검사는
  # 그 파괴를 정확히 잡는다.
  if [[ "$typed_state" == *"FILLED-"* ]]; then
    fail "$name" "문서=[$typed_state] — 취소했다면서 필인 확장이 들어갔다."
    return
  fi
  if [[ "$typed_state" != *"abc"* ]]; then
    fail "$name" "문서=[$typed_state] — 패널을 닫고 친 'abc'가 온전하지 않다. 백스페이스가 먹었다."
    return
  fi
  if [[ "$typed_state" != *";fill"* ]]; then
    fail "$name" "문서=[$typed_state] — 약어 ';fill' 이 지워졌다. 백스페이스가 나갔다는 뜻이다."
    return
  fi

  pass "$name  문서=[$typed_state]"
}

run_case_plain_expansion
run_case_substring_no_expansion
run_case_word_prefix_no_expansion
run_case_terminated_bare_word_expands
run_case_return_terminator
run_case_tab_terminator
run_case_typing_ahead_aborts_expansion
run_case_fill_in_typing_after_panel_aborts
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
