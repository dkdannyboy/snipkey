# SnipKey

macOS용 무료 오픈소스 텍스트 확장기이자 핫키 매크로 도구입니다. TextExpander를
그대로 대체할 수 있고(원클릭 마이그레이션 제공), Keyboard Maestro에서 매일 쓰는
기능들을 함께 담았습니다.

네이티브 Swift, Apple Silicon, 구독 없음, 계정 없음, 네트워크 접속 없음.

SnipKey는 메뉴 막대(⚡ 아이콘)에 살면서 Dock 아이콘도 함께 둡니다. 처음에는 메뉴
막대 전용으로 만들었는데, macOS는 액세서리 앱이 활성화되는 것을 허용하지 않습니다.
그래서 창이 키보드 포커스 없이 열렸고 — ⌘N은 앞에 있던 다른 앱으로 가버렸고,
스니펫 편집기 안에서 ⌘C/⌘V가 먹지 않았습니다. Mac의 다른 창들처럼 정상 동작하는
창을 얻는 대가로 Dock 아이콘 하나는 싼 값입니다.

> English documentation: [README.md](README.md)

---

## 무엇을 하는가

**텍스트 확장.** 어느 앱에서든 약어를 치면 SnipKey가 전체 텍스트로 바꿔줍니다.
`;sig`는 서명이 되고, `;addr`은 주소가 됩니다.

구두점으로 시작하는 약어(`;sig`, `/addr`, `,date`)는 **다 치는 순간 즉시** 확장됩니다.
구두점이 있으면 모호하지 않기 때문입니다 — 그렇게 시작하는 실제 단어는 없으니까요.

`sig` 같은 맨몸 약어는 **종결자**(공백, 마침표, 단어가 아닌 문자)를 칠 때까지
기다렸다가 확장됩니다. 그래야만 합니다. `sig`는 `signal`, `sign`, `signature`의 첫
세 글자라서, 치는 즉시 확장하면 그 단어들을 아예 쓸 수 없게 됩니다 — SnipKey가
타이핑 도중에 먹어버리니까요. `sig `를 치면 서명 다음에 그 공백이 정확히 원래 자리에
남습니다. 치자마자 확장되기를 원한다면 `;sig` 형태의 약어를 쓰세요.

**Return과 Tab은 맨몸 약어의 종결자가 아닙니다.** 단어를 끝내는 키인데도 SnipKey는
일부러 무시하며, 그 이유는 알아둘 가치가 있습니다. SnipKey는 키 입력을 삼키지 않고
지켜보기만 하므로, SnipKey가 움직일 수 있는 시점엔 그 키가 이미 앱에 도착해 있습니다.
그런데 Return과 Tab은 *일을 저지릅니다*. Slack에서 Return은 메시지를 전송합니다.
양식에서 Tab은 다음 칸으로 포커스를 옮깁니다. 이 키로 확장한다면 `sig`가 그대로
전송된 뒤에 서명이 도착하거나, 방금 이동한 칸에 서명이 박힐 겁니다. **엉뚱한 곳에
확장되는 것은 확장이 안 되는 것보다 나쁩니다.** 그래서 하지 않습니다. 공백이나
구두점으로 끝내시거나, 종결자를 아예 기다리지 않는 `;sig` 형태를 쓰세요.

**어디서든 검색 (⌘/).** 약어가 기억나지 않나요? 어느 앱에서 타이핑하다가 ⌘/를
누르면 약어·라벨·내용으로 라이브러리 전체를 검색하고, Return으로 원하는 것을 확장할
수 있습니다. 수백 개짜리 라이브러리를 실제로 쓸 수 있게 만드는 기능입니다.

**TextExpander 마이그레이션.** SnipKey에 기존 TextExpander 데이터를 가리키면 모든
그룹·약어·스니펫을 가져옵니다 — 필인, 중첩 스니펫, 클립보드 매크로까지요. 다시 칠
것이 없습니다.

**핫키 매크로.** 텍스트 삽입, 셸 스크립트 실행, AppleScript 실행, 앱 열기, URL 열기를
전역 단축키로 실행합니다. Keyboard Maestro의 기본기를, 가격표 없이.

