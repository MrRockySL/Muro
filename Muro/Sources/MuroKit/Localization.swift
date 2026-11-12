import Foundation
import Observation

/// The languages Muro speaks.
///
/// The raw value is the name of the language's folder in the app
/// (`<code>.lproj`), which is also the code macOS knows it by, so the choice
/// made here and the one in System Settings > Language & Region > Applications
/// are the same setting.
public enum MuroLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt-BR"
    case russian = "ru"

    /// The language's own name for itself, which is how a language list reads
    /// to the one person who needs to find their language in it.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português (Brasil)"
        case .russian: return "Русский"
        }
    }

    /// For numbers and dates written in this language.
    public var locale: Locale { Locale(identifier: rawValue) }

    /// The best of Muro's languages for a list of preferred ones, most wanted
    /// first, the way macOS hands them out ("zh-Hans-CN", "es-MX", "pt-PT").
    /// English when none of them is one Muro has.
    public static func best(for preferences: [String]) -> MuroLanguage {
        for preference in preferences {
            if let match = match(preference) { return match }
        }
        return .english
    }

    private static func match(_ identifier: String) -> MuroLanguage? {
        let parts = identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map { $0.lowercased() }
        guard let code = parts.first else { return nil }
        switch code {
        case "en": return .english
        case "ja": return .japanese
        case "ko": return .korean
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ru": return .russian
        case "zh", "yue":
            // Written Chinese is one of two scripts. The script decides when it
            // is named; otherwise the place does, the way macOS reads it.
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains("hans") { return .simplifiedChinese }
            let traditional: Set<String> = ["tw", "hk", "mo"]
            return parts.dropFirst().contains(where: traditional.contains) || code == "yue"
                ? .traditionalChinese : .simplifiedChinese
        default: return nil
        }
    }

    /// Which form of a counted word a number takes in this language: "one",
    /// "few", "many" or "other", by the Unicode plural rules for whole numbers.
    public func pluralCategory(_ count: Int) -> String {
        let n = abs(count)
        switch self {
        case .english, .german, .italian, .spanish:
            return n == 1 ? "one" : "other"
        case .french, .portuguese:
            return n <= 1 ? "one" : "other"
        case .russian:
            let ten = n % 10, hundred = n % 100
            if ten == 1, hundred != 11 { return "one" }
            if (2...4).contains(ten), !(12...14).contains(hundred) { return "few" }
            return "many"
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return "other"
        }
    }
}

/// Muro's text in the language the person chose.
///
/// Every word the app shows goes through `L` (or `LN` for a counted word). The
/// English text is the key, so a line with no translation still reads in
/// English rather than as a blank or a code name.
///
/// The tables are plain `Localizable.strings` files, one folder per language,
/// the same files any Mac app carries. Muro reads them itself instead of
/// leaving it to macOS, because macOS settles an app's language once, when it
/// starts, and Muro changes language the moment one is picked.
///
/// Observable, and that is how the change reaches the screen: a view whose
/// body asks for a line of text is redrawn when the language changes, in
/// place, with its scroll position and state kept. Nothing is rebuilt and no
/// window is reopened. It is the same mechanism the look uses (`Appearance`).
public final class Localization: Observable, @unchecked Sendable {
    public static let shared = Localization()

    /// Posted on the main thread after the language changes.
    public static let didChange = Notification.Name("com.mrrockysl.muro.languageDidChange")

    /// Where a key's context begins. `L("All", ctx: "places")` looks up
    /// "All@@places", for the words one English spelling covers and another
    /// language needs two for.
    public static let contextMark = "@@"
    /// Where a counted key's form begins: "%@ wallpapers#one".
    public static let pluralMark = "#"

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var current: MuroLanguage = .english
    private var system = true
    private var table: [String: String] = [:]
    private var english: [String: String] = [:]
    private var folder: URL?

    private init() {
        folder = Self.defaultFolder()
        english = Self.load(.english, from: folder)
        let chosen = Self.chosenLanguage()
        system = chosen == nil
        current = chosen ?? MuroLanguage.best(for: Self.systemPreferences())
        table = current == .english ? english : Self.load(current, from: folder)
    }

    // MARK: Reading

    public var language: MuroLanguage {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { current }
    }

