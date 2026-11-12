import XCTest
import Observation
@testable import MuroKit

/// Muro's languages (issue #62). The tables are read from the source tree, the
/// same files `build-app.sh` copies into the app.
final class LocalizationTests: XCTestCase {
    /// `Muro/`, two folders above this file.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let tables = root.appendingPathComponent("Localization", isDirectory: true)
    private static let sources = root.appendingPathComponent("Sources", isDirectory: true)

    override func tearDown() {
        Localization.shared.useTables(in: nil)
        Localization.shared.use(.english, followingSystem: true)
        super.tearDown()
    }

    // MARK: - The rules

    func testPluralFormsFollowEachLanguage() {
        XCTAssertEqual(MuroLanguage.english.pluralCategory(1), "one")
        XCTAssertEqual(MuroLanguage.english.pluralCategory(0), "other")
        XCTAssertEqual(MuroLanguage.english.pluralCategory(2), "other")
        XCTAssertEqual(MuroLanguage.french.pluralCategory(0), "one")
        XCTAssertEqual(MuroLanguage.french.pluralCategory(1), "one")
        XCTAssertEqual(MuroLanguage.french.pluralCategory(2), "other")
        XCTAssertEqual(MuroLanguage.portuguese.pluralCategory(0), "one")
        for one in [1, 21, 31, 101] { XCTAssertEqual(MuroLanguage.russian.pluralCategory(one), "one", "\(one)") }
        for few in [2, 3, 4, 22, 34] { XCTAssertEqual(MuroLanguage.russian.pluralCategory(few), "few", "\(few)") }
        for many in [0, 5, 11, 12, 14, 19, 25, 111] {
            XCTAssertEqual(MuroLanguage.russian.pluralCategory(many), "many", "\(many)")
        }
        for language in [MuroLanguage.simplifiedChinese, .traditionalChinese, .japanese, .korean] {
            XCTAssertEqual(language.pluralCategory(1), "other")
        }
    }

    func testTheMacsLanguageListPicksMurosLanguage() {
        XCTAssertEqual(MuroLanguage.best(for: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["yue-Hant"]), .traditionalChinese)
        XCTAssertEqual(MuroLanguage.best(for: ["pt-PT"]), .portuguese)
        XCTAssertEqual(MuroLanguage.best(for: ["es-MX"]), .spanish)
        XCTAssertEqual(MuroLanguage.best(for: ["fr_CA"]), .french)
        XCTAssertEqual(MuroLanguage.best(for: ["nl-NL", "de-DE", "en-US"]), .german)
        XCTAssertEqual(MuroLanguage.best(for: ["sv-SE"]), .english)
        XCTAssertEqual(MuroLanguage.best(for: []), .english)
    }

