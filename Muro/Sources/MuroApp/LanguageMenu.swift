import SwiftUI
import MuroKit

/// The list both language pickers open: the Language row in Settings and the
/// one in the menu bar (issue #62).
///
/// "Same as macOS" comes first and says which language that is on this Mac.
/// Every language after it is written in its own name, because the person
/// looking for theirs may not be able to read the one Muro is in right now.
@MainActor
enum LanguageMenu {
    /// The order they are listed in: the Latin alphabet first, by name, then
    /// the others.
    static let order: [MuroLanguage] = [
        .german, .english, .spanish, .french, .italian, .portuguese,
        .russian, .japanese, .korean, .simplifiedChinese, .traditionalChinese
    ]

    static func options(store: AppStore) -> [MenuOption] {
        let localization = Localization.shared
        let followsSystem = localization.followsSystem
        let chosen = localization.language
        var options = [
            MenuOption(
                title: L("Same as macOS"),
                checked: followsSystem,
                detail: Localization.systemLanguage().nativeName
            ) { store.setLanguage(nil) },
            MenuOption.divider
        ]
        options += order.map { language in
            MenuOption(title: language.nativeName, checked: !followsSystem && chosen == language) {
                store.setLanguage(language)
            }
        }
        return options
    }

    /// What a closed picker shows: the language Muro is in, in its own name.
    static var current: String { Localization.shared.language.nativeName }
}