    /// True while Muro follows the Mac's own language instead of a choice made
    /// in Muro.
    public var followsSystem: Bool {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { system }
    }

    public var locale: Locale { language.locale }

    /// For dates and times: the chosen language, with the Mac's own region and
    /// its 12 or 24 hour clock, so a time reads the way this person set it.
    public var formattingLocale: Locale {
        let current = Locale.current
        let language = self.language
        // The Mac's own locale when it already speaks this language, so every
        // choice made in System Settings carries over untouched.
        if MuroLanguage.best(for: [current.identifier]) == language { return current }
        var parts = Locale.Components(locale: current)
        parts.languageComponents = Locale.Language.Components(identifier: language.rawValue)
        parts.hourCycle = current.hourCycle
        return Locale(components: parts)
    }

    /// The language Muro would use if it followed the Mac.
    public static func systemLanguage() -> MuroLanguage {
        MuroLanguage.best(for: systemPreferences())
    }

    // MARK: Choosing

    /// Changes the language everywhere at once. Nil follows the Mac's own.
    ///
    /// The choice is kept where macOS keeps an app's language, so the next
    /// start opens in it too, down to the parts macOS draws itself (the Open
    /// panel, the standard menus), and System Settings shows the same choice.
    public func choose(_ language: MuroLanguage?) {
        let defaults = UserDefaults.standard
        if let language {
            defaults.set([language.rawValue], forKey: Self.preferenceKey)
        } else {
            defaults.removeObject(forKey: Self.preferenceKey)
        }
        let resolved = language ?? MuroLanguage.best(for: Self.systemPreferences())
        use(resolved, followingSystem: language == nil)
    }

