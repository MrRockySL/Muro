import SwiftUI
import AVFoundation
import AppKit
import MuroKit

// The first launch, and only the first launch.
//
// The gallery window opens small and greets: the Muro moon and its name
// appear, the person picks the language Muro speaks, and on Continue the same
// window grows to its full size while a short 3D film plays in it (a tunnel of
// live wallpapers that unrolls into a galaxy and pours into the moon). Near
// the end of the film the gallery shows through and takes over. Designed in Figma first ("MURO 6.1 · WELCOME" in Muro App Design).

/// The welcome window: smaller than the gallery on purpose. It greets, it is
/// not a workspace.
enum WelcomeSize {
    static let window = CGSize(width: 800, height: 530)
}

/// The two films the welcome plays, shipped inside the app. A build made
/// without them still works: the moon falls back to the app icon, and the
/// intro is skipped rather than shown as an empty frame.
enum WelcomeAssets {
    static let moon: URL? = Bundle.main.url(forResource: "WelcomeMoon", withExtension: "mov")
    static let intro: URL? = Bundle.main.url(forResource: "WelcomeIntro", withExtension: "mov")
    /// Seconds into the intro at which the gallery starts to show through it.
    static let handoff: Double = 7.3
}

/// How long each move of the welcome takes, in seconds.
enum WelcomeTiming {
    /// The film coming up over the language screen.
    static let filmIn = 0.45
    /// The window growing from the welcome's size to the gallery's.
    static let grow = 0.8
    /// The film fading into the gallery at its end, and after Skip.
    static let filmOut = 0.6
    static let filmOutSkipped = 0.4
}

extension MuroLanguage {
    /// Each language's own colour on the welcome screen, shown only once it
    /// is picked: on its card, the Continue button and the glow below. In
    /// the order the languages are listed they run as one spectrum, from
    /// Muro's blue to teal.
    var welcomeHue: Color {
        switch self {
        case .german: return Color(hex: 0x5AA9FF)
        case .english: return Color(hex: 0x6F8BFF)
        case .spanish: return Color(hex: 0x8E7BFF)
        case .french: return Color(hex: 0xB57BFF)
        case .italian: return Color(hex: 0xE07BEA)
        case .portuguese: return Color(hex: 0xFF7BB0)
        case .russian: return Color(hex: 0xFF8A73)
        case .japanese: return Color(hex: 0xFFB36B)
        case .korean: return Color(hex: 0xE6D36A)
        case .simplifiedChinese: return Color(hex: 0x7DE8A8)
        case .traditionalChinese: return Color(hex: 0x4FD6C9)
        }
    }
}

// MARK: - The flow

struct WelcomeFlow: View {
    @EnvironmentObject var store: AppStore

    /// `leaving`: the languages go and the film comes up over the greeting.
    /// `intro`: only the film is left. The window grows around it once, then
    /// the gallery is built under it and the film fades into the gallery.
    private enum Phase { case start, language, leaving, intro }

    @State private var phase: Phase = .start
    @State private var picked: MuroLanguage = Localization.shared.language
    @State private var filmStage: IntroFilmStage = .waiting
    /// The gallery's window size, which is where the welcome ends. The film is
    /// laid out at this size from the start, so growing only uncovers more of
    /// it and the picture itself never moves or scales.
    @State private var canvas: CGSize?
    @State private var grown = false
    @State private var revealing = false
    @State private var skipRequested = false
    @FocusState private var focused: Bool

    private let mac = Localization.systemLanguage()

