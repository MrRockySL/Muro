// Runtime remapping technique derived from Phosphene (MIT),
// copyright 2026 kageroumado; see THIRD_PARTY_NOTICES.md.
import Foundation
import ObjectiveC

func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let runtimeClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let instance = class_createInstance(runtimeClass, 0)
    else {
        extensionLog("could not create WallpaperRemoteContextXPC")
        return nil
    }

    let offset = class_getInstanceVariable(runtimeClass, "box").map(ivar_getOffset) ?? 8
    let instanceSize = class_getInstanceSize(runtimeClass)
    guard offset >= 0,
          offset + MemoryLayout<UInt32>.size <= instanceSize
    else {
        extensionLog("unexpected WallpaperRemoteContextXPC layout")
        return nil
    }

    let object = instance as AnyObject
    Unmanaged.passUnretained(object).toOpaque()
        .advanced(by: offset)
        .storeBytes(of: contextId, as: UInt32.self)
    return object
}

func extractWallpaperUUID(from value: Any?) -> UUID? {
    guard let value else { return nil }
    return searchWallpaperUUID(value, depth: 0)
}

private func searchWallpaperUUID(_ value: Any, depth: Int) -> UUID? {
    guard depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
        if let uuid = searchWallpaperUUID(child.value, depth: depth + 1) { return uuid }
    }
    return nil
}