    /// Switches the tables without touching the saved choice. Tests and the
    /// first screen use it; everything else goes through `choose`.
    public func use(_ language: MuroLanguage, followingSystem: Bool = false) {
        let loaded = language == .english ? nil : Self.load(language, from: lock.withLock { folder })
        registrar.withMutation(of: self, keyPath: \.language) {
            lock.withLock {
                current = language
                system = followingSystem
                table = loaded ?? english
            }
        }
        let post = { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// Points Muro at another folder of language tables. For the tests, which
    /// read the files in the source tree rather than an app's.
    public func useTables(in folder: URL?) {
        let english = Self.load(.english, from: folder)
        let language = lock.withLock { current }
        let table = language == .english ? english : Self.load(language, from: folder)
        registrar.withMutation(of: self, keyPath: \.language) {
            lock.withLock {
                self.folder = folder
                self.english = english
                self.table = table
            }
        }
    }

    // MARK: Looking up

    /// The text for a key, with each `%@` (or `%1$@`, `%2$@`) replaced by the
    /// matching value.
    public func text(_ key: String, context: String? = nil, _ values: [Any] = []) -> String {
        registrar.access(self, keyPath: \.language)
        let full = context.map { key + Self.contextMark + $0 } ?? key
        let (found, language) = lock.withLock { (table[full] ?? english[full], current) }
        return Self.fill(found ?? key, with: values, locale: language.locale)
    }

    /// The text for a counted key in the form its number takes. The number is
    /// the first value.
    ///
    /// A line for exactly one, `key#=1`, comes first when there is one. It is
    /// for the sentences that drop the number when there is only one thing
    /// ("Delete this wallpaper?"), which in most languages cannot go in the
    /// "one" form: in Russian that form also covers 21, and in French 0.
    public func counted(_ key: String, _ count: Int, _ values: [Any] = []) -> String {
        registrar.access(self, keyPath: \.language)
        let (language, table, english) = lock.withLock { (current, self.table, self.english) }
        let form = language.pluralCategory(count)
        let exact = count == 1 ? table[key + Self.pluralMark + "=1"] : nil
        let found = exact
            ?? table[key + Self.pluralMark + form]
            ?? table[key + Self.pluralMark + "other"]
            ?? english[key + Self.pluralMark + MuroLanguage.english.pluralCategory(count)]
            ?? english[key + Self.pluralMark + "other"]
        return Self.fill(found ?? key, with: [count] + values, locale: language.locale)
    }

    /// Whether the chosen language has its own line for a key.
    public func hasTranslation(_ key: String) -> Bool {
        lock.withLock { table[key] != nil }
    }

    // MARK: Filling in values

    /// Puts values into a line of text. Written by hand rather than through
    /// `String(format:)`, which reads its arguments by type and crashes, or
    /// prints nonsense, the day a translation's `%@` meets a number.
    static func fill(_ format: String, with values: [Any], locale: Locale) -> String {
        guard !values.isEmpty, format.contains("%") else {
            return format.replacingOccurrences(of: "%%", with: "%")
        }
        let words = values.map { describe($0, locale: locale) }
        var out = ""
        var next = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                out.append(character)
                index = format.index(after: index)
                continue
            }
            var cursor = format.index(after: index)
            guard cursor < format.endIndex else { out.append("%"); break }
            if format[cursor] == "%" {
                out.append("%")
                index = format.index(after: cursor)
                continue
            }
            // "%@" takes the next value; "%2$@" takes the one it names.
            var digits = ""
            while cursor < format.endIndex, format[cursor].isNumber {
                digits.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            var position: Int?
            if !digits.isEmpty, cursor < format.endIndex, format[cursor] == "$" {
                position = Int(digits).map { $0 - 1 }
                cursor = format.index(after: cursor)
            } else if !digits.isEmpty {
                // Not a placeholder of ours ("100%" in running text).
                out.append("%")
                index = format.index(after: index)
                continue
            }
            guard cursor < format.endIndex, format[cursor] == "@" else {
                out.append("%")
                index = format.index(after: index)
                continue
            }
            let slot = position ?? next
            if position == nil { next += 1 }
            out.append(slot >= 0 && slot < words.count ? words[slot] : "")
            index = format.index(after: cursor)
        }
        return out
    }

    private static func describe(_ value: Any, locale: Locale) -> String {
        switch value {
        case let text as String: return text
        case let number as Int: return String(number)
        case let number as Int64: return String(number)
        case let number as Double:
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: number)) ?? String(number)
        default: return String(describing: value)
        }
    }

    // MARK: Files

    private static let preferenceKey = "AppleLanguages"

    /// The language picked for Muro alone, in Muro or in System Settings. Nil
    /// when nothing was picked and Muro follows the Mac.
    private static func chosenLanguage() -> MuroLanguage? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let own = UserDefaults.standard.persistentDomain(forName: bundleID)?[preferenceKey] as? [String],
              !own.isEmpty
        else { return nil }
        return MuroLanguage.best(for: own)
    }

    /// The Mac's own list of languages, not the one an app's choice replaces.
    private static func systemPreferences() -> [String] {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?[preferenceKey] as? [String]) ?? Locale.preferredLanguages
    }

    /// The folder holding the `<code>.lproj` folders: the app's resources, or
    /// the one named by `MURO_L10N_DIR` when the app runs outside a bundle.
    private static func defaultFolder() -> URL? {
        if let path = ProcessInfo.processInfo.environment["MURO_L10N_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Bundle.main.resourceURL
    }

    public static func load(_ language: MuroLanguage, from folder: URL?) -> [String: String] {
        guard let folder else { return [:] }
        let file = folder
            .appendingPathComponent(language.rawValue + ".lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let table = plist as? [String: String]
        else { return [:] }
        return table
    }
}

/// Muro's text for an English line, in the chosen language. Each `%@` in it is
/// replaced by the next value, so a sentence is translated whole and a language
/// that orders its words differently can say `%2$@` before `%1$@`.
public func L(_ key: String, _ values: Any..., ctx: String? = nil) -> String {
    Localization.shared.text(key, context: ctx, values)
}

/// Several sentences as one paragraph. Chinese and Japanese end a sentence
/// with a full-width stop and put nothing after it; the others put a space.
public func joinSentences(_ sentences: [String]) -> String {
    switch Localization.shared.language {
    case .simplifiedChinese, .traditionalChinese, .japanese: return sentences.joined()
    default: return sentences.joined(separator: " ")
    }
}

/// A counted line, in the form the number takes: `LN("%@ wallpapers", 3)`.
/// The number is the first `%@`.
public func LN(_ key: String, _ count: Int, _ values: Any...) -> String {
    Localization.shared.counted(key, count, values)
}
