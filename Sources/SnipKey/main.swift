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
// Menu bar only — no Dock icon.
app.setActivationPolicy(.accessory)
app.run()