**필인 양식.** 스니펫이 잠시 멈추고 이름이나 금액을 묻거나 목록에서 고르게 한 뒤,
최종 텍스트를 조립할 수 있습니다.

---

## 설치

macOS 13 이상이 필요합니다.

[최신 릴리스][releases]에서 `SnipKey.dmg`를 받아 열고 SnipKey를 응용 프로그램으로
끌어다 놓으세요. 디스크 이미지는 Apple의 서명과 공증을 받았으므로 Gatekeeper 경고
없이 열립니다.

[releases]: https://github.com/dkdannyboy/snipkey/releases

Homebrew로 설치할 수도 있습니다:

```bash
brew tap dkdannyboy/tap
brew trust dkdannyboy/tap      # Homebrew는 서드파티 tap에 대해 신뢰를 확인합니다
brew install --cask snipkey
```

이후 업데이트는 `brew upgrade --cask snipkey`로 합니다. 앱을 지워도 스니펫
라이브러리는 남습니다. 그것까지 지우려면 `brew uninstall --zap --cask snipkey`를
쓰세요.

직접 빌드하려면:

```bash
git clone https://github.com/dkdannyboy/snipkey.git
cd snipkey
./scripts/build-app.sh --install
open /Applications/SnipKey.app
```

첫 실행 시 설정 도우미가 필요한 권한 하나를 안내하고, 스니펫을 가져오는 것을(또는
샘플로 새로 시작하는 것을) 도와줍니다.

### 손쉬운 사용 권한

macOS는 사용자가 무엇을 치는지 지켜보고 대신 타이핑하는 앱에 **손쉬운 사용**
권한을 요구합니다. 피할 방법은 없습니다 — TextExpander, Keyboard Maestro를 비롯한
모든 확장기가 똑같은 것을 필요로 합니다.

시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → **SnipKey** 켜기.

SnipKey에는 네트워크 코드가 아예 없습니다. 여러분이 친 것은 Mac 밖으로 나가지
않습니다.

> **SnipKey를 재빌드한 뒤 확장이 멈췄다면:** macOS는 이 권한을 앱의 코드 서명에
> 묶습니다. 배포된 빌드나 정식 인증서로 서명한 빌드는 번들 ID와 팀 ID로 식별되므로
> 업데이트해도 권한이 유지됩니다. 하지만 서명 인증서가 하나도 없는 Mac에서 빌드하면
> ad-hoc으로 서명되어 코드 해시만으로 식별됩니다 — 그래서 재빌드할 때마다 완전히 새
> 앱처럼 보이고, 스위치는 켜진 채로 macOS가 조용히 무시합니다. SnipKey 설정에서
> **Clear Permission and Re-grant**를 쓰거나 `tccutil reset Accessibility
> io.snipkey.mac`을 실행한 뒤 다시 켜세요. 아예 겪지 않으려면 Xcode에 Apple ID로
> 로그인하세요 — 무료 계정도 인증서를 발급하며 `build-app.sh`가 알아서 집어 씁니다.

---

## TextExpander에서 옮겨오기

SnipKey는 TextExpander 4/5 데이터를 직접 읽습니다. 첫 실행 시 흔한 위치들을 살펴봅니다:

- `~/Library/Mobile Documents/com~apple~CloudDocs/TextExpander/Settings.textexpandersettings` (iCloud)
- `~/Library/Application Support/TextExpander/Settings.textexpandersettings`
- `~/Dropbox/TextExpander/Settings.textexpandersettings`
- `~/Library/Application Support/TextExpander/Backups/` 안의 가장 최신 백업

데이터가 다른 곳에 있다면 **Import from folder…**로 `.textexpandersettings`나
`.textexpanderbackup` 폴더를 고르세요.

명령줄로도 옮길 수 있습니다:

```bash
/Applications/SnipKey.app/Contents/MacOS/SnipKey --import-te /path/to/data.textexpanderbackup
```

서식 있는(리치 텍스트) 스니펫은 평문으로 들어오고, 나머지는 그대로 넘어옵니다.

---

## 매크로 레퍼런스

SnipKey는 TextExpander의 매크로 문법을 그대로 씁니다. 가져온 스니펫이 계속
동작합니다.

