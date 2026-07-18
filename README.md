<div align="center">

<img src="assets/icon.png" width="120" alt="Muro">

# Muro

### Live wallpapers for your Mac — without the battery bill. For free.

![macOS](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![License](https://img.shields.io/badge/License-MIT-green)
![Price](https://img.shields.io/badge/Price-Free-brightgreen)
[![Download](https://img.shields.io/badge/⬇_Download-Muro-A9C4FF)](../../releases/latest)

</div>

---

## The problem

A still desktop picture is a waste of a beautiful screen. But every live
wallpaper app that fixes it seems to come with a catch: a **subscription**, a
**Pro tier** that locks the good wallpapers behind a paywall, or — worst of all
— a fan that spins up the moment you set one.

Most of them are Electron apps wrapping a web page. They idle at 300–400 MB of
RAM and keep your CPU warm all day, for a picture that moves.

## The solution

**Muro** is a native macOS app that plays looping video wallpapers across every
display, browsed through a full-screen gallery. It's written in Swift and
SwiftUI, decodes video on the Apple Silicon media engine instead of the CPU, and
**pauses itself the moment you can't see it**.

**Everything is free.** There's no Pro tier, no paywall, no license key, and no
account. Every wallpaper and every feature is unlocked.

---

## Features

- 🌙 **Live video wallpapers** — looping, seamless, on every display at once.
- 🪶 **~2% CPU while playing** — HEVC decoded in hardware, never on the CPU.
- 😴 **Pauses itself** — on full-screen apps, display sleep, screen lock, Low Power Mode and low battery. A paused wallpaper costs **0% CPU**.
- ⚡ **Smooth or Efficient** — keep a wallpaper's original frame rate, or drop it to 30 fps to halve the power draw. Your choice, per wallpaper.
- 🖼️ **Explore gallery** — browse the catalog, preview full-screen, download only what you want.
- 🔄 **New wallpapers arrive on their own** — the library updates without updating the app. See below.
- 📃 **Playlists** — rotate through a set on a timer, shuffled or in order.
- 📥 **Import your own** — drop in any video; it's transcoded once to HEVC and added to your library.
- 🎛️ **Menu bar controls** — play, pause, skip and switch wallpapers without opening the app.
- 💾 **Space control** — see what each wallpaper costs on disk and remove downloads you're done with.
- 🆓 **Free & open source** (MIT).

> Requires **macOS 26 or newer** on **Apple Silicon** — it's built on SwiftUI's
> native liquid glass and the Apple Silicon media engine.

---

## What it looks like

<p align="center">
  <img src="screenshots/home.png" width="820" alt="Muro — the Home gallery with a featured wallpaper and picks from your library">
</p>

---

## Install

1. Download the latest **`Muro-1.0.dmg`** from the [Releases](../../releases/latest) page.
2. Open the DMG and drag **Muro** into your **Applications** folder.
3. **Allow it through macOS security.** Because the app is free and self-signed
   (not a paid, Apple-notarized certificate), macOS blocks the first launch with a
   *"can't be opened… Apple could not verify it is free of malware"* warning. To
   let it run:
   - Double-click the app once, then close the warning.
   - Open **System Settings → Privacy & Security**, scroll down to the message
     about **Muro**, and click **Open Anyway**, then **Open** to confirm.
   - *(On older macOS you can instead right-click the app → **Open** → **Open**.)*
4. Open **Explore**, pick a wallpaper, and hit **Apply**. That's it.

> Muro keeps running in your menu bar after you close the window — that's what
> keeps your wallpaper playing. Use the menu bar icon to control it, or **Quit**
> to stop.

---

## New wallpapers arrive on their own

You never have to update the app to get new wallpapers.

The library lives in its own repo,
**[Muro-Wallpapers](https://github.com/MrRockySL/Muro-Wallpapers)** — a
`catalog.json` index plus the videos as release assets. Muro re-reads that
catalog every time it launches or comes to the front, so when new wallpapers are
published there they appear in the **Explore** tab of **every install that
already exists**, whether it was downloaded today or six months ago.

Videos download only when you pick one, and can be removed again from the
Library tab whenever you want the space back.

> Give it up to ~5 minutes after a new batch is published — GitHub's CDN caches
> the catalog for a few minutes before it reaches everyone.

---

## Build from source

```bash
git clone https://github.com/MrRockySL/Muro.git
cd Muro/Muro
./build-app.sh --install     # builds, bundles, signs, installs to /Applications
```

`./build-app.sh --dmg` also produces `dist/Muro-<version>.dmg`.

The package builds five products: **MuroKit** (the shared engine and library
code), **muro-app** (the app itself), and the `muro-engine`, `muro-import` and
`muro-set` command line tools, which share the same config and library files as
the app.

---

## How it works

Muro is built on **AVFoundation** and **AppKit** — no Electron, no web views, no
private APIs.

- **The wallpaper window** is a borderless, click-through, non-activating
  `NSWindow` sitting just below the desktop icons, joined to every Space and
  hidden from Mission Control. Your desktop behaves exactly as it did before.
- **Playback** uses `AVQueuePlayer` with `AVPlayerLooper`, so loops are seamless
  and never seek. Videos are transcoded once to **HEVC** at import and decoded by
  the Apple Silicon media engine — the CPU barely participates.
- **Pausing** is the real trick. Muro watches window occlusion, display sleep,
  screen lock, Low Power Mode and battery level, and stops the player whenever
  the wallpaper can't be seen. A paused player is genuinely 0% CPU.
- **Frame rate, not resolution, drives power.** 4K at 30 fps costs roughly half
  what 4K at 60 fps does, while resolution barely moves the needle — which is why
  the Smooth/Efficient switch exists instead of a resolution setting.

---

## Roadmap

Planned for a future update:

- 🔒 **Lock screen live wallpapers** — the same video playing behind your login
  and lock screen, not just the desktop.

---

## Contributing

This is an open project and contributions are very welcome. Found a bug, have a
feature idea, or want to improve something? **[Open an issue](../../issues)** or
send a **pull request** — let's make it better together.

---

## Credits

Wallpaper videos by **[Wallspace](https://wallspace.app)**

---

## License

[MIT](LICENSE) — free to use, change, and share.

The wallpaper videos are not covered by that license; they belong to their
creators.

Made by **[MrRockySL](https://github.com/MrRockySL)**.
