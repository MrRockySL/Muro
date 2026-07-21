// Codable shapes matching WallpaperTypes. Derived from Phosphene (MIT),
// copyright 2026 kageroumado; see THIRD_PARTY_NOTICES.md.
import Foundation

struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

enum Disposability: Codable {
    case none, removable, purgeable

    private enum CodingKeys: String, CodingKey {
        case none, removable, purgeable
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .removable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .removable)
        case .purgeable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.removable) { self = .removable }
        else if container.contains(.purgeable) { self = .purgeable }
        else { self = .none }
    }
}

struct GroupID: Codable { var id: String }
struct GroupSortID: Codable { var id: String }

struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
}

enum ContentBadge: Codable {
    case none, video, dynamic

    private enum CodingKeys: String, CodingKey { case none, video, dynamic }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .video:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .video)
        case .dynamic:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.video) { self = .video }
        else if container.contains(.dynamic) { self = .dynamic }
        else { self = .none }
    }
}

enum Thumbnail: Codable {
    case image(url: URL)
    case customButton(CustomButton)

    private enum CodingKeys: String, CodingKey { case image, customButton }
    private enum ImageCodingKeys: String, CodingKey { case url }
    private enum CustomButtonCodingKeys: String, CodingKey { case _0 }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        case let .customButton(button):
            var nested = container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            try nested.encode(button, forKey: ._0)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.image) {
            let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            self = .image(url: try nested.decode(URL.self, forKey: .url))
        } else if container.contains(.customButton) {
            let nested = try container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            self = .customButton(try nested.decode(CustomButton.self, forKey: ._0))
        } else {
            self = .image(url: URL(fileURLWithPath: "/"))
        }
    }
}

enum CustomButton: Codable {
    case addPhotoButton, addColorButton, shuffleColorsButton

    private enum CodingKeys: String, CodingKey {
        case addPhotoButton, addColorButton, shuffleColorsButton
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addPhotoButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addPhotoButton)
        case .addColorButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addColorButton)
        case .shuffleColorsButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .shuffleColorsButton)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.addColorButton) { self = .addColorButton }
        else if container.contains(.shuffleColorsButton) { self = .shuffleColorsButton }
        else { self = .addPhotoButton }
    }
}

struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

struct WallpaperOption: Codable {}

struct ChoiceProviderID: Codable {
    var rawValue: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
}

enum RefreshPolicy: Codable {
    case `default`
    private enum CodingKeys: String, CodingKey { case `default` }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .default)
    }

    init(from decoder: any Decoder) throws { self = .default }
}

struct ContextMenu: Codable { var items: [ContextMenuItem] }
struct ContextMenuItem: Codable { var identifier: String; var name: String }
enum EmptyCodingKeys: CodingKey {}

@objc(ShimViewModelsXPC)
final class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("decode not needed") }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            extensionLog("settings archive failed: \(error)")
        }
    }
}
