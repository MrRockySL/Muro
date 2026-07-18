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
