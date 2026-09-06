/// Issue #20: the app menu has no Settings item.
/// Holds the app-menu Settings item. The type lives in MuroKit so a test can read the values.
public enum AppMenuSettings {
    /// This value is the menu name. The ellipsis shows that the item opens a window.
    public static let title = "Settings…"

    /// This value is the key for the Command shortcut. macOS uses the comma key for Settings.
    public static let shortcut: Character = ","

    /// This value is the id of the existing Settings window. A different id opens a second window.
    public static let windowID = "settings"

    /// The function makes the app active. Then it opens the Settings window.
    /// The sequence is necessary. An inactive app opens the window behind other apps.
    public static func present(activate: () -> Void, open: (() -> Void)?) {
        activate()
        open?()
    }
}