    func testValuesGoInTheirPlaces() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(Localization.fill("%@ of %@", with: [1, 2], locale: en), "1 of 2")
        XCTAssertEqual(Localization.fill("%2$@ before %1$@", with: ["a", "b"], locale: en), "b before a")
        XCTAssertEqual(Localization.fill("%@% of %@", with: [42, "129 MB"], locale: en), "42% of 129 MB")
        XCTAssertEqual(Localization.fill("below 20% battery", with: [], locale: en), "below 20% battery")
        XCTAssertEqual(Localization.fill("100%% sure", with: [], locale: en), "100% sure")
        // A value the line has no place for is dropped, never a crash.
        XCTAssertEqual(Localization.fill("%@ and %@", with: ["one"], locale: en), "one and ")
    }

    // MARK: - The tables

    func testEveryLanguageHasEveryLineOfTheEnglish() throws {
        let english = Localization.load(.english, from: Self.tables)
        XCTAssertGreaterThan(english.count, 400)
        let counted = Set(english.keys.filter { $0.contains("#") }.map { Self.base($0) })
        for language in MuroLanguage.allCases where language != .english {
            let table = Localization.load(language, from: Self.tables)
            let name = language.rawValue
            XCTAssertFalse(table.isEmpty, "\(name) has no table")
            for key in english.keys where !key.contains("#") {
                XCTAssertNotNil(table[key], "\(name) is missing \(key)")
            }
            for key in counted {
                XCTAssertNotNil(table[key + "#other"], "\(name) is missing \(key)#other")
            }
            for (key, value) in table {
                let base = Self.base(key)
                let form = key.contains("#") ? String(key[key.index(after: key.lastIndex(of: "#")!)...]) : nil
                if let form {
                    XCTAssertTrue(counted.contains(base), "\(name) has an unknown counted line \(key)")
                    XCTAssertTrue(["one", "few", "many", "other", "=1"].contains(form), "\(name) \(key)")
                } else {
                    XCTAssertNotNil(english[key], "\(name) has a line English does not: \(key)")
                }
                XCTAssertFalse(value.isEmpty, "\(name) \(key) is empty")
                XCTAssertFalse(value.contains("\u{2014}"), "\(name) \(key) has an em dash")
                let want = Self.arguments(base.components(separatedBy: Localization.contextMark)[0])
                let got = Self.arguments(value)
                XCTAssertFalse(got.mixed, "\(name) \(key) mixes %@ and %1$@")
                // A line for exactly one may leave the number out, and so may
                // "one" where it means exactly one.
                let mayDropCount = form == "=1"
                    || (form == "one" && [MuroLanguage.german, .spanish, .italian].contains(language))
                if mayDropCount, got.indices == want.indices.filter({ $0 != 0 }) { continue }
                XCTAssertEqual(got.indices, want.indices, "\(name) \(key) = \(value)")
            }
        }
    }

    func testEveryLineTheCodeAsksForIsInTheEnglish() throws {
        let english = Localization.load(.english, from: Self.tables)
        let used = try Self.keysInCode()
        XCTAssertGreaterThan(used.count, 400)
        for (key, counted) in used {
            if counted {
                XCTAssertNotNil(english[key + "#one"], "English is missing \(key)#one")
                XCTAssertNotNil(english[key + "#other"], "English is missing \(key)#other")
            } else {
                XCTAssertNotNil(english[key], "English is missing \(key)")
            }
        }
        // And nothing in the table that the code no longer asks for. Categories
        // and Apple's screen saver names are looked up by their stored names.
        let usedKeys = Set(used.map(\.key))
        for key in english.keys {
            let base = Self.base(key)
            if base.hasSuffix("@@category") || base.hasSuffix("@@saver") { continue }
            XCTAssertTrue(usedKeys.contains(base), "English has a line nothing uses: \(key)")
        }
    }

    func testEveryLanguageCarriesItsSmallTables() {
        for language in MuroLanguage.allCases {
            let folder = Self.tables.appendingPathComponent(language.rawValue + ".lproj")
            let info = folder.appendingPathComponent("InfoPlist.strings")
            let plist = (try? Data(contentsOf: info)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String]
            }
            XCTAssertNotNil(plist?["NSHumanReadableCopyright"], "\(language.rawValue) InfoPlist.strings")
            let ext = Self.tables.appendingPathComponent("Extension/\(language.rawValue).lproj/Localizable.strings")
            let lines = (try? Data(contentsOf: ext)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String]
            }
            XCTAssertEqual(lines?.count, 2, "\(language.rawValue) extension table")
        }
    }

    // MARK: - Looking up

    func testLinesComeOutInTheChosenLanguage() {
        let localization = Localization.shared
        localization.useTables(in: Self.tables)

        localization.use(.english)
        XCTAssertEqual(L("Settings"), "Settings")
        XCTAssertEqual(LN("%@ wallpapers", 1), "1 wallpaper")
        XCTAssertEqual(LN("%@ wallpapers", 12), "12 wallpapers")
        XCTAssertEqual(LN("Delete %@ wallpapers?", 1), "Delete this wallpaper?")

        localization.use(.german)
        XCTAssertEqual(L("Settings"), "Einstellungen")
        XCTAssertEqual(LN("%@ wallpapers", 1), "1 Hintergrundbild")
        XCTAssertEqual(LN("%@ wallpapers", 3), "3 Hintergrundbilder")
        XCTAssertEqual(L("Default", ctx: "look"), "Standard")

        localization.use(.simplifiedChinese)
        XCTAssertEqual(L("Lock screen"), "锁屏")
        XCTAssertEqual(LN("Delete %@ wallpapers?", 1), "删除这个墙纸？")
        XCTAssertEqual(LN("Delete %@ wallpapers?", 3), "删除 3 个墙纸？")
        XCTAssertEqual(L("%@ wallpapers in %@", ctx: nil), "%@ wallpapers in %@",
                       "a counted line asked for as a plain one falls back to its key")

        localization.use(.russian)
        XCTAssertEqual(LN("Delete %@ screen savers?", 1), "Удалить эту заставку?")
        XCTAssertEqual(LN("Delete %@ screen savers?", 21), "Удалить 21 заставку?")
        XCTAssertEqual(LN("Delete %@ screen savers?", 3), "Удалить 3 заставки?")
        XCTAssertEqual(LN("Delete %@ screen savers?", 5), "Удалить 5 заставок?")

        localization.use(.french)
        XCTAssertEqual(LN("%@ wallpapers", 0), "0 fond d’écran")
        XCTAssertEqual(LN("Delete %@ wallpapers?", 1), "Supprimer ce fond d’écran\u{00A0}?")

        localization.use(.japanese)
        XCTAssertEqual(LN("Cycle: %2$@ across %1$@ wallpapers", 4, "1 時間"), "サイクル：4 枚の壁紙で 1 時間")

        // A language the table has no line for falls back to English.
        XCTAssertEqual(L("No such line in any table"), "No such line in any table")
    }

    func testTheChoiceIsSeenByTheScreen() {
        let localization = Localization.shared
        localization.useTables(in: Self.tables)
        localization.use(.english)
        let changed = expectation(description: "a view reading text is told the language changed")
        withObservationTracking {
            _ = L("Settings")
        } onChange: {
            changed.fulfill()
        }
        localization.use(.italian)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(L("Settings"), "Impostazioni")
    }

    // MARK: - Helpers

    private static func base(_ key: String) -> String {
        guard let mark = key.lastIndex(of: "#") else { return key }
        return String(key[..<mark])
    }

    /// The values a line takes, by position: "%@ of %@" is [0, 1].
    private static func arguments(_ text: String) -> (indices: [Int], mixed: Bool) {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?@")
        var out: [Int] = []
        var next = 0
        var numbered = false
        var plain = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) {
                out.append(Int(text[range])! - 1)
                numbered = true
            } else {
                out.append(next)
                next += 1
                plain = true
            }
        }
        return (out.sorted(), numbered && plain)
    }

    /// Every `L("…")` and `LN("…")` in Muro's code, with its context when it
    /// has one.
    private static func keysInCode() throws -> [(key: String, counted: Bool)] {
        var found: [String: Bool] = [:]
        let call = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(LN?)\\(\"((?:[^\"\\\\]|\\\\.)*)\"")
        let context = try NSRegularExpression(pattern: "ctx:\\s*\"([^\"]+)\"")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            guard file.lastPathComponent != "Localization.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let utf16 = Array(text.utf16)
            for match in call.matches(in: text, range: NSRange(location: 0, length: utf16.count)) {
                let kind = (text as NSString).substring(with: match.range(at: 1))
                let key = (text as NSString).substring(with: match.range(at: 2))
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                // The rest of the call, up to its closing bracket, for a ctx:.
                var depth = 1
                var index = match.range.location + match.range.length
                var inString = false
                let start = index
                while index < utf16.count, depth > 0 {
                    let unit = utf16[index]
                    if unit == 0x22, index == 0 || utf16[index - 1] != 0x5C { inString.toggle() }
                    if !inString {
                        if unit == 0x28 { depth += 1 }
                        if unit == 0x29 { depth -= 1 }
                    }
                    index += 1
                }
                let rest = NSRange(location: start, length: index - start)
                let ctx = context.firstMatch(in: text, range: rest)
                    .map { (text as NSString).substring(with: $0.range(at: 1)) }
                let full = ctx.map { key + Localization.contextMark + $0 } ?? key
                found[full] = kind == "LN"
            }
        }
        return found.map { ($0.key, $0.value) }
    }
}
