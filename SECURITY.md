# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 2.0.x   | Yes |
| < 2.0   | Please update |

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

- Cloudflare R2 for the wallpaper catalog, thumbnails, previews, and wallpaper
  downloads
- GitHub's Releases API to check for a newer Muro version

The catalog URL can be changed through macOS preferences. A custom catalog can
therefore provide wallpaper URLs on different hosts.

The catalog is checked when Muro launches and when it returns to the foreground.
The update check runs at launch and when you press **Check for Updates**.
Visible catalog thumbnails load automatically. An available preview downloads
for an undownloaded item the first time you open it or after its cached copy has
been removed. The full video downloads only when you choose **Preview** or
**Download**. Muro does not install updates. When one is available, its
**Download** button opens the GitHub release page.

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

The extension log records technical lifecycle events such as process IDs,
wallpaper and display identifiers, requested dimensions, and errors. It does not
contain video contents and is not uploaded. The current log is append-only and
has no automatic rotation or size limit.

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
git checkout v2.0
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
