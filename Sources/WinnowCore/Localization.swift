import Foundation

/// Looks up an English key in the app's Localizable.strings and fills in printf-style arguments.
/// Keys and translations live in Localization/Translations.json; scripts/build-strings.py checks them.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

/// "A, B and C" in the user's language.
public func joinedList(_ items: [String]) -> String {
    ListFormatter.localizedString(byJoining: items)
}
