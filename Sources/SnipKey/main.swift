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
