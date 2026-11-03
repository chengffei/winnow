import AppKit
import WinnowCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            ScanSettings()
                .tabItem { Label(L("Scanning"), systemImage: "magnifyingglass") }
        }
        .frame(width: 520)
    }
}

/// The app's language: follows the system unless the user picks one here.
/// Stored as this app's AppleLanguages, which macOS reads at launch.
enum AppLanguage {
    static let codes = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]
    private static let key = "language"

    /// "" means follow the system.
    static var selected: String { UserDefaults.standard.string(forKey: key) ?? "" }
    /// What the running app was started with.
    static let launched = selected

    static func select(_ code: String) {
        let defaults = UserDefaults.standard
        if code.isEmpty {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(code, forKey: key)
            defaults.set([code], forKey: "AppleLanguages")
        }
    }

    /// Each language's name in that language, e.g. 日本語.
    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        // Start the new copy once this one has quit, so both never run at once.
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(url.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var language = AppLanguage.selected

    var body: some View {
        Form {
            Picker(L("Language"), selection: $language) {
                Text(L("Match System")).tag("")
                Divider()
                ForEach(AppLanguage.codes, id: \.self) { code in
                    Text(AppLanguage.name(code)).tag(code)
                }
            }
            .onChange(of: language) { AppLanguage.select(language) }

            if language != AppLanguage.launched {
                HStack {
                    Text(model.job == nil ? L("The new language applies after Winnow restarts.")
                                          : L("The new language applies after Winnow restarts. Wait for the scan to finish first."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Restart Now")) { AppLanguage.relaunch() }
                        .disabled(model.job != nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScanSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: UInt64?
    @State private var newItem = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(L("Processor use"), selection: $model.options.speed) {
                    Text(L("All cores")).tag(ScanSpeed.full)
                    Text(L("Half the cores")).tag(ScanSpeed.reduced)
                    Text(L("One core")).tag(ScanSpeed.minimal)
                }
            } header: {
                Text(L("Speed"))
            } footer: {
                Text(L("Using less keeps the Mac responsive during long scans, but scans take longer."))
                    .settingsFootnote()
            }

            Section {
                Toggle(L("Remember file fingerprints"), isOn: $model.options.useCache)
                HStack {
                    Text(L("Cache size"))
                    Spacer()
                    Text(cacheSize.map(Fmt.bytes) ?? "…").foregroundStyle(.secondary).monospacedDigit()
                    Button(L("Clear Cache")) {
                        HashCache.clear()
                        cacheSize = HashCache.size()
                    }
                    .disabled(model.job != nil || cacheSize == 0)
                }
            } header: {
                Text(L("Cache"))
            } footer: {
                Text(L("Files that have not changed are not read again on the next scan. Clear the cache if results look out of date."))
                    .settingsFootnote()
            }

            Section {
                ForEach(model.options.alwaysSkip, id: \.self) { item in
                    HStack {
                        Text(item).font(.body.monospaced())
                        Spacer()
                        Button {
                            model.options.alwaysSkip.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L("Remove"))
                    }
                }
                HStack {
                    TextField("", text: $newItem, prompt: Text(L("Name or pattern, e.g. node_modules or *.tmp")))
                        .labelsHidden()
                        .onSubmit(add)
                    Button(L("Add"), action: add)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(L("Always Skip"))
            } footer: {
                Text(L("Applies to every scan. A plain name skips any file or folder with that name. Trash, caches and NAS recycle bins are always skipped."))
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .task { cacheSize = await Task.detached { HashCache.size() }.value }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        if !model.options.alwaysSkip.contains(item) { model.options.alwaysSkip.append(item) }
        newItem = ""
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
