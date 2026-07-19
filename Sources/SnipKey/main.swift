import AppKit
import ServiceManagement
import SnipKeyKit

// Headless CLI mode: `SnipKey --import-te <folder>` imports TextExpander data
// into the store and exits. Useful for scripted migration and testing.
let arguments = CommandLine.arguments

if arguments.contains("--enable-login-item") {
    do {
        try SMAppService.mainApp.register()
        print("SnipKey will now launch at login.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not enable launch at login: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
if let flagIndex = arguments.firstIndex(of: "--import-te") {
    let folder: URL
    if arguments.count > flagIndex + 1 {
        folder = URL(fileURLWithPath: arguments[flagIndex + 1])
    } else if let detected = TEImporter.detectDataFolders().first {
        folder = detected
    } else {
        FileHandle.standardError.write(Data("No TextExpander data folder found or given.\n".utf8))
        exit(1)
    }
    do {
        let store = Store()
        let result = try TEImporter.importFolder(folder)

        switch store.importGroups(result.groups) {
        case .saved:
            print("Imported \(result.snippetCount) snippets in \(result.groups.count) groups from \(result.sourcePath)")
            if result.richTextCount > 0 {
                print("Note: \(result.richTextCount) formatted snippets were converted to plain text")
            }
            exit(0)

        case .blockedByLoadFailure:
            let backup = store.loadFailure?.backupURL?.path ?? "no backup could be made"
            FileHandle.standardError.write(Data("""
            Import aborted: SnipKey could not read your existing snippet library, so nothing was written.
            Refusing to overwrite it. A copy was kept at: \(backup)
            Open SnipKey's Settings to retry the file or start fresh, then import again.

            """.utf8))
            exit(1)

        case .blockedByRemoteChange, .blockedByUnavailableLibrary, .blockedByNewerSchema:
            FileHandle.standardError.write(Data("""
            Import aborted: SnipKey will not write over the snippet library at its configured
            location, so nothing was written. It may still be downloading, its volume may be
            unmounted, or another Mac may have changed it. Nothing was lost — try again once
            the library is available.

            """.utf8))
            exit(1)

        case .failed(let message):
            FileHandle.standardError.write(Data("Import failed while saving: \(message)\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("Import failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// 조립된 앱 번들에서 현지화 리소스가 실제로 로드되는지 검사하고 종료한다.
// 1.2.0이 실행 즉시 크래시했다 — LocalizationManager.init → Bundle.module이 리소스
// 번들을 못 찾아 fatalError. 설치본에서만 재현돼, "번들을 직접 열어보는" 우회 검증은
// 통과하고 실제 앱 실행 경로만 죽었다. 그래서 CI가 조립한 번들을 이 플래그로 직접
// 실행해, 진짜 LocalizationManager 코드로 세 언어가 키가 아닌 번역으로 해석되는지
// 본다. GUI 세션이 필요 없어 헤드리스 러너에서도 돈다.
if arguments.contains("--selfcheck") {
    let suite = UserDefaults(suiteName: "snipkey.selfcheck") ?? .standard
    suite.removePersistentDomain(forName: "snipkey.selfcheck")
    let loc = LocalizationManager(deviceDefaults: suite)

    var failures: [String] = []
    var resolved: [AppLanguage: String] = [:]
    for lang in [AppLanguage.en, .ko, .ja] {
        loc.language = lang
        let v = loc.s("tab.snippets")
        resolved[lang] = v
        // 키 그대로면 리소스 번들을 못 잡고 .main 폴백으로 떨어진 것이다.
        if v == "tab.snippets" {
            failures.append("\(lang.rawValue): resource bundle not loaded (got the key back)")
        }
    }
    // 언어별로 다른 테이블이 실제로 로드됐는지 — ko/ja가 en과 같으면 한 언어만 로드된 것.
    if let en = resolved[.en], resolved[.ko] == en { failures.append("ko table did not load (== en)") }
    if let en = resolved[.en], resolved[.ja] == en { failures.append("ja table did not load (== en)") }

    if failures.isEmpty {
        print("selfcheck OK — en=\(resolved[.en] ?? "?") ko=\(resolved[.ko] ?? "?") ja=\(resolved[.ja] ?? "?")")
        exit(0)
    } else {
        FileHandle.standardError.write(Data(("selfcheck FAILED:\n  " + failures.joined(separator: "\n  ") + "\n").utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// SnipKey is a normal app with a Dock icon, even though its day-to-day home is
// the menu bar. It was a menu-bar-only (.accessory) app at first, and that turned
// out to be the wrong trade: an accessory app cannot become the active app, so
// its window opened without keyboard focus — ⌘N and ⌘F went to whatever app was
// in front, and ⌘C/⌘V did not work inside the snippet editor. A Dock icon is a
// small price for a window that behaves like every other window on the Mac.
app.setActivationPolicy(.regular)
app.run()
