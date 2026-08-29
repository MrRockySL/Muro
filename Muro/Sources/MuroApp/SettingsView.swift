import SwiftUI
import ServiceManagement
import MuroKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("defaultMode") private var defaultMode = "smooth"

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmClear = false
    @State private var customPauseAfter = false
    /// The window keeps this view alive across close/reopen, which used to
    /// preserve the scroll position — reopening must always show the header.
    @State private var scrollToTopOnNextOpen = false

    var body: some View {
        ZStack {
            // Full-bleed glass layer: fills the ENTIRE window including under
            // the transparent, separator-less titlebar (so the top bar is the
            // same glass, no seam). Content scrolls on top.
            VisualEffectBackground()
                .overlay(Color.black.opacity(0.22))
                .ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                    .id("settings-top")

                section("GENERAL") {
                    row(icon: "power", tint: .blue, title: "Launch at Login",
                        subtitle: "Muro starts quietly in the background") {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .tint(Color.muroAccent)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, enabled in
                                setLaunchAtLogin(enabled)
                                // Logging in with no menu bar icon would leave
                                // no way to reach the app — keep them together.
                                if enabled { showMenuBarIcon = true }
                            }
                    }
                    divider
                    row(icon: "menubar.rectangle", tint: .purple, title: "Show Menu Bar Icon",
                        subtitle: "Quick controls from the menu bar") {
                        Toggle("", isOn: $showMenuBarIcon)
                            .toggleStyle(.switch)
                            .tint(Color.muroAccent)
                            .labelsHidden()
                    }
                    divider
                    row(icon: "dock.rectangle", tint: .pink, title: "Show Dock Icon",
                        subtitle: "Turn off to run Muro as a menu bar app") {
                        Toggle("", isOn: $showDockIcon)
                            .toggleStyle(.switch)
                            .tint(Color.muroAccent)
                            .labelsHidden()
                            .onChange(of: showDockIcon) { _, on in
                                NSApp.setActivationPolicy(on ? .regular : .accessory)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                    }
                }

                section("PLAYBACK") {
                    row(icon: "speedometer", tint: .orange, title: "Playback Speed",
                        subtitle: "How fast wallpapers play") {
                        GlassDropdown(width: 120, align: .trailing, options: {
                            [0.5, 0.75, 1.0, 1.25, 1.5].map { speed in
                                MenuOption(
                                    title: speedLabel(speed),
                                    checked: abs(store.playbackSpeed - speed) < 0.01
                                ) { store.setPlaybackSpeed(speed) }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text(speedLabel(store.playbackSpeed))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .glassCapsule(fill: 0.09, stroke: 0.15)
                        }
                    }
                    divider
                    row(icon: "gauge.with.dots.needle.33percent", tint: .mint, title: "Default Quality",
                        subtitle: "Smooth keeps original fps · Efficient caps at 30 fps (~2% CPU)") {
                        CapsuleSegments(
                            options: [("Smooth", "smooth"), ("Efficient", "efficient")],
                            selection: $defaultMode
                        )
                    }
                    divider
                    row(icon: "pause.circle", tint: .indigo, title: "Pause After",
                        subtitle: pauseAfterSubtitle) {
                        GlassDropdown(width: 150, align: .trailing, options: {
                            SettingsView.pauseAfterChoices.map { seconds in
                                MenuOption(
                                    title: seconds == 0 ? "Off" : durationLabel(seconds),
                                    checked: store.pauseAfterSeconds == seconds
                                ) { store.setPauseAfter(seconds) }
                            } + [.divider, MenuOption(title: "Custom…") { customPauseAfter = true }]
                        }) {
                            HStack(spacing: 6) {
                                Text(store.pauseAfterSeconds == 0
                                     ? "Off" : durationLabel(store.pauseAfterSeconds))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .glassCapsule(fill: 0.09, stroke: 0.15)
                        }
                        .anchoredCard(isPresented: $customPauseAfter, width: 300, align: .trailing) {
                            CustomDurationPicker(seconds: Binding(
                                get: { max(10, store.pauseAfterSeconds) },
                                set: { store.setPauseAfter($0) }
                            )) { customPauseAfter = false }
                        }
                    }
                }

                section("ENERGY") {
                    row(icon: "battery.25percent", tint: .yellow, title: "Auto-pause in Low Power Mode",
                        subtitle: "Freeze wallpapers while saving energy") {
                        Toggle("", isOn: Binding(
                            get: { store.autoPauseLowPower },
                            set: { store.setAutoPauseLowPower($0) }
                        ))
                        .toggleStyle(.switch).tint(Color.muroAccent).labelsHidden()
                    }
                    divider
                    row(icon: "bolt.slash", tint: .red, title: "Auto-pause below 20% battery",
                        subtitle: "Resumes automatically on power") {
                        Toggle("", isOn: Binding(
                            get: { store.autoPauseBattery },
                            set: { store.setAutoPauseBattery($0) }
                        ))
                        .toggleStyle(.switch).tint(Color.muroAccent).labelsHidden()
                    }
                    divider
                    row(icon: "macwindow.on.rectangle", tint: .teal, title: "Auto-pause when covered",
                        subtitle: "Freeze a display's wallpaper while a full screen app or window hides it") {
                        Toggle("", isOn: Binding(
                            get: { store.autoPauseFullScreen },
                            set: { store.setAutoPauseFullScreen($0) }
                        ))
                        .toggleStyle(.switch).tint(Color.muroAccent).labelsHidden()
                    }
                }

                section("DISPLAYS") {
                    ForEach(Array(store.displays.enumerated()), id: \.element.id) { index, display in
                        if index > 0 { divider }
                        row(icon: display.symbolName,
                            tint: .cyan,
                            title: display.name,
                            subtitle: "\(display.kindLabel) display") {
                            Text("\(display.pixelsW) × \(display.pixelsH)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.muroSecondary)
                        }
                    }
                }

                section("STORAGE") {
                    row(icon: "internaldrive", tint: .gray, title: "Library & Cache",
                        subtitle: store.clearStatus ?? "Everything goes except the wallpaper in use") {
                        HStack(spacing: 10) {
                            Text(formatSize(store.libraryBytes))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.muroSecondary)
                            Button("Clear") { confirmClear = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5.5)
                                .glassCapsule(fill: 0.09, stroke: 0.15)
                        }
                    }
                    // An "Auto-clear memory: Manual / Daily / Weekly" row used
                    // to sit here. Nothing ever read it, and the RAM it claimed
                    // to free is not RAM Muro holds, so it was removed rather
                    // than given a fake implementation.
                }

                // The wallpaper catalog URL is baked in (AppStore
                // .defaultCatalogURL) and not shown here — a normal user never
                // needs to change it, and a bad value only breaks their own
                // Explore. Still overridable via `defaults write … catalogURL`
                // for the owner's own testing.

                section("ABOUT") {
                    row(icon: "arrow.down.circle", tint: .green,
                        title: "Software Update",
                        subtitle: updateSubtitle) {
                        updateControl
                    }
                    divider
                    row(icon: "heart.fill", tint: .pink,
                        title: "Support Muro",
                        subtitle: "Muro is free. Sponsoring keeps it that way.") {
                        sponsorControl
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.willCloseNotification
            )) { note in
                if (note.object as? NSWindow)?.title == "Muro Settings" {
                    scrollToTopOnNextOpen = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )) { note in
                guard scrollToTopOnNextOpen,
                      (note.object as? NSWindow)?.title == "Muro Settings" else { return }
                scrollToTopOnNextOpen = false
                proxy.scrollTo("settings-top", anchor: .top)
            }
            }
        }
        .frame(width: 560, height: 600)
        .menuHost()
        .background(SettingsWindowConfigurator())
        .alert("Clear the library?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearDownloadedCache() }
        } message: {
            Text(clearMessage)
        }
    }

    /// Issue #3: a fast wallpaper is distracting, so let it move for a while
    /// and then hold on a frame.
    static let pauseAfterChoices = [0, 10, 30, 60, 120, 300, 900, 3600]

    static func pauseAfterLabel(_ seconds: Int) -> String {
        seconds <= 0 ? "Off" : durationLabel(seconds)
    }

    private var pauseAfterSubtitle: String {
        store.pauseAfterSeconds == 0
            ? "Wallpapers keep playing until something else pauses them"
            : "Play for \(durationLabel(store.pauseAfterSeconds)) after every change or unlock, then hold on a frame"
    }

    /// Says what is about to happen in counts, and names the part that cannot
    /// be taken back. "Except applied or playlist items" told the user the
    /// rules and left them to work out the consequence.
    private var clearMessage: String {
        let plan = store.clearPlan
        guard !plan.isEmpty else {
            return "Nothing to clear. The only wallpapers here are the ones in use."
        }
        var text = "This removes \(plan.removed.count) "
            + (plan.removed.count == 1 ? "wallpaper" : "wallpapers")
            + " and frees about \(formatSize(plan.bytes))."
        if plan.kept > 0 {
            text += plan.kept == 1
                ? " The one that is playing stays."
                : " The \(plan.kept) in use stay."
        }
        if plan.personal > 0 {
            text += plan.personal == 1
                ? " 1 of them is your own video and cannot be recovered."
                : " \(plan.personal) of them are your own videos and cannot be recovered."
        }
        return text
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 8) {
            MuroMark(cornerRadius: 16)
                .frame(width: 64, height: 64)
            Text("Muro")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("Version \(AppStore.appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(Color.muroSecondary)
            if let version = store.latestRelease?.version {
                Button {
                    openWhatsNew(store)
                } label: {
                    Text("Muro \(version) is available. See what's new.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                }
                .buttonStyle(.plain)
            }
            CreditLink(text: "Designed & developed by \(Credits.name)", size: 10)
                .padding(.top, 2)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.muroSecondary)
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .liquidGlass(cornerRadius: 14, tint: 0.14, stroke: 0.1)
        }
        .padding(.top, 20)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 58)
    }

    // MARK: - Software update

    private var updateSubtitle: String {
        switch store.updateCheck {
        case .idle:      return "Muro \(AppStore.appVersion)"
        case .checking:  return "Checking GitHub…"
        case .upToDate:  return "Muro \(AppStore.appVersion) is the latest version"
        case .available(let version, _):
            return "Version \(version) is available on GitHub"
        case .failed:    return "Couldn't check. Check your connection."
        }
    }

    @ViewBuilder private var updateControl: some View {
        switch store.updateCheck {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 96)
        case .available:
            // Muro is not self-updating, so this hands over the DMG itself
            // when the release has one and the release page when it does not.
            Button("Download ↗") { store.downloadUpdate() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(Color.muroAccent))
        default:
            Button("Check Now") {
                Task { await store.checkForUpdates(userInitiated: true) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5.5)
            .glassCapsule(fill: 0.09, stroke: 0.15)
        }
    }

    /// The only place in Settings that asks for anything.
    ///
    /// One ordinary row, built with the same helper as every other, so it sits
    /// in the list rather than shouting over it. It is already the only warm
    /// colour among the blues and teals and the only heart among the gears,
    /// which is contrast enough; a glowing or pulsing treatment would be a nag
    /// wearing a nicer outfit, and the reason people trust Muro is that it
    /// never does that. Nothing here is gated, nothing is withheld, and
    /// ignoring it costs the user nothing.
    private var sponsorControl: some View {
        Button("Sponsor ↗") { NSWorkspace.shared.open(AppStore.sponsorURL) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5.5)
            .glassCapsule(fill: 0.09, stroke: 0.15)
    }

    private func row(
        icon: String, tint: Color, title: String, subtitle: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.22))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muroSecondary)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Frosted-glass window chrome

/// NSVisualEffectView bridge — the translucent blurred "liquid glass" base
/// behind the Settings content.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Only touches the window chrome: transparent, full-size-content,
/// separator-less titlebar so the SwiftUI glass background shows through it
/// seamlessly. It does NOT insert any view (that previously covered the
/// content and blanked the window).
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
    }
}
