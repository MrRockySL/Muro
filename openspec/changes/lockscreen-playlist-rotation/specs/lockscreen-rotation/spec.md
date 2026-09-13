## Purpose

Defines how a running playlist or automation can keep the macOS lock screen showing the same wallpaper as the desktop, without paying the cost of a full lock-screen apply (video copy, plist rewrites, `WallpaperAgent` restart, screen flash) on every rotation step.

## ADDED Requirements

### Requirement: Schedules carry a target surface

A playlist and an automation SHALL each record a target surface: `desktop`, `lockscreen`, or `all`. For a schedule, `all` SHALL mean the desktop and the lock screen only; a schedule SHALL NOT target the screen saver. The surface SHALL be editable in the playlist editor and the automation editor. A schedule stored before this capability existed SHALL load as `desktop`.

When the running Mac cannot host a live lock screen (macOS below 26, or the lock-screen extension is unavailable), the surface control SHALL be hidden and every schedule SHALL behave as `desktop` regardless of its stored value.

#### Scenario: Legacy schedule keeps its behaviour

- **WHEN** a playlist saved by an older build (no surface field) is loaded and started
- **THEN** it rotates the desktop only and does not touch the lock screen

#### Scenario: Author targets the lock screen

- **WHEN** the user sets a playlist's surface to `all` or `lockscreen` and starts it
- **THEN** the lock screen shows the same wallpaper as the desktop, in the same order and interval

#### Scenario: A schedule never drives the screen saver

- **WHEN** a playlist's surface is `all` and it is running
- **THEN** the screen saver keeps whatever wallpaper it had and no rotation writes the Apple screen-saver role

#### Scenario: Surface control hidden without lock-screen support

- **WHEN** the app runs on macOS 15
- **THEN** the playlist and automation editors show no surface control and schedules rotate the desktop only

### Requirement: The lock screen is driven by a single fixed store selection

When a schedule whose surface includes the lock screen starts, the app SHALL write the Apple wallpaper store **once**, with a **fixed wallpaper id** that stays constant for the life of the schedule, recorded as the selection for every display. Every rotation step SHALL swap the staged video behind that id instead of rewriting the store, restarting `WallpaperAgent`, or causing a visible flash.

The full lock-screen apply path (store writes, agent restart) SHALL still be used for starting, stopping, and single (non-rotating) applies.

#### Scenario: Steady-state rotation touches no system state

- **WHEN** an `all` playlist runs for an hour with a 5-minute interval
- **THEN** `WallpaperAgent` is not restarted by any of the rotation steps and the wallpaper store is not rewritten by them

#### Scenario: Starting the schedule still registers normally

- **WHEN** an `all` playlist is started
- **THEN** the extension is registered and the wallpaper store is written once, exactly as a single lock-screen apply does today

### Requirement: The lock screen advances only while locked

The lock screen SHALL advance its rotation only while the screen is locked. While the screen is unlocked, no lock-screen rotation timer SHALL run and no video decoding for the lock-screen surface SHALL occur. On the next lock, the lock screen SHALL show the step that the schedule's elapsed running time implies, not merely the step after the last one shown.

#### Scenario: No work while unlocked

- **WHEN** an `all` playlist is running and the Mac stays unlocked
- **THEN** the lock-screen surface stays paused on a still frame and runs no rotation timer

#### Scenario: Catch-up on lock

- **WHEN** the Mac is locked after being unlocked for a span covering three rotation intervals
- **THEN** the lock screen shows the step the schedule would be on now, not the step immediately following the one shown before unlock

### Requirement: The staged video behind the rotation id always matches the current step

When a schedule whose surface includes the lock screen starts, and at every rotation step, the app SHALL stage the current step's video behind the fixed rotation id (preferring a hard link over a copy). The extension container SHALL hold one rotation video at a time, not the whole playlist. A step whose video cannot be staged SHALL leave the previous video in place rather than showing a blank lock screen, and the failure SHALL be recorded in diagnostics.

#### Scenario: Large playlist keeps one video staged

- **WHEN** a 40-wallpaper `all` playlist runs
- **THEN** the container holds the single current rotation video, replaced at each step, with no staging window or manifest

#### Scenario: Missing staged video does not blank the screen

- **WHEN** the rotation reaches a step whose video failed to stage
- **THEN** the lock screen keeps showing the previous wallpaper and the failure is recorded in diagnostics

### Requirement: The extension swaps the rendered video on a library-changed signal

The extension SHALL observe the `com.mrrockysl.muro.wallpaper.library-changed` Darwin notification. On that signal, while the screen is locked, the extension SHALL re-resolve the staged path for the current selection and, if it differs from the video being rendered, rebuild its renderer on the live rendering context without a re-`acquire` or a visible flash. If the new video cannot be opened, the extension SHALL keep the current renderer and log the failure.

#### Scenario: Swap without a flash

- **WHEN** the app stages a new step's video behind the rotation id and posts `library-changed` while the Mac is locked
- **THEN** the lock screen crossfades or cuts to the new video with no black frame and no re-registration

#### Scenario: Unrelated library-changed is a no-op

- **WHEN** `library-changed` is posted by staged-library pruning and the rotation video has not changed
- **THEN** the extension does not rebuild its renderer

### Requirement: Stopping or emptying a schedule restores the lock screen

When a schedule whose surface includes the lock screen is stopped, or loses its last wallpaper to a deletion, or has its surface edited back to `desktop` while running, the lock screen SHALL be restored to the wallpaper the user had before the schedule took it, through the same restore path a single lock-screen removal uses. The staged rotation video and the rotation-owned selection SHALL be cleaned up.

#### Scenario: Stop restores the previous wallpaper

- **WHEN** the user stops a running `all` playlist
- **THEN** the lock screen returns to the wallpaper set before the playlist started and the staged rotation videos are removed

#### Scenario: Deleting the last wallpaper stops the rotation cleanly

- **WHEN** the last wallpaper is deleted out of a running `all` playlist
- **THEN** the rotation stops, the lock screen is restored, and no rotation-owned selection is left behind

### Requirement: Previews and diagnostics understand a rotating selection

The lock-screen "applied" state for a wallpaper that is the current step of a running rotation SHALL read as applied for that surface. Diagnostics SHALL record rotation applies distinctly from single applies, including which schedule is driving the lock screen and its current step.

#### Scenario: Current step shows as applied

- **WHEN** an `all` playlist is on step 2 of 4
- **THEN** the library shows wallpaper 2 as applied on the lock screen and not wallpapers 1, 3, or 4

#### Scenario: Diagnostics name the driving schedule

- **WHEN** the lock screen is being driven by a rotation
- **THEN** the diagnostics log identifies the schedule and the current step rather than only a single wallpaper id
