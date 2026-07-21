// Settings-model remapping technique derived from Phosphene (MIT),
// copyright 2026 kageroumado; see THIRD_PARTY_NOTICES.md.
import Foundation

struct ExtensionWallpaperEntry: Codable {
    let id: String
    let title: String
    let videoFilename: String
    let thumbnailFilename: String
}

private struct ExtensionWallpaperLibrary: Codable {
    let wallpapers: [ExtensionWallpaperEntry]
}

private var documentsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
}

private func stagedEntries() -> [(ExtensionWallpaperEntry, URL, URL)] {
    let index = documentsURL.appendingPathComponent("library.json")
    guard let data = try? Data(contentsOf: index),
          let library = try? JSONDecoder().decode(ExtensionWallpaperLibrary.self, from: data)
    else {
        extensionLog("no staged lock-screen library")
        return []
    }

    return library.wallpapers.compactMap { entry in
        let directory = documentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
        let video = directory.appendingPathComponent(entry.videoFilename)
        let thumbnail = directory.appendingPathComponent(entry.thumbnailFilename)
        guard FileManager.default.fileExists(atPath: video.path),
              FileManager.default.fileExists(atPath: thumbnail.path)
        else {
            extensionLog("staged files missing for \(entry.id)")
            return nil
        }
        return (entry, video, thumbnail)
    }
}

func stagedVideoURL(for choiceID: String?) -> URL? {
    guard let choiceID else { return nil }
    return stagedEntries().first { $0.0.id == choiceID }?.1
}

func makeSettingsResponse() -> AnyObject? {
    let provider = ChoiceProviderID(rawValue: extensionDomain)
    let items = stagedEntries().enumerated().map { offset, staged in
        let (entry, video, thumbnail) = staged
        let descriptor = ChoiceIDDescriptor(
            provider: provider,
            identifier: entry.id,
            files: [video],
            configuration: Data(entry.id.utf8)
        )
        let choiceID = ChoiceID(id: entry.id, descriptor: descriptor)
        let choice = ChoiceDescriptor(
            id: choiceID,
            provider: provider,
            identifier: entry.id,
            name: entry.title,
            localizedDescription: "Muro live wallpaper",
            thumbnail: .image(url: thumbnail),
            isDownloaded: true,
            options: []
        )
        return SettingsItem(
            id: choiceID,
            localizedName: entry.title,
            thumbnail: .image(url: thumbnail),
            choice: choice,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: offset,
            disposability: .none
        )
    }

    let group = SettingsGroup(
        id: GroupID(id: "muro-live-wallpapers"),
        items: items,
        localizedName: "Muro — Live Wallpapers",
        disposability: .none,
        sortOrder: -90,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: nil,
        thumbnail: nil
    )
    let model = SettingsViewModels(
        desktop: SettingsViewModel(
            groups: [group],
            refreshPolicy: .default,
            isModificationDisabled: false
        ),
        screenSaver: nil
    )

    let shim = ShimViewModelsXPC(value: model)
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: shim,
        requiringSecureCoding: false
    ), let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass,
       let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    else {
        extensionLog("settings model remap prerequisites missing")
        return nil
    }

    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")
    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error { extensionLog("settings model remap failed: \(error)") }
    unarchiver.finishDecoding()
    extensionLog("built \(items.count) settings choice(s)")
    return result as AnyObject?
}