| 매크로 | 하는 일 |
|---|---|
| `%filltext:name=X%` | 한 줄 텍스트를 묻습니다 |
| `%filltext:name=X:default=Y%` | …기본값과 함께 |
| `%fillarea:name=X%` | 여러 줄 텍스트를 묻습니다 |
| `%fillpopup:name=X:one:two:default=one%` | 목록에서 고르게 합니다 |
| `%fillpart:name=X:default=yes%` … `%fillpartend%` | 껐다 켤 수 있는 선택 구간 |
| `%snippet:;abbrev%` | 다른 스니펫을 삽입합니다 (최대 10단계 중첩) |
| `%clipboard` | 현재 클립보드 텍스트를 넣습니다 |
| `%date:yyyy-MM-dd%` | 날짜·시각을 `DateFormatter` 형식으로 넣습니다 |
| `%\|` | 확장 후 커서를 이 자리에 둡니다 |
| `%key:enter%` | 확장 후 키를 누릅니다 (`enter`, `tab`, `escape`, `space`) |

매크로가 아닌 퍼센트 기호(인코딩된 URL의 `%EC%9D%B4` 같은 것)는 건드리지 않습니다.

---

## 키보드 단축키

| 단축키 | 위치 | 동작 |
|---|---|---|
| `⌘/` | 모든 앱 | 스니펫을 검색해 고른 것을 확장 |
| `↑` `↓` `↩` `⌘1`–`⌘9` `esc` | 검색 팔레트 | 이동, 확장, 바로가기, 닫기 |
| `⌘F` | SnipKey 창 | 검색 필드로 포커스 |
| `⌘N` | SnipKey 창 | 새 스니펫 (그 자리로 스크롤하고 강조) |

검색 단축키는 설정에서 바꾸거나 끌 수 있습니다.

---

## 핫키 매크로

| 동작 | 인자 |
|---|---|
| Insert Text | 붙여넣을 텍스트 (위 매크로도 동작합니다) |
| Run Shell Script | 스크립트 소스, `/bin/zsh -lc`로 실행 |
| Run AppleScript | AppleScript 소스 |
| Open URL | URL 또는 파일 경로 |
| Open Application | 앱 이름(`Safari`) 또는 전체 경로 |

핫키 필드를 클릭하고 조합을 누르면 단축키가 설정됩니다. 수정자 키가 최소 하나는
필요합니다.

매크로를 항상 쓸 수 있게 하려면 설정에서 **Launch SnipKey at login**을 켜거나
다음을 실행하세요:

```bash
/Applications/SnipKey.app/Contents/MacOS/SnipKey --enable-login-item
```

---

## 데이터가 있는 곳

| 무엇 | 경로 |
|---|---|
| 스니펫, 매크로, 설정 | `~/Library/Application Support/SnipKey/store.json` |
| 문제 해결 로그 | `~/Library/Logs/SnipKey.log` |

`store.json`은 평범한 JSON입니다 — 백업하거나 손으로 편집할 수 있습니다. 설정에
**Export snippets…** 버튼도 있습니다.

> **여러 Mac에서 함께 쓰는 것에 대하여:** SnipKey에는 아직 동기화 기능이 없습니다.
> `store.json`을 iCloud Drive 같은 곳에 두고 두 Mac에서 동시에 SnipKey를 실행하면,
> 각 앱이 메모리에 들고 있는 사본으로 파일 전체를 덮어쓰기 때문에 한쪽의 변경이
> 조용히 사라집니다. 지금은 한 대를 주 편집기로 정하고 다른 쪽으로 파일을 복사해
> 쓰세요. 안전한 동기화는 작업 중입니다.

SnipKey가 그 파일을 찾았지만 읽지 못하면 — 동기화 사고, 절반만 쓰인 파일, 잘못된
손편집 — 그 위에 새로 시작하지 **않습니다**. 원본 옆에 시각이 찍힌 사본을 남기고,
저장을 거부하며, 설정에서 파일을 다시 시도할지 새로 시작할지 묻습니다. 읽기 실패로
스니펫이 덮어써지는 일은 없습니다.

---

## 개발

```bash
swift build          # 빌드
swift test           # 유닛 테스트 (파서 + 임포터 + 매처)
./scripts/build-app.sh           # dist/SnipKey.app 빌드
./scripts/build-app.sh --install # …그리고 /Applications에 설치
./scripts/release.sh             # 서명·공증된 dist/SnipKey-<버전>.dmg
```

