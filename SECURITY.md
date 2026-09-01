# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 4.0.x   | Yes |
| < 4.0   | Please update |

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
as root.

The main app is signed with no entitlements and is not sandboxed. The embedded
wallpaper extension's only declared entitlement is the App Sandbox entitlement.
The main app uses normal user-level access to:

- Show wallpaper windows on connected displays
- Read videos that you explicitly choose to import
- Store downloaded wallpapers, imported videos, preferences, and playlists
- Observe display sleep, screen lock, its wallpaper windows' visibility, and
  power state
- Register Muro as a login item only when you enable **Launch at Login**

Imported videos stay on your Mac and are not uploaded.

While Muro's menu-bar panel is open, it temporarily observes global left-click
and right-click events so it can close the panel when you click elsewhere. It
handles the Escape key locally. It does not record or upload those events.

### Desktop picture on macOS 14 and 15

On macOS 15 and earlier the menu bar takes its colour from the desktop picture.
Muro does not use the desktop picture: it plays video in its own window seated
under the desktop icons, which macOS knows nothing about, so the menu bar was
being tinted by whatever still image you had set before installing Muro while a
different video played underneath it.

On those versions only, Muro sets your desktop picture to a still frame of the
wallpaper it is playing, per display, so the menu bar samples the right image.
The frames live in `~/Library/Application Support/Muro/DesktopStills`.

**This does not run on macOS 26 or later**, where the menu bar is transparent
and there is nothing to correct.

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

This is disclosed because it is the one thing Muro does that changes state
outside its own data directories. The reason: a DMG downloaded through a
browser is quarantined, the flag is inherited by the embedded extension, and
macOS then refuses to load that extension, so lock-screen wallpapers silently
fail to apply. Muro is not sandboxed, so it can clear the flag on itself.

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

- Copies the selected video and thumbnail into the extension's local container
- Backs up and updates the user-level macOS wallpaper stores, `Index.plist` and
  `Index2.plist`
- Registers the extension with `pluginkit`
- Restarts Apple's `WallpaperAgent` so the change takes effect

Muro attempts to restore the previous wallpaper settings if applying fails and
when you remove its lock-screen wallpaper.

This feature depends on private macOS wallpaper interfaces, including
`WallpaperExtensionKit` and runtime-only wallpaper types. Apple can change these
interfaces without notice, so future macOS releases may require compatibility
fixes.

### Network access

With its default catalog, the current app makes unauthenticated HTTPS requests
to:

- `cdn.murowallpaper.com`, Muro's own domain in front of Cloudflare R2, for the
  wallpaper catalog, thumbnails, previews, and wallpaper downloads
- GitHub's Releases API to check for a newer Muro version

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

Cloudflare and GitHub receive normal connection information such as your IP
address. Muro has no account system, advertising, analytics, telemetry, or
third-party crash-reporting service. It sends no separate telemetry payload and
does not intentionally upload imported video contents, preferences, or
diagnostic logs.

### Data stored on your Mac

Muro stores local data in:

- `~/Library/Application Support/Muro` for downloaded and imported wallpapers,
  thumbnails, configuration, playlists, lock-screen state, and wallpaper-store
  backups
- `~/Library/Caches/Muro/Previews` for a preview cache capped at 200 MB
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
git checkout v4.0
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
- Muro trusts the URLs and metadata supplied by the default HTTPS catalog.
  The catalog and wallpaper assets have no separate cryptographic signatures,
  hashes, or host pinning.
- A failed lock-screen operation could temporarily change wallpaper settings,
  although Muro keeps backups and attempts rollback.
