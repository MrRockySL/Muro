# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 6.1.x   | Yes |
| < 6.1   | Please update |

Only the latest release receives security fixes. Updates are published on the
[Releases](https://github.com/MrRockySL/Muro/releases) page.

## Reporting a vulnerability

Please do not publish vulnerability details in a public issue.

Use GitHub's private reporting page:
[Report a vulnerability](https://github.com/MrRockySL/Muro/security/advisories/new)

If private reporting is unavailable, open a normal issue asking to be contacted
privately, without including details of the vulnerability.

Muro is maintained by one person. The target is an initial reply within 7 days
and a fix, mitigation, or clear response within 30 days for a confirmed issue.
Credit will be given in the release notes unless you prefer otherwise.

## What Muro can and cannot do

Muro is a native macOS live-wallpaper app. This section documents the access it
uses so that you can make an informed decision before installing it.

### Permissions and system access

The current app does not request microphone, camera, Screen Recording,
Accessibility, Full Disk Access, or administrator permission. It does not run
as root. The one permission it can ask for is System Audio Recording, and only
when you show an interactive wallpaper that moves with sound (see
**Interactive wallpapers** below).

The main app is signed with no entitlements and is not sandboxed. The embedded
wallpaper extension's only declared entitlement is the App Sandbox entitlement.
The main app uses normal user-level access to:

- Show wallpaper windows on connected displays
- Read videos that you explicitly choose to import
- Store downloaded wallpapers, imported videos, preferences, and playlists
- Observe display sleep, screen lock, its wallpaper windows' visibility, and
  power state
- Register Muro as a login item only when you enable **Launch at Login**
- Set your Mac's screen saver, and how long it waits, when you ask it to
- Copy screen savers you import into `~/Library/Screen Savers`, and move ones you
  delete from there to the Trash
- Keep your downloaded wallpapers in a folder you choose, when you set
  **Download Folder**
- Set Apple's still pictures, its drawn wallpapers and your own screen savers
  through macOS's wallpaper store, when you pick one
- Read the position, size, layer and opacity of on-screen windows, never their
  names or contents, and only while **Play only on desktop** or **Replay on
  Clear Desktop** is on, or an interactive wallpaper is shown
- Run an interactive wallpaper's page, tell it where the pointer is, and tell
  it how loud the Mac's sound is, only while an interactive wallpaper is shown
- Answer `muro://` links from other apps, which can switch to a live wallpaper
  already in your Library and pause or resume (see **Links from other apps**
  below)

Imported videos stay on your Mac and are not uploaded.

While Muro's menu-bar panel is open, it temporarily observes global left-click
and right-click events so it can close the panel when you click elsewhere. It
handles the Escape key locally. It does not record or upload those events.

### Windows on your screen

Since 5.0, **Play only on desktop** and **Replay on Clear Desktop** need to know
whether a window is open on each screen. While either is on, Muro asks macOS for
the window list about twice a second, and again straight after a click, an app
switch, a hide, a launch, a quit or a Space change. It reads each window's
position, size, layer and opacity, which macOS gives any app without a
permission prompt, and it never reads window titles or contents. Muro has no
Screen Recording permission, so macOS does not hand it titles at all.

For the same reason, Muro observes global mouse-up events while either switch is
on: a click is the earliest sign that a window is about to open, close or
minimise. Only the fact that a click happened is used, never where it landed or
on what, and key events are never observed. Nothing here is stored or uploaded,
and with both switches off, which is the default, none of it runs.

### Desktop picture

Muro plays video in its own window seated under the desktop icons, which macOS
knows nothing about. So the desktop picture underneath stayed whatever it had
been, and quitting Muro left you looking at a picture you replaced weeks ago,
or at nothing at all.

Muro sets your desktop picture to a still frame of the wallpaper it is playing,
per display, and keeps it in step with every playlist and automation step. The
frames live in `~/Library/Application Support/Muro/DesktopStills`.

This started on macOS 15 and earlier, where the menu bar takes its colour from
the desktop picture and was sampling the wrong image. It runs on every version
now, because a Mac with no picture behind the video has a black desktop the
moment Muro is not running.

Your own desktop picture is read and recorded in
`~/Library/Application Support/Muro/desktop-tint.json` before anything is
written, and put back when the wallpaper is removed. Muro restores only its own
change: if you pick a new picture yourself in System Settings, that is your
choice and Muro leaves it alone. It also skips any display whose wallpaper is
being driven by Muro's lock-screen extension.

This is disclosed because the desktop picture is state outside Muro's own data
directories.

### Quarantine removal on Muro's own bundle

Since 3.0, Muro removes the `com.apple.quarantine` extended attribute from its
own application bundle and the wallpaper extension inside it. It does this at
launch, and again before registering the extension, and only when the attribute
is actually present.

This is disclosed because it changes state outside Muro's own data directories.
The reason: a DMG downloaded through a browser is quarantined, the flag is
inherited by the embedded extension, and macOS then refuses to load that
extension, so lock-screen wallpapers silently fail to apply. Muro is not
sandboxed, so it can clear the flag on itself.

The scope is deliberately narrow. Muro only ever touches paths inside its own
bundle, only that one attribute, and it removes rather than adds. It does not
alter Gatekeeper settings, system policy, or any other application. Removing
the attribute does not bypass the first-launch approval you already gave; it
only stops macOS treating the already-approved bundle's inner components as
untrusted downloads.

If macOS is running Muro from a translocated read-only copy (Gatekeeper path
randomisation, which happens when an app is opened from inside a DMG rather
than from Applications), Muro detects that, changes nothing, and tells you to
move it to Applications.

### Lock-screen integration

On macOS 26 or newer, Muro can register its bundled, sandboxed wallpaper
extension. When you apply a lock-screen wallpaper, the main app:

- Copies the selected video and thumbnail into the extension's local container.
  A playlist or automation hard links each step's video there instead, so a
  step takes no extra disk space; a wallpaper kept on another drive is copied
- Backs up and updates the user-level macOS wallpaper stores, `Index.plist` and
  `Index2.plist`
- Registers the extension with `pluginkit`
- Restarts Apple's `WallpaperAgent` so the change takes effect

Muro attempts to restore the previous wallpaper settings if applying fails and
when you remove its lock-screen wallpaper.

Since 6.0, Muro also handles Macs set to **Use Screen Saver: Automatic** in
System Settings, Wallpaper, Screen Saver, which is how a new Mac starts. There
macOS keeps one wallpaper for the desktop, the lock screen and the screen saver.
Before Muro sets one of those places on such a Mac, it switches it to **Custom**
in the same stores, keeping what is on screen, so each place keeps its own
wallpaper. Muro does not switch it back to Automatic.

A lock screen set from Muro leaves your own picture on the desktop. macOS keeps
one wallpaper per display for the desktop and the lock screen together, so Muro
stays in that place and shows your picture on the desktop itself. To do that it
reads the picture file macOS names as that display's desktop picture, wherever
you keep it, and keeps a screen-sized copy in
`~/Library/Application Support/Muro/OwnDesktop`, recorded in
`own-desktop.json`. The copy is handed to Muro's extension, which draws it on
the desktop, and it is deleted when the lock screen comes off. If the picture
is in Desktop, Documents, Downloads or on another drive, macOS may ask you
first whether Muro may read it. Only one still picture is read this way, never
a folder, and a picture of your own only for a display where Muro plays nothing
on the desktop.

If you then set another picture in System Settings or Finder on a display where
Muro is only the lock screen, Muro notices, copies the new picture the same
way, and writes its lock screen back into the wallpaper stores, restarting
`WallpaperAgent` once. The backup of those stores learns your newest picture,
so removing the lock screen gives that one back. Where Muro also plays on that
display's desktop, a picture you set in System Settings takes the lock screen
and Muro lets it go. This is disclosed because it reads a file of yours outside
Muro's own data directories and writes macOS's wallpaper stores again without a
click in Muro.

The extension also answers macOS when it asks what the lock wallpaper looks
like as a still picture. macOS keeps that picture on the Preboot volume and
draws it on the login screen, before anything of Muro's is running. The image
is a frame of the wallpaper you chose and nothing else; Muro hands it over and
macOS decides where it is stored. Answering was added because refusing left the
login screen showing a picture from whatever wallpaper had last been exported
successfully, which could be months old.

This feature depends on private macOS wallpaper interfaces, including
`WallpaperExtensionKit` and runtime-only wallpaper types. Apple can change these
interfaces without notice, so future macOS releases may require compatibility
fixes.

### Screen saver

Since 5.0, Muro can be your screen saver as well as your desktop and lock
screen. macOS keeps all three in the same user-level wallpaper stores, and it
files the screen saver under a role it calls `idle`, so applying one writes the
same `Index.plist` and `Index2.plist` described above and takes the same backups
first. The screen saver is one setting for the whole Mac rather than one per
display, because macOS has no per-display screen saver.

Muro checks at launch that it still holds the screen saver it recorded, and puts
it back if macOS has given it to something else. That check exists because
replacing **Muro.app** while Muro is running makes macOS drop the wallpaper
extension and hand the screen saver to Apple's aerials, and macOS does not hand
it back on its own.

Settings has a **Start Screen Saver** row that sets how long your Mac waits
before the screen saver begins. It writes the key `idleTime` in the
`com.apple.screensaver` preferences domain, for the current user and the current
host, which is the single place macOS keeps that setting and the same place
System Settings writes it. This is disclosed because that preference is state
outside Muro's own data directories. Muro writes only that one key, only when
you change that row, and it writes **Never** as `0`, which is how macOS itself
records it. No other key, domain, user or host is touched, and nothing is read
from or written to the preference unless you open Settings.

### Apple section

Since 6.0, the Apple section lists Apple's aerials, Dynamic Wallpapers and
screen savers. To build that list Muro reads Apple's own catalogues on your Mac,
in `/Library/Application Support/com.apple.idleassetsd/Customer`,
`/System/Library/Desktop Pictures`, `/System/Library/AssetsV2`,
`/System/Library/Wallpapers` and `/System/Library/ExtensionKit/Extensions`, and
the screen savers in `/Library/Screen Savers` and `~/Library/Screen Savers`. It
only reads these folders and never writes into them. An aerial macOS has already
downloaded is played from where it is.

Aerials and still pictures download from Apple's servers, at the addresses
those catalogues give, and only when you choose **Download**, **Preview** or
**Set Wallpaper**. Before that, an aerial's card picture is read from Apple's
server: the video's index and one frame, never the whole file. The card pictures
of still pictures, drawn wallpapers and screen savers come from
`cdn.murowallpaper.com`, and so do Apple's eight screen savers, which are Muro's
own 4K recordings.

Still pictures and drawn wallpapers can only be shown by macOS, so
**Set Wallpaper** writes them into the user-level wallpaper stores described
under Lock-screen integration, as the same record System Settings writes. Muro
keeps a list of what it set in
`~/Library/Application Support/Muro/macos-wallpapers.json`, so **Remove** can
give the place back. Downloaded aerials and still pictures are kept beside your
other wallpapers, so they follow **Download Folder**.

### Screen savers you import

Since 6.0, the Library's import bar takes `.saver` screen savers, such as
XScreenSaver. Muro copies the one you choose into `~/Library/Screen Savers`,
where macOS looks for screen savers, and leaves your original where it was.
Deleting one from the Library moves it to the Trash, as System Settings does.
Only screen savers in your own `~/Library/Screen Savers` can be deleted from
Muro.

A `.saver` is code written by someone else, and Muro never loads one into
itself. When an imported screen saver has no picture of its own, Muro runs it
for about 20 seconds in a separate helper process, `muro-saver-picture`, in a
hidden window off every screen, and keeps one frame as its card picture in
`~/Library/Caches/Muro/AppleAerials`. A screen saver that crashes or hangs takes
only the helper down. The helper is not sandboxed, and macOS runs the same code
whenever that screen saver is in use, so only import screen savers you trust.

### Interactive wallpapers

Since 6.1, a wallpaper can be an interactive wallpaper: a web page on the
desktop instead of a video. Muro comes with a few of its own, and the Library's
import bar takes yours, as an HTML page or a folder with one in it. Muro copies
what you choose into `Interactive` in its own library folder and leaves your
original where it was. None of this runs unless an interactive wallpaper is on
your desktop or open on its page in Muro: no web view is made and nothing is
listened to.

**The page.** An interactive wallpaper is shown by macOS's own web engine
(WebKit), in separate processes that macOS sandboxes. A page you import is code
written by someone else, so Muro keeps what it can reach small:

- It can read its own folder and nothing else on your Mac.
- Every request to the internet (`http`, `https`, `ws`, `wss`, `ftp`) is blocked
  before it leaves, and the page cannot go to another address. Muro's own
  interactive wallpapers ask the internet for nothing.
- It keeps nothing between runs: no cookies, no storage, no cache.
- It cannot open a window, show a dialog, or use the camera or the microphone.
- It never gets the keyboard, and it gets no real mouse events either: the
  wallpaper window lets every click through to your desktop.

**The pointer.** A wallpaper window cannot see the mouse, so while an
interactive wallpaper is shown, Muro observes global mouse-move events and
left clicks and tells the page where the pointer is on that display, but only
while the pointer is over the desktop itself. When it moves over an app window
the page is told only that the pointer has gone, and a click is passed on only
when it lands on the desktop. Muro checks this from the position and layer of
on-screen windows, never their names or contents. The page is told a position
between 0 and 1 and nothing about what is under it. Key events are never
observed. Nothing is stored or uploaded.

**The sound.** A page can ask to move with the sound your Mac is playing. The
first time one does, macOS asks whether Muro may record system audio, and
without your yes the page hears silence. With it, Muro taps the Mac's sound
output (a Core Audio process tap, macOS 14.2 or later), measures how loud 64
frequency bands are about forty times a second, and gives the page those 64
numbers. The sound itself is never kept, written to disk or sent anywhere, and
the page never receives it. Muro listens only while a page that asked for sound
is on screen and moving: it stops when the wallpaper is paused, covered, or
removed, when the Mac is locked or the display sleeps. You can take the
permission back in System Settings > Privacy & Security > Screen & System Audio
Recording.

A page still uses your Mac's processor, graphics chip and memory, more than a
video does, and a badly written one can use a lot. Only import interactive
wallpapers you trust.

### Links from other apps

Since 6.1, Muro registers the `muro://` link scheme, so a script, a Shortcut or
another app can change the live wallpaper without opening Muro. macOS lets any
app open such a link, and a web page can too, once you click **Open Muro** when
the browser asks. This is disclosed because something outside Muro can now
change what Muro shows, without a click in Muro. So a link is held to what is
safe from a page:

- There are three links and nothing else is answered. `muro://set` switches the
  desktop, the lock screen or the screen saver to a live wallpaper that is
  already in your Library, on a display that is connected. `muro://pause` and
  `muro://resume` do what the menu bar's pause does.
- A link never downloads, imports or deletes anything, and it changes no
  setting.
- A link cannot set what macOS shows itself: Apple's still pictures, drawn
  wallpapers and screen savers. Those are set in Muro only.
- A link never opens a window and never shows a message. Muro sends nothing
  back to whoever opened the link, so a link cannot be used to read what is in
  your Library or anything else on your Mac.
- Links are carried out one at a time, in the order they came. At most 16 wait
  and the rest are ignored, and a link longer than 1,024 characters is not read
  at all.

A link that sets the lock screen or the screen saver does the same work as
setting it in Muro, which is described under **Lock-screen integration**: the
video is copied to the extension, the wallpaper stores are written and
`WallpaperAgent` is restarted. Setting a live wallpaper from a link also stops
a playlist or automation playing in that place, as setting one by hand does.

A link that is ignored, or that could not be finished, is written to the
macOS log (subsystem `com.mrrockysl.muro`, category `links`) with the link's
own text and the reason. Nothing is uploaded.

To turn links off, run
`defaults write com.mrrockysl.muro linksOff -bool true`. Muro then ignores
every link. A link can still start Muro when it is not running, because macOS
opens the app before Muro sees the link.

### Download Folder

Since 6.0, Settings has a **Download Folder** row. If you choose a folder, Muro
moves your downloaded wallpapers into a folder called `Muro Wallpapers` inside
it, marks that folder with a small hidden `.muro-wallpapers` file so it is never
mistaken for someone else's, and puts a symbolic link to it in place of
`~/Library/Application Support/Muro/Masters`. **Default** moves them back.

This is disclosed because that folder is outside Muro's own data directories.
Uninstalling Muro does not remove it: delete `Muro Wallpapers` yourself if you
no longer want the videos.

### Network access

With its default catalog, the current app makes unauthenticated HTTPS requests
to:

- `cdn.murowallpaper.com`, Muro's own domain in front of Cloudflare R2, for the
  wallpaper catalog, thumbnails, previews, and wallpaper downloads, and since
  6.0 the Apple section's card pictures and its 4K screen saver recordings
- GitHub's Releases API to check for a newer Muro version
- Since 6.0, Apple's own servers, only for the Apple section: an aerial's index
  and one frame for its card, and the aerials and still pictures you choose to
  download

Before 4.0 those requests went to a shared `pub-<id>.r2.dev` address. That
hostname is common to every Cloudflare R2 bucket, so networks that block it
block all of them at once, and Explore arrived empty for the people behind such
a filter. The old address still answers, so copies of Muro older than 4.0 keep
working.

The catalog URL can be changed through macOS preferences. A custom catalog can
therefore provide wallpaper URLs on different hosts.

The catalog is checked when Muro launches and when it returns to the foreground.
The update check runs at launch, when Muro returns to the foreground and at
most once every six hours, and when you press **Check for Updates**. Since 3.0
it also reads the latest release's notes and asset list so **What's New** can
show what changed and offer the download.
Visible catalog thumbnails load automatically. An available preview downloads
for an undownloaded item the first time you open it or after its cached copy has
been removed. The full video downloads only when you choose **Preview** or
**Download**. Muro does not install updates. When one is available, its
**Download** button opens the disk image from that GitHub release in your
browser, or the release page if that release has no disk image. You install it
yourself.

Cloudflare, GitHub and, when you use the Apple section, Apple receive normal
connection information such as your IP address. Muro has no account system,
advertising, analytics, telemetry, or third-party crash-reporting service. It
sends no separate telemetry payload and does not intentionally upload imported
video contents, preferences, or diagnostic logs.

### Data stored on your Mac

Muro stores local data in:

- `~/Library/Application Support/Muro` for downloaded and imported wallpapers,
  thumbnails, configuration, playlists, lock-screen state, and wallpaper-store
  backups
- `~/Library/Caches/Muro/Previews` for a preview cache capped at 200 MB
- `~/Library/Caches/Muro/Thumbnails` for catalog thumbnails, kept so each loads
  only once
- `~/Library/Caches/Muro/AppleAerials` for the Apple section's card pictures and
  the details read about each aerial
- `~/Library/Caches/Muro/Share` for at most one hard link to the wallpaper you
  last shared, emptied at launch
- The folder you choose with **Download Folder**, if you choose one
- The `com.mrrockysl.muro` preferences domain for interface and catalog settings
- The wallpaper extension's container for staged lock-screen files and its
  local diagnostic log
- `~/Library/Application Support/Muro/lockscreen-diagnostics.log`, written on
  every lock-screen apply

The extension log records technical lifecycle events such as process IDs,
wallpaper and display identifiers, requested dimensions, and errors. Since 3.0
it is size-capped rather than growing without limit.

The lock-screen diagnostics log records the macOS version, the wallpaper and
target identifiers, whether the extension was registered, whether the wallpaper
stores kept the change, and whether macOS acknowledged it. It exists so a
failure report can be answered. Since 4.0 it is written on every apply rather
than only on a failure, because an apply that reported success and did nothing
used to leave no record at all. It is capped at 32 KB and, like the extension
log, contains no video contents and is never uploaded.

The extension also writes a small `acquire-receipt.json` inside its own
container, holding the identifier of the wallpaper macOS last asked it for, the
time, and whether a frame was drawn. Muro reads it to tell an apply that macOS
genuinely collected apart from one it only wrote down. It is a single record,
overwritten each time, and is never uploaded.

### Dependencies and release contents

The Swift package has no external package dependencies and otherwise uses Apple
system frameworks. Parts of the wallpaper extension are derived from the
MIT-licensed Phosphene project and are documented in
[`Muro/THIRD_PARTY_NOTICES.md`](Muro/THIRD_PARTY_NOTICES.md).

The source tree includes developer command-line tools for preparing and
publishing wallpapers. Those tools and the developer's Cloudflare credentials
are not included in the released **Muro.app**.

## Verifying or building Muro

You can inspect and compile the tagged source:

```bash
git clone https://github.com/MrRockySL/Muro.git
cd Muro
git checkout v6.1.1
swift build -c release --package-path Muro
```

You can verify the current app bundle's internal code seal:

```bash
codesign --verify --deep --strict --verbose=2 "/Applications/Muro.app"
```

Muro uses an ad-hoc signature. Anyone can modify and ad-hoc sign another copy,
so this check does not establish provenance or an Apple Developer ID identity.
Building the complete app and DMG also requires Xcode and the bundled wallpaper
assets expected by `Muro/build-app.sh`.

## Known security-relevant limitations

- Releases are ad-hoc signed and are not notarized by Apple.
- Hardened Runtime is not enabled.
- Release builds are created manually and are not reproduced through CI.
- The main app is not sandboxed.
- Lock-screen support depends on private macOS interfaces.
- The Apple section reads Apple's own catalogues and writes Apple's own
  wallpaper records, which Apple can change without notice.
- Imported `.saver` screen savers are third-party code: macOS runs them as your
  screen saver, and Muro's picture helper runs them briefly, without a sandbox.
- An imported interactive wallpaper is third-party code. It runs in macOS's web
  engine, held to its own folder and off the internet, but it is not reviewed
  by anyone.
- Any app, and any web page you let open Muro, can send `muro://` links. A link
  can only switch to a live wallpaper already in your Library, pause or resume,
  and links are on unless you turn them off.
- Muro trusts the URLs and metadata supplied by the default HTTPS catalog.
  The catalog and wallpaper assets have no separate cryptographic signatures,
  hashes, or host pinning.
- A failed lock-screen operation could temporarily change wallpaper settings,
  although Muro keeps backups and attempts rollback.
