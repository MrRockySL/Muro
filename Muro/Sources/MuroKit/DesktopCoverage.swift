import CoreGraphics
import Foundation

/// Issue #22. Which screens have an app window open on them, worked out from
/// the window list macOS keeps for every process. Only positions and layers
/// are read, never a window's name or what is in it.
public enum DesktopCoverage {
    /// One on-screen window, reduced to what the rule reads.
    public struct Window: Equatable {
        public var layer: Int
        public var bounds: CGRect
        public var alpha: Double

        public init(layer: Int, bounds: CGRect, alpha: Double) {
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
        }
    }

    /// In points. A window smaller than this on either side is not something
    /// anyone reads as covering a desktop. Helper windows some apps keep on
    /// screen are 1 × 1.
    public static let minimumSide: CGFloat = 40

    /// Clicking the wallpaper to reveal the desktop does not hide any window.
    /// It slides each one almost off the screen and leaves a strip of it
    /// showing at an edge, and the window list reports exactly that. Measured
    /// on a real Mac on 2026-09-11: strips 13 to 45 points deep, none holding
    /// even 7% of its window. So a window covers a screen only when a real
    /// part of it is there: a quarter of the window, or a piece at least
    /// `minimumPiece` points on both sides. The second rule keeps a very large
    /// window counting on a screen that shows only a fraction of it.
    public static let minimumShare: CGFloat = 0.25
    public static let minimumPiece: CGFloat = 200

    /// Ordinary app windows only. They all sit on layer 0, while the
    /// wallpaper (Muro's own included), desktop widgets, the Dock, the menu
    /// bar and floating overlays all sit on other layers. Muro's gallery and
    /// Settings are app windows, so they count like any other.
    public static func counts(_ window: Window) -> Bool {
        window.layer == 0
            && window.alpha > 0
            && window.bounds.width >= minimumSide
            && window.bounds.height >= minimumSide
    }

    /// Whether enough of a window is on one screen to cover that desktop.
    public static func covers(_ window: Window, screen frame: CGRect) -> Bool {
        let overlap = frame.intersection(window.bounds)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0,
              window.bounds.width > 0, window.bounds.height > 0
        else { return false }
        let share = (overlap.width * overlap.height) / (window.bounds.width * window.bounds.height)
        return share >= minimumShare
            || (overlap.width >= minimumPiece && overlap.height >= minimumPiece)
    }

    /// Every screen with at least one counting window on it. A window across
    /// two screens covers both.
    public static func coveredScreens<Key: Hashable>(
        windows: [Window], screens: [Key: CGRect]
    ) -> Set<Key> {
        var covered = Set<Key>()
        for window in windows where counts(window) {
            for (key, frame) in screens where covers(window, screen: frame) {
                covered.insert(key)
            }
        }
        return covered
    }

    /// What to hand on after a look, given what was handed on last time.
    ///
    /// A screen that has just gone clear is still reported covered until a
    /// second look agrees, so a window caught mid-animation or halfway between
    /// Spaces cannot start a wallpaper for a moment, or restart Pause After.
    /// A screen that has just been covered is reported at once: freezing a
    /// tenth of a second late would cost nothing, but playing by mistake does.
    public static func settle<Key: Hashable>(
        previous: Set<Key>?, current: Set<Key>, confirming: Bool
    ) -> (report: Set<Key>, needsConfirmation: Bool) {
        guard let previous, !confirming else { return (current, false) }
        let cleared = previous.subtracting(current)
        return cleared.isEmpty ? (current, false) : (current.union(cleared), true)
    }

    /// The live window list, in the same global coordinates as
    /// `CGDisplayBounds`, with the origin at the top left of the main display.
    /// Minimised and hidden windows, and windows on other Spaces, are not on
    /// screen and are not returned.
    public static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Window(layer: layer, bounds: bounds, alpha: alpha)
        }
    }
}