    var body: some View {
        ZStack {
            // Taken away once the film covers the window: only the film is
            // left to redraw while the window grows.
            if phase != .intro {
                WelcomeNight(hue: picked.welcomeHue, showsLanguageGlow: phase == .language)
                moon
                name
                if phase == .language {
                    languages
                        .transition(.opacity.combined(with: .offset(y: 14)))
                }
            }

            // Here from the first frame, paused and see-through, so Continue
            // starts a film that is already loaded instead of a cut while it
            // loads. It lets every click through to the cards under it.
            if let url = WelcomeAssets.intro {
                IntroFilm(
                    url: url,
                    canvas: canvas,
                    stage: filmStage,
                    hideDuration: skipRequested ? WelcomeTiming.filmOutSkipped : WelcomeTiming.filmOut,
                    handoffAt: WelcomeAssets.handoff,
                    onShown: filmShown,
                    onHandoff: reveal,
                    onHidden: finish,
                    onEnd: reveal
                )
                .allowsHitTesting(false)
            }

            if phase == .leaving || phase == .intro, !revealing {
                skipButton
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) { proceed(); return .handled }
        .onKeyPress(.escape) { skip(); return .handled }
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .onKeyPress(.upArrow) { move(by: -4); return .handled }
        .onKeyPress(.downArrow) { move(by: 4); return .handled }
        .contentShape(Rectangle())
        .onTapGesture { if phase == .start { showLanguages() } }
        .onAppear {
            focused = true
            if let window = mainWindow {
                WelcomeWindow.prepare(window)
                canvas = WelcomeWindow.gallerySize(of: window)
            }
            // A short hello. The spiral of wallpapers belongs to the film
            // after Continue, so it is not told twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { showLanguages() }
        }
    }

    // MARK: The moon and the name

    /// One moon for the whole greeting: big in the middle while it forms,
    /// then up to the top, smaller, when the languages arrive.
    private var moon: some View {
        let forming = phase == .start
        return WelcomeMoon()
            .frame(width: 200, height: 200)
            .scaleEffect(forming ? 1 : 0.64)
            .offset(y: forming ? -51 : -187)
            .opacity(phase == .leaving ? 0 : 1)
            .modifier(Arrival(delay: 0.1))
    }

    private var name: some View {
        Text(verbatim: "Muro")
            .font(.system(size: 40, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.white)
            .offset(y: 116)
            .opacity(phase == .start ? 1 : 0)
            .modifier(Arrival(delay: 0.4))
    }

    // MARK: The languages

    private var languages: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 142)
            Text(L("Welcome to Muro"))
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L("Choose your language"))
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0x98A0AC))
                .padding(.top, 6)
            VStack(spacing: 12) {
                row(Array(LanguageMenu.order.prefix(4)))
                row(Array(LanguageMenu.order.dropFirst(4).prefix(4)))
                row(Array(LanguageMenu.order.dropFirst(8)))
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
            HStack {
                Text(L("You can change it later in Settings."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x98A0AC))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 16)
                Button(action: proceed) {
                    Text(L("Continue"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x0A0C10))
                        .lineLimit(1)
                        .padding(.horizontal, 26)
                        .frame(height: 40)
                        .background(Capsule().fill(continueFill))
                        .shadow(color: picked.welcomeHue.opacity(0.45), radius: 10, y: 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
        }
        .frame(width: WelcomeSize.window.width, height: WelcomeSize.window.height)
        .opacity(phase == .leaving ? 0 : 1)
    }

    private var continueFill: Color {
        Color(nsColor: NSColor(picked.welcomeHue).blended(withFraction: 0.25, of: .white) ?? NSColor(picked.welcomeHue))
    }

    private func row(_ items: [MuroLanguage]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.self) { language in
                LanguageCard(
                    language: language,
                    speaking: Localization.shared.language,
                    isPicked: language == picked,
                    isMac: language == mac
                ) { pick(language) }
            }
        }
    }

    private var skipButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: skip) {
                    Text(L("Skip"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.trailing, 16)
    }

    // MARK: Steps

    private func showLanguages() {
        guard phase == .start else { return }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) { phase = .language }
    }

    /// Picking a language changes every word on the window at once. The
    /// Mac's own language is kept as "follow the Mac", the same as choosing
    /// Same as macOS in Settings, so a later change in System Settings still
    /// carries through.
    private func pick(_ language: MuroLanguage) {
        guard phase == .language else { return }
        withAnimation(.easeOut(duration: 0.25)) { picked = language }
        store.setLanguage(language == mac ? nil : language)
    }

    private func move(by step: Int) {
        guard phase == .language, let index = LanguageMenu.order.firstIndex(of: picked) else { return }
        let next = index + step
        guard LanguageMenu.order.indices.contains(next) else { return }
        pick(LanguageMenu.order[next])
    }

    private func proceed() {
        switch phase {
        case .start: showLanguages()
        case .language: leave()
        default: break
        }
    }

    private func skip() {
        switch phase {
        case .start:
            showLanguages()
        case .leaving, .intro:
            skipRequested = true
            reveal()
        case .language:
            break
        }
    }

    // Continue, in three moves that never overlap, so each one only has to
    // redraw what is left on screen:
    //   1. the film, already playing, dissolves in over the greeting;
    //   2. the window grows once, straight to the gallery's size, over the
    //      film alone (the greeting is gone from under it by then);
    //   3. the gallery is built under the film, and at the film's end the film
    //      fades straight into it.
    // The old way grew the window while the film was still loading, grew it
    // to a size 28 points short of the gallery (so it jumped again when the
    // gallery arrived), and faded the film into the welcome's sky before the
    // gallery cut in over it.

    private func leave() {
        guard phase == .language else { return }
        withAnimation(.easeIn(duration: 0.3)) { phase = .leaving }
        if WelcomeAssets.intro != nil {
            filmStage = .showing
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { filmShown() }
        }
    }

    /// The film covers the whole window now.
    private func filmShown() {
        guard phase == .leaving else { return }
        phase = .intro
        guard let window = mainWindow, let canvas else { grew(); return }
        WelcomeWindow.grow(window, to: canvas, duration: WelcomeTiming.grow, completion: grew)
    }

    /// The window has the gallery's size, and keeps it from here on.
    private func grew() {
        guard !grown else { return }
        grown = true
        // Built now, under the film and at its final size, so the gallery is
        // finished long before anyone sees it and nothing is laid out, and no
        // window changes size, at the moment it shows.
        if WelcomeAssets.intro == nil {
            withAnimation(.easeOut(duration: 0.35)) { store.welcomeHandoff = true }
            reveal()
        } else {
            store.welcomeHandoff = true
            if skipRequested { reveal() }
        }
    }

    /// The film fades into the gallery: at its end, or straight away on Skip.
    /// Waits for the window to finish growing if it has not yet.
    private func reveal() {
        guard grown else {
            skipRequested = true
            return
        }
        guard !revealing else { return }
        withAnimation(.easeOut(duration: 0.25)) { revealing = true }
        if let window = mainWindow { WelcomeWindow.release(window) }
        if WelcomeAssets.intro == nil {
            finish()
        } else {
            filmStage = .hiding
        }
    }

    private func finish() {
        guard store.welcomeActive else { return }
        if let window = mainWindow { WelcomeWindow.release(window) }
        store.finishWelcome()
    }
}

