#!/bin/zsh
# Development helper: grants Accessibility to the freshly built SnipKey and
# verifies the expansion engine actually starts.
#
# Ad-hoc signed builds get a new code signature on every rebuild, which makes
# macOS silently ignore the existing Accessibility grant. This clears the stale
# entry, re-approves the app, and confirms the event tap came up. Retries
# because TCC commits asynchronously and can race with an app relaunch.
set -u

BUNDLE_ID="com.snipkey.app"
LOG=~/Library/Logs/SnipKey.log

grant_once() {
  osascript -e 'tell application "System Settings" to quit' 2>/dev/null
  pkill -f "SnipKey.app" 2>/dev/null
  sleep 2
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1
  sleep 1
  open /Applications/SnipKey.app
  sleep 5
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1
  sleep 6
  osascript <<'EOF' >/dev/null 2>&1
on findAndClick(el)
  tell application "System Events"
    try
      if class of el is checkbox and (name of el) is "SnipKey" then
        if (value of el) is 0 then click el
        delay 3
        return "ok"
      end if
    end try
    try
      repeat with c in UI elements of el
        set r to my findAndClick(c)
        if r is not "" then return r
      end repeat
    end try
    return ""
  end tell
end findAndClick
tell application "System Events" to tell process "System Settings" to my findAndClick(window 1)
EOF
  sleep 4
  osascript -e 'tell application "System Settings" to quit' 2>/dev/null
  pkill -f "SnipKey.app" 2>/dev/null
  sleep 3
  rm -f "$LOG"
  open /Applications/SnipKey.app
  sleep 6
  grep -q "engine started" "$LOG" 2>/dev/null
}

for attempt in 1 2 3; do
  echo "grant attempt $attempt…"
  if grant_once; then
    echo "ENGINE OK"
    exit 0
  fi
done
echo "ENGINE FAILED after 3 attempts"
exit 1