기여 방법과 **일부러 그렇게 만든 동작들**(고치면 안 되는 것들)은
[CONTRIBUTING.md](CONTRIBUTING.md)를 읽어주세요.

코드는 두 타깃으로 나뉩니다:

- `SnipKeyKit` — 모델, JSON 저장소, TextExpander 임포터, 매크로 파서. UI 없음, 유닛
  테스트로 덮여 있습니다.
- `SnipKey` — 메뉴 막대 앱: 타이핑을 지켜보는 CGEvent 탭, 합성 키 입력 인젝터,
  Carbon 핫키 매니저, SwiftUI 창들.

### 코드 서명

`build-app.sh`는 키체인에서 찾을 수 있는 가장 좋은 인증서를 골라 쓰고, 어느 것을
썼는지 알려줍니다:

| 키체인의 인증서 | 서명 | 재빌드 후 유지 | 배포 가능 |
| --- | --- | --- | --- |
| `Developer ID Application` | 하드닝 런타임 + 신뢰 타임스탬프 | 예 | 예 — 릴리스는 이걸로 만듭니다 |
| `Apple Development` | 하드닝 런타임 | 예 | 아니오 — 자기 Mac에서만 실행 |
| 없음 | Ad-hoc | **아니오** | 아니오 |

일상에서 중요한 건 가운데 칸입니다. macOS는 손쉬운 사용 권한을 *지정된 요구사항*에
기록합니다. 제대로 서명된 앱이라면 그 요구사항은 "번들 ID `io.snipkey.mac`, 팀 ID
`36VF39Z75X`"이고 재빌드해도 바뀌지 않습니다. ad-hoc 빌드에는 팀 ID가 없어서
요구사항이 코드 해시로 주저앉는데, 그건 빌드할 때마다 바뀝니다. 권한이 증발하는
이유입니다.

그러니 SnipKey를 손보실 거면 Xcode에 Apple ID로 로그인해(무료도 충분합니다)
`Apple Development` 인증서를 발급받으세요. 그러면 권한이 사라지지 않습니다. 인증서
없이 막혔다면 `./scripts/dev-grant-accessibility.sh`가 낡은 TCC 항목을 지우고 앱을
다시 승인한 뒤, 이벤트 탭이 실제로 살아났는지 확인해 줍니다.

특정 인증서를 강제하려면 `SNIPKEY_SIGN_ID`로 덮어쓰세요:

```bash
SNIPKEY_SIGN_ID="Developer ID Application: 이름 (TEAMID)" ./scripts/build-app.sh
```

### 릴리스 만들기

`./scripts/release.sh`는 어느 Mac에서나 Gatekeeper 경고 없이 열리는 서명·공증된
`dist/SnipKey-<버전>.dmg`를 만듭니다. 두 가지가 필요합니다:

1. `Developer ID Application` 인증서 — Apple Developer Program 유료 멤버십이
   있어야 발급됩니다. Xcode → Settings → Accounts → Manage Certificates → **+** →
   Developer ID Application에서 발급하세요. 다른 Mac에 이미 있다면 키체인 접근에서
   *개인 키를 포함해* `.p12`로 내보낸 뒤 이 Mac에서 열면 됩니다.

2. 공증 자격증명 — 키체인에 한 번만 저장합니다:

   ```bash
   xcrun notarytool store-credentials snipkey-notary \
     --apple-id "you@example.com" \
     --team-id "36VF39Z75X" \
     --password "<앱 암호>"
   ```

   여기서 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호에서 발급하는
   앱 암호입니다. Apple ID 본 암호가 아닙니다.

둘 중 하나라도 없으면 스크립트가 이유를 설명하며 실행을 거부하므로, 절반만 서명된
빌드를 손에 쥘 일은 없습니다. 앱을 서명하고, Apple에 공증을 요청하고, 티켓을 앱
*그리고* 디스크 이미지에 스테이플한 뒤, `spctl`로 결과를 검증하고서야 성공을
알립니다.

---

## 라이선스

MIT. [LICENSE](LICENSE)를 보세요.