/// Fades a piece in once, a moment after the window opens.
private struct Arrival: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.86)
            .onAppear {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(delay)) { shown = true }
            }
    }
}

// MARK: - One language

private struct LanguageCard: View {
    let language: MuroLanguage
    /// The language the window speaks right now, for the second line.
    let speaking: MuroLanguage
    let isPicked: Bool
    let isMac: Bool
    let action: () -> Void

    @State private var hovering = false

    private var hue: Color { language.welcomeHue }

    /// The language's name in the language the window speaks now, the way
    /// macOS writes it. Left out on the card of that same language, where it
    /// would only repeat the name above it.
    private var localName: String? {
        guard language != speaking,
              let name = speaking.locale.localizedString(forIdentifier: language.rawValue)
        else { return nil }
        return name.prefix(1).uppercased(with: speaking.locale) + name.dropFirst()
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.nativeName)
                        .font(.system(size: language == .portuguese ? 14 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if localName != nil || isMac {
                        HStack(spacing: 6) {
                            if let localName {
                                Text(localName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: 0x98A0AC))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            if isMac {
                                Text(verbatim: "Mac")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.3)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)))
                            }
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if isPicked {
                    tick
                        .padding(10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 176, height: 64)
            .background(card)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isPicked ? hue.opacity(0.9) : .white.opacity(hovering ? 0.2 : 0.1), lineWidth: isPicked ? 1.5 : 1)
            )
            .shadow(color: isPicked ? hue.opacity(0.42) : .clear, radius: 13, y: 8)
            .scaleEffect(hovering && !isPicked ? 1.02 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityLabel(Text(language.nativeName))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    /// Only the picked card has a colour. Every card carrying its own coloured
    /// dot and corner glow was eleven colours at once, too much for one
    /// screen, so the rest stay plain glass.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(
                colors: isPicked
                    ? [hue.opacity(0.26), hue.opacity(0.09)]
                    : [.white.opacity(hovering ? 0.11 : 0.085), .white.opacity(0.035)],
                startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(
                colors: [hue.opacity(isPicked ? 0.42 : 0), hue.opacity(0)],
                center: .topTrailing, startRadius: 0, endRadius: 90))
        }
    }

    private var tick: some View {
        Circle()
            .fill(hue)
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x0A0C10))
            )
    }
}

