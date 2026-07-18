import AppKit

// muro-engine: Phase 0 engine proof.
// Usage: muro-engine <path-to-video>
// Plays the video behind the desktop icons on the main screen, looping
// seamlessly, pausing whenever it is not visible (fullscreen apps, screen
// lock, display sleep).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
