<div align="center">

# ⚡ SnipKey

**macOS용 무료 오픈소스 네이티브 GUI 텍스트 확장기 — TextExpander를 그대로 대체합니다.**

네이티브 Swift · Apple Silicon · 구독 없음 · 계정 없음 · 네트워크 접속 없음

[![Release](https://img.shields.io/github/v/release/dkdannyboy/snipkey?color=brightgreen)](https://github.com/dkdannyboy/snipkey/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/dkdannyboy/snipkey/total)](https://github.com/dkdannyboy/snipkey/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/dkdannyboy/snipkey/releases/latest)
[![Made with Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)](https://swift.org)

[English](README.md) · **한국어** · [日本語](README.ja.md)

<img src="docs/images/snippets.png" width="720" alt="SnipKey 스니펫 라이브러리">

</div>

---

어느 앱에서든 약어를 치면 SnipKey가 전체 텍스트로 바꿔줍니다. `;sig`는 서명이,
`;addr`은 주소가 됩니다. 메뉴 막대에 살면서, TextExpander 라이브러리를 한 번에
가져오고, 여러분이 친 키를 Mac 밖으로 내보내지 않습니다.

## 기능

- **어디서나 텍스트 확장.** 모든 앱에서 동작합니다. `;sig` → 서명.
- **어디서나 검색 (⌘/).** 약어가 기억나지 않나요? 어느 앱에서든 약어·라벨·내용으로
  라이브러리 전체를 검색하고 Return으로 확장합니다.
- **TextExpander 마이그레이션.** 모든 그룹·약어·스니펫을 가져옵니다 — 필인, 중첩
  스니펫, 클립보드 매크로까지. 다시 칠 것이 없습니다.
- **필인 양식.** 스니펫이 잠시 멈추고 이름이나 금액을 묻거나 목록에서 고르게 한 뒤
  최종 텍스트를 조립합니다.
- **다중 Mac 동기화.** iCloud Drive나 아무 동기화 폴더로 여러 Mac에서 같은
  라이브러리를 씁니다 — 스니펫을 잃지 않도록 지키는 안전장치와 함께.
- **3개 언어.** English·한국어·日本語, 설정에서 즉시 전환.
- **설계부터 프라이빗.** 계정도, 텔레메트리도, 네트워크 코드도 아예 없습니다.

## 왜 SnipKey인가?

텍스트 확장기는 이미 여럿 있습니다 — TextExpander 자체, 그리고
[Espanso](https://espanso.org) 같은 오픈소스 도구들. SnipKey는 **제대로 된 GUI를
갖춘 네이티브 Mac 앱**, **TextExpander 라이브러리를 그대로 가져오기**, **클라우드에
아무것도 두지 않기**를 원하는 사람을 위한 것입니다.

| | **SnipKey** | TextExpander | Espanso |
|---|---|---|---|
| 가격 | **무료** | 구독제 | 무료 |
| 오픈소스 | ✅ MIT | ❌ | ✅ |
| 네이티브 GUI 편집기 | ✅ | ✅ | 설정 파일(YAML) |
| TextExpander 원클릭 가져오기 | ✅ | — | ❌ |
| 계정 없이 완전 오프라인 | ✅ | ❌ | ✅ |
| 한국어 / English / 日本語 내장 UI | ✅ | ❌ | ❌ |

Espanso도 훌륭합니다 — 특히 Linux·Windows까지 필요하다면요. SnipKey는 일부러 Mac
전용, GUI 우선이며, 기존 TextExpander 라이브러리를 읽어와 스니펫을 하나도 잃지 않습니다.

## 설치

macOS 13 이상이 필요합니다.

**다운로드:** [최신 릴리스][releases]에서 `SnipKey.dmg`를 받아 열고 SnipKey를 응용
프로그램으로 끌어다 놓으세요. 디스크 이미지는 Apple의 서명과 공증을 받았으므로
Gatekeeper 경고 없이 열립니다.

**Homebrew:**

```bash
brew tap dkdannyboy/tap
brew trust dkdannyboy/tap      # Homebrew는 서드파티 tap에 대해 신뢰를 확인합니다
brew install --cask snipkey
```

이후 업데이트는 `brew upgrade --cask snipkey`.

첫 실행 시 설정 도우미가 필요한 권한 하나 — **손쉬운 사용** — 을 안내합니다. 무엇을
치는지 보고 대신 타이핑하려면 모든 텍스트 확장기가 이 권한을 요구합니다. 여러분이
친 것은 Mac 밖으로 나가지 않습니다.

[releases]: https://github.com/dkdannyboy/snipkey/releases

## 확장은 어떻게 동작하나

구두점으로 시작하는 약어(`;sig`, `/addr`, `,date`)는 다 치는 순간 즉시 확장됩니다.
구두점이 있으면 모호하지 않기 때문입니다.

`sig` 같은 맨몸 약어는 종결자(공백, 마침표, 단어가 아닌 문자)를 칠 때까지 기다렸다가
확장됩니다. 그래야만 합니다 — `sig`는 `signal`, `signature`의 첫 세 글자라, 치는 즉시
확장하면 그 단어들을 아예 쓸 수 없게 됩니다. `sig `를 치면 서명 뒤에 그 공백이
남습니다.

**Return과 Tab은 맨몸 약어의 종결자가 아닙니다** — 일부러 그렇게 했습니다. SnipKey는
키를 삼키지 않고 지켜보기만 하므로, 움직일 수 있는 시점엔 키가 이미 앱에 도착해
있습니다. 그런데 Return과 Tab은 *일을 저지릅니다*: Slack에서 Return은 전송, Tab은 다음
칸으로 이동. 엉뚱한 곳에 확장되는 것은 확장이 안 되는 것보다 나쁩니다. 공백이나
구두점으로 끝내거나 `;sig` 형태를 쓰세요.

## 다중 Mac 동기화

SnipKey는 자체 동기화 서비스를 돌리지 않습니다. 클라우드가 이미 동기화하는 폴더
(iCloud Drive, Dropbox 등) 안의 파일을 가리키면 클라우드가 알아서 동기화합니다.
**설정 → 동기화**에서:

- **Save Snippets As…** — 첫 Mac에서 라이브러리를 동기화 폴더로 복사합니다.
- **Link to Snippets…** — 두 번째 Mac에서 그 파일을 가리킵니다.
- **Don't Sync** — 로컬 전용 라이브러리로 돌아갑니다.

공유 라이브러리는 쉽게 망가집니다 — 두 Mac이 동시에 쓰거나, 아직 안 받은 iCloud
자리표시자거나, 전환이 절반만 끝나거나. SnipKey는 스니펫을 잃는 쪽이 되기를
거부합니다: 덮어쓰기 전에 백업하고, 파일이 밑에서 바뀌면 덮지 않고 다시 읽으며, 새
라이브러리가 온전히 읽히지 않으면 위치를 절대 바꾸지 않습니다.

## TextExpander에서 옮겨오기

SnipKey는 TextExpander 4/5 데이터를 직접 읽습니다. 첫 실행 시 흔한 위치(iCloud,
Application Support, Dropbox, 가장 최신 로컬 백업)를 살핍니다. 데이터가 다른 곳에
있다면 **설정 → 데이터 → Import from folder…**로 `.textexpandersettings`나
`.textexpanderbackup` 폴더를 고르세요.

서식 있는(리치 텍스트) 스니펫은 평문으로 들어오고, 나머지는 그대로 넘어옵니다.

## 매크로 레퍼런스

SnipKey는 TextExpander의 매크로 문법을 그대로 씁니다. 가져온 스니펫이 계속 동작합니다.

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
| <code>%&#124;</code> | 확장 후 커서를 이 자리에 둡니다 |
| `%key:enter%` | 확장 후 키를 누릅니다 (`enter`, `tab`, `escape`, `space`) |

## 키보드 단축키

| 단축키 | 위치 | 동작 |
|---|---|---|
| `⌘/` | 모든 앱 | 스니펫을 검색해 고른 것을 확장 |
| `⌘,` | 모든 창 | 설정 열기 |
| `⌘N` | SnipKey 창 | 새 스니펫 |
| `⌘F` | SnipKey 창 | 검색 필드로 포커스 |

## 데이터가 있는 곳

| 무엇 | 경로 |
|---|---|
| 스니펫·설정 | `~/Library/Application Support/SnipKey/store.json` |
| 문제 해결 로그 | `~/Library/Logs/SnipKey.log` |

`store.json`은 평범한 JSON입니다. SnipKey가 그 파일을 찾았지만 읽지 못하면 그 위에
새로 시작하지 **않습니다** — 시각이 찍힌 사본을 남기고, 저장을 거부하며, 어떻게 할지
묻습니다. 읽기 실패로 스니펫이 덮어써지는 일은 없습니다.

## 기여

Pull request를 환영합니다. [CONTRIBUTING.md](CONTRIBUTING.md)를 봐주세요 — 특히
버그처럼 보이지만 일부러 그렇게 만든 동작들의 목록을요.

```bash
git clone https://github.com/dkdannyboy/snipkey.git
cd snipkey
swift test                       # 유닛 테스트
./scripts/build-app.sh --install # 빌드 후 /Applications에 설치
```

## 라이선스

MIT. [LICENSE](LICENSE)를 보세요.

## 상표

TextExpander와 Espanso는 각 소유자의 상표입니다. SnipKey는 독립적인 오픈소스
프로젝트로, 이들과 제휴·후원·보증 관계가 없습니다. "그대로 대체"는 데이터·동작
호환성을 뜻하며 제휴를 뜻하지 않습니다.