// MARK: - The night behind everything

/// The welcome's sky: a midnight gradient, moonlight above, a glow in the
/// picked language's colour below, and still stars and coloured lights kept
/// to the edges so they never sit behind a word.
private struct WelcomeNight: View {
    let hue: Color
    let showsLanguageGlow: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0F1424), Color(hex: 0x0A0D16), Color(hex: 0x07090F)],
                           startPoint: .top, endPoint: .bottom)
            Ellipse().fill(Color(hex: 0x3D7BFF).opacity(0.32))
                .frame(width: 580, height: 320).blur(radius: 90).offset(x: 0, y: -265)
            Ellipse().fill(Color(hex: 0x7B5CFF).opacity(0.26))
                .frame(width: 460, height: 280).blur(radius: 90).offset(x: 170, y: -255)
            Ellipse().fill(hue.opacity(showsLanguageGlow ? 0.2 : 0.08))
                .frame(width: 720, height: 230).blur(radius: 100).offset(x: 0, y: 310)
                .animation(.easeOut(duration: 0.35), value: hue)
            WelcomeStars()
        }
    }
}

private struct WelcomeStars: View {
    private static let palette: [Color] = ([0xFF8A3D, 0x4FD6C9, 0xFF7BB0, 0x8E7BFF, 0xFFC46B, 0x7DE8A8, 0x5AA9FF, 0xE07BEA, 0xFF6B6B] as [UInt32])
        .map { Color(hex: $0) }

