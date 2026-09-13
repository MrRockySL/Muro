## Why

Playlists and automations only ever drive the desktop engine. When one is running, the macOS lock screen stays frozen on whatever wallpaper was last applied by hand (upstream issue [#26](https://github.com/MrRockySL/Muro/issues/26)). The obvious fix — call `LockScreenService.apply()` on every rotation step — is unshippable: it copies the video, rewrites both wallpaper plists twice, restarts `WallpaperAgent`, and flashes the whole screen. The maintainer agreed on the lighter path: the store keeps **one fixed wallpaper id** and rotation **swaps the file behind that id**, driven by the app's existing timer — no plist rewrites, no agent restarts, no flash, no second clock.

This change is rebased on **upstream v4.0.3** (`1aa1603`), which reworked the exact surfaces #26 touches: the lock-screen selection is now per-connected-display (`LockScreenSelections.afterApply`), the screen saver ships as its own surface (upstream #18), and `DesktopTintService` was rewritten as `DesktopStillService`. The mechanism below still holds on v4.0.3; the artifacts are updated to its names and shapes.

## What Changes

- Playlists and automations gain a **surface selector** (`desktop`, `lockscreen`, `all`), chosen in their editors and stored in `playlists.json` / `automations.json`. **Everything defaults to `desktop`** — new schedules and legacy ones alike — so a schedule never takes over the lock screen unless the user opts that in. For a schedule, **`all` means Desktop + Lock Screen only**; the screen saver is never in a playlist/automation fan-out (upstream #18 ships a static screen-saver surface and #26 deliberately leaves it alone). This needs `ApplySurface` (today a non-`Codable` `String, CaseIterable` enum in `MuroApp/Store.swift`) moved into `MuroKit` and made `Codable` first — keeping all four cases and their raw values (`"All"` / `"Desktop"` / `"Lockscreen"` / `"Screensaver"`) untouched.
- When a schedule whose surface includes the lock screen starts, `LockScreenService` performs **one normal apply** (`surface: .desktop`, the Apple role the lock screen renders) whose store selection is a **fixed id** — the schedule's own UUID — constant for the life of the schedule, and stages exactly **one video** behind it. The id is written through `LockScreenSelections.afterApply` with `targetKey == "all"`, so it collapses the per-display record to `["all": rotationID]` and every display reads it.
- Each `AutomationScheduler` tick of such a schedule **replaces the file behind that id** (atomic swap in the extension container) and posts the existing `com.mrrockysl.muro.wallpaper.library-changed` notification. The desktop and lock-screen halves move on the same tick, so they cannot drift.
- Staging prefers a **hard link** from the library into the container (same volume, zero extra disk, near-zero cost); a spike verifies the extension plays through one, falling back to a single-video copy if it does not.
- The **extension grows a `library-changed` observer** — it has none today; the app posts the signal on the Darwin notify center (`CFNotificationCenterGetDarwinNotifyCenter()`) but nothing in the extension listens — registered the same way `ExtensionPreferences` already listens for `preferences-changed` on that same center. On signal it re-resolves the staged path and **rebuilds the renderer on the live `CAContext`** (keeping the context/root layer avoids a re-`acquire` and the flash). This is the only new piece of extension code, and it lands in `ExtensionPreferences.swift` (an existing file — no `project.pbxproj` edit). The extension owns no timer and no rotation logic.
- One catch-up hook, still no second clock: the app also **reconciles the staged file to the current step on `com.apple.screenIsLocked` and on wake**, so a tick missed while napped or asleep doesn't leave a stale video on the lock screen.
- Stopping a schedule, deleting its last wallpaper, or moving the surface back to `desktop` restores the lock screen through the existing `LockScreenService.remove()` path.
- Desktop rotation is untouched — it stays on the engine path. `DesktopStillService` already skips a display whose slot `LockScreenService` owns, so the rotation id sitting in the selection record keeps the still writer off that surface for free.

## Capabilities

### New Capabilities
- `lockscreen-rotation`: how a running playlist or automation can keep the macOS lock screen in step with the desktop, and the low-cost mechanism (fixed id + file swap behind it + the app's single timer + extension-side renderer rebuild on `library-changed`) that does it without restarting `WallpaperAgent` per step.

### Modified Capabilities
<!-- No existing specs in this repo; nothing to modify. -->

## Impact

- **App (`MuroApp`)**: `ApplySurface` moved out to `MuroKit`; `AutomationScheduler` (`apply` callback gains surface + target), `AppStore` (`scheduler.apply` wiring at `Store.swift` ~317-321, `startPlaylist` / `startAutomation` / stop paths, lock/wake reconcile observers), the playlist editor (`PlaylistEditorView` in `LibraryView.swift`, added in v4.0.3) and `AutomationEditorView`.
- **Kit (`MuroKit`)**: `ApplySurface` (relocated here + made `Codable`, four cases kept; add a `scheduleCases` subset `[.desktop, .lockscreen, .all]` for the schedule pickers), `Playlist` and `Automation` models (new `surface` field as an optional backing value with a computed `.desktop` default, matching `Automation.Step`'s `seconds` → `duration`).
- **Service (`MuroApp/LockScreenService.swift`)**: fixed-id apply once (`beginRotation`), single-video staged swap (`stageRotationStep`), teardown, rotation-liveness bookkeeping so `purgeDeadMuroSurfaces` / `healIfNeeded` treat the id as alive while its schedule runs.
- **Extension (`MuroWallpaperExtension`)**: `library-changed` observer on the Darwin notify center in `ExtensionPreferences.swift`, renderer rebuild on the live `CAContext` (`RendererState` + a fresh `VideoRenderer` reusing the existing `context` / `rootLayer`). The rotation id is the schedule's own uuid, so `acquire` / `snapshot` / `SettingsProvider` / settings view models need **no** change. **No new timers, no new files.**
- **On-disk**: `playlists.json` / `automations.json` schema (additive); the container holds one rotation video while a lock-screen schedule runs (a hard link or one copy), removed on stop.
- **No new dependencies.** Deployment stays macOS 26+ for the lock-screen surface; below that the surface picker is hidden exactly as the single-apply UI already is (`store.lockScreenAvailable`).
