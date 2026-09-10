import AppKit

/// Stable identifier for a display, used as the key in EngineConfig.
/// Display UUIDs survive reboots and re-plugs, unlike CGDirectDisplayID.
public func displayUUID(for screen: NSScreen) -> String? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    let displayID = CGDirectDisplayID(number.uint32Value)
    guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, uuidRef) as String
}

/// Whether this screen is the Mac's own built-in panel, or `nil` when the
/// screen cannot be identified at all.
///
/// The UI used to infer this from which display was the *main* one, which is
/// only the same thing until somebody makes an external monitor their primary
/// display. Then the laptop icon and the word Main land on the monitor, and
/// the Mac's own screen gets called External, which it never is.
public func displayIsBuiltIn(_ screen: NSScreen) -> Bool? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
}

/// The `CGDirectDisplayID` macOS puts in a wallpaper extension's acquire
/// request, so the app can name a staged file the extension will look for.
///
/// The UUID is the stable identity and is what everything else keys on. This
/// number is not stable across reboots or replugs, which is exactly why it is
/// used for nothing but the filename of a picture that is restaged whenever
/// the displays change.
public func directDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else { return nil }
    return CGDirectDisplayID(number.uint32Value)
}