    var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<70 {
                let d = 0.8 + rng.next() * 1.0
                let point = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: d, height: d)),
                             with: .color(.white.opacity(0.12 + rng.next() * 0.4)))
            }
            for _ in 0..<30 {
                let color = Self.palette[Int(rng.next() * Double(Self.palette.count)) % Self.palette.count]
                let d = 1.8 + rng.next() * 2.2
                var point: CGPoint
                repeat {
                    point = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                } while point.x > 26 && point.x < size.width - 26 && point.y > 130 && point.y < size.height - 20
                let opacity = 0.55 + rng.next() * 0.4
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 3))
                    glow.fill(Path(ellipseIn: CGRect(x: point.x - d, y: point.y - d, width: d * 3, height: d * 3)),
                              with: .color(color.opacity(opacity * 0.8)))
                }
                context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: d, height: d)),
                             with: .color(color.opacity(opacity)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The 3D Muro moon, turning slowly. A film with a see-through background;
/// the app icon stands in when a build has no film.
private struct WelcomeMoon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x6F8BFF).opacity(0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: 110))
                .frame(width: 260, height: 260)
            if let url = WelcomeAssets.moon {
                LoopingPlayerView(url: url)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .padding(28)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small, repeatable random sequence, so the stars land in the same place
/// on every draw instead of jumping.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

// MARK: - The intro film

enum IntroFilmStage: Equatable {
    /// Loaded, paused on its first frame, see-through.
    case waiting
    /// Playing, and coming up over whatever is under it.
    case showing
    /// Fading away, uncovering the gallery.
    case hiding
}

private struct IntroFilm: NSViewRepresentable {
    let url: URL
    let canvas: CGSize?
    let stage: IntroFilmStage
    let hideDuration: Double
    let handoffAt: Double
    let onShown: () -> Void
    let onHandoff: () -> Void
    let onHidden: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> IntroFilmView {
        IntroFilmView(url: url, handoffAt: handoffAt)
    }

    func updateNSView(_ view: IntroFilmView, context: Context) {
        view.canvas = canvas
        view.onHandoff = onHandoff
        view.onEnd = onEnd
        switch stage {
        case .waiting: break
        case .showing: view.show(duration: WelcomeTiming.filmIn, completion: onShown)
        case .hiding: view.hide(duration: hideDuration, completion: onHidden)
        }
    }
}

/// Plays the intro once, muted. It is loaded as soon as the welcome opens and
/// waits on its first frame, invisible, so Continue never waits for it.
///
/// Everything that moves here is Core Animation, not SwiftUI: the fades are
/// layer animations, and the picture is a fixed size (the gallery's window)
/// centred in the view, so while the window grows around it nothing is
/// rescaled and the picture stays exactly where it is on screen.
final class IntroFilmView: NSView {
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    /// The film and its night behind it: the one layer that fades.
    private let film = CALayer()
    private var readyObservation: NSKeyValueObservation?
    private var boundaryToken: Any?
    private var endToken: NSObjectProtocol?

    var onHandoff: (() -> Void)?
    var onEnd: (() -> Void)?
    /// The size to lay the picture out at, centred. Nil fills the view.
    var canvas: CGSize? {
        didSet { if canvas != oldValue { needsLayout = true } }
    }

    private enum Target { case hidden, shown, gone }
    private var target: Target = .hidden
    private var pendingShow: (duration: Double, completion: () -> Void)?

    init(url: URL, handoffAt: Double) {
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        // The film's own night, so a frame that is late to decode is never a
        // flash of white or of what is under it.
        film.backgroundColor = NSColor(red: 0.016, green: 0.024, blue: 0.043, alpha: 1).cgColor
        film.opacity = 0
        film.masksToBounds = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        film.addSublayer(playerLayer)
        layer?.addSublayer(film)
        boundaryToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: handoffAt, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in self?.onHandoff?() }
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in self?.onEnd?() }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.startPendingShow() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let boundaryToken { player.removeTimeObserver(boundaryToken) }
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        player.pause()
    }

    /// Never in the way of a click: while it waits, the cards under it are
    /// what is being clicked.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(duration: Double, completion: @escaping () -> Void) {
        guard target == .hidden else { return }
        target = .shown
        pendingShow = (duration, completion)
        if playerLayer.isReadyForDisplay {
            startPendingShow()
        } else {
            // A first frame that never arrives must not hold the welcome up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startPendingShow() }
        }
    }

    private func startPendingShow() {
        guard let pending = pendingShow else { return }
        pendingShow = nil
        player.play()
        fade(to: 1, duration: pending.duration, completion: pending.completion)
    }

    func hide(duration: Double, completion: @escaping () -> Void) {
        guard target != .gone else { return }
        target = .gone
        pendingShow = nil
        fade(to: 0, duration: duration, completion: completion)
    }

    private func fade(to value: Float, duration: Double, completion: @escaping () -> Void) {
        let from = film.presentation()?.opacity ?? film.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = value
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        film.opacity = value
        film.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let size = canvas ?? bounds.size
        // On whole pixels. The window grows by an even number of points each
        // step around a fixed centre, so this lands on the same spot every
        // time and the picture cannot shimmer between two pixels.
        let scale = window?.backingScaleFactor ?? 2
        let x = ((bounds.width - size.width) / 2 * scale).rounded() / scale
        let y = ((bounds.height - size.height) / 2 * scale).rounded() / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        film.frame = bounds
        playerLayer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        CATransaction.commit()
    }
}

// MARK: - The window

/// The welcome borrows the gallery window rather than opening one of its own,
/// so growing into the gallery is one window changing size, not two windows
/// swapping places.
@MainActor
enum WelcomeWindow {
    /// Welcome size, centred, and fixed while the greeting is up. The size is
    /// the whole window, title bar included, because the greeting draws under
    /// the hidden title bar the way the design does. The window is see-through
    /// for the moment it changes size, so the first launch never flashes the
    /// gallery's size before the greeting's.
    static func prepare(_ window: NSWindow) {
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.alphaValue = 0
        let size = NSSize(width: WelcomeSize.window.width, height: WelcomeSize.window.height)
        window.setFrame(centred(size, around: window.screen?.visibleFrame.center ?? window.frame.center, on: window.screen), display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
    }

    /// The whole window the gallery opens at: its content plus the title bar
    /// over it. The welcome grows to exactly this, measured from the window
    /// rather than assumed, so the gallery's own minimum size, which takes
    /// over when it is built, finds the window already right and never moves
    /// it again. (The content size alone, which the first version grew to,
    /// was 28 points short, and the window jumped when the gallery arrived.)
    static func gallerySize(of window: NSWindow) -> CGSize {
        let titleBar = max(0, window.frame.height - window.contentLayoutRect.height)
        return CGSize(width: GallerySize.opening.width, height: GallerySize.opening.height + titleBar)
    }

    /// Grows the window once, around its centre, to `size`, in step with the
    /// display.
    static func grow(_ window: NSWindow, to size: CGSize, duration: Double, completion: @escaping () -> Void) {
        let target = centred(NSSize(width: size.width, height: size.height), around: window.frame.center, on: window.screen)
        WindowGrowth(window: window, to: target, duration: duration, completion: completion).start()
    }

    static func release(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = true
    }

    /// Centred on `centre` on whole points, kept on the screen. The size is
    /// never rounded up, unlike `NSRect.integral`, which grows a rect a point
    /// whenever its centre falls between two.
    fileprivate static func centred(_ size: NSSize, around centre: NSPoint, on screen: NSScreen?) -> NSRect {
        var frame = NSRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width).rounded()
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height).rounded()
        }
        return frame
    }
}

/// One window resize, driven by the display itself.
///
/// `NSWindow.animator().setFrame` steps on a timer that is not tied to the
/// screen, so its steps landed 8 to 24 ms apart: some refreshes showed no
/// change and the next showed two, which is the stutter people saw. Here every
/// refresh of the display gets exactly one step, placed where the window
/// should be at the moment that refresh appears.
@MainActor
private final class WindowGrowth: NSObject {
    /// The one running, kept alive until it ends.
    private static var running: WindowGrowth?

    private weak var window: NSWindow?
    private let from: NSRect
    private let to: NSRect
    private let duration: Double
    private var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?

    init(window: NSWindow, to: NSRect, duration: Double, completion: @escaping () -> Void) {
        self.window = window
        self.from = window.frame
        self.to = to
        self.duration = duration
        self.completion = completion
    }

    func start() {
        Self.running?.end()
        guard let window, from != to else {
            completion?()
            completion = nil
            return
        }
        Self.running = self
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A display link stops while its window is off screen. A welcome
        // window closed halfway must still finish growing, so the last step
        // is also kept on a clock.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5) { [weak self] in self?.end() }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { end(); return }
        let begin = startTime ?? link.timestamp
        startTime = begin
        let t = min(1, max(0, (link.targetTimestamp - begin) / duration))
        guard t < 1 else { end(); return }
        let frame = frameAt(eased(t))
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// Slow out of the small size, slow into the big one.
    private func eased(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * t) }

    /// The size grows in even numbers of points around a fixed centre, so the
    /// window's edges and the film centred in it always fall on whole pixels.
    private func frameAt(_ e: Double) -> NSRect {
        let width = ((from.width + (to.width - from.width) * e) / 2).rounded() * 2
        let height = ((from.height + (to.height - from.height) * e) / 2).rounded() * 2
        let midX = from.midX + (to.midX - from.midX) * e
        let midY = from.midY + (to.midY - from.midY) * e
        return NSRect(x: (midX - width / 2).rounded(), y: (midY - height / 2).rounded(), width: width, height: height)
    }

    private func end() {
        link?.invalidate()
        link = nil
        if let window, window.frame != to { window.setFrame(to, display: true) }
        if Self.running === self { Self.running = nil }
        let done = completion
        completion = nil
        done?()
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
