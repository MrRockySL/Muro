import SwiftUI
import MuroKit

// Muro 3.0 building blocks. Every surface in the redesigned Library is one of
// these, so the tabs, the import bubble, the cards and the two editor sheets
// cannot drift apart the way the 2.0 versions did.

// MARK: - The plus glyph

/// A plus that is centred because of how it is built, not because of a fudge
/// factor.
///
/// `Image(systemName: "plus")` looks wrong at this size, and the reason is not
/// the drawing: an SF Symbol is laid out as text, so its box carries the font's
/// ascender and descender, and centring that box leaves the ink sitting high.
/// The old code papered over it with a hand-tuned `offset(y: 0.5)` that was
/// still visibly off. Two capsules in a `ZStack` share one centre by
/// definition, keep proper round caps at any weight, and let the stroke scale
/// with the button instead of with a font size.
struct PlusGlyph: View {
    /// Length of each arm.
    var span: CGFloat
    var thickness: CGFloat
    var colour: Color = .white

    var body: some View {
        ZStack {
            Capsule(style: .continuous).frame(width: span, height: thickness)
            Capsule(style: .continuous).frame(width: thickness, height: span)
        }
        .foregroundStyle(colour)
        .frame(width: span, height: span)
    }
}

// MARK: - The glass bubble

/// The surface every round glass control in the app is made of: the Library's
/// import "+", the New Playlist and New Automation cards, and the four
/// controls in the top bar.
///
/// It lives in one place because the four top-bar buttons were asked for as
/// "the plus button with that animation". Two copies of a lit circle drift
/// apart the moment one of them is tuned, so the circle, the light inside it,
/// the rim, the catch-light and the two springs are written once and the
/// callers only supply what goes in the middle.
struct BubbleSurface: ViewModifier {
    var size: CGFloat
    var hovering = false
    var pressed = false
    /// A control that is currently on (search, while the field is open). It
    /// reads like a permanent hover with an accent rim, rather than a
    /// different kind of button.
    var active = false
    var tint: Color = .muroAccent

    private var lit: Bool { hovering || active }

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            // The accent light lives inside the circle.
            //
            // It used to be a radial gradient nearly four times the diameter,
            // painted behind the bubble so it lit the card around it. At the
            // sizes this is actually used at that is not a glow, it is a
            // purple smudge with a button in the middle of it, and the edge of
            // the gradient is visible against the panel. Clipping the same
            // light to the circle keeps the lit look and stops it leaking.
            .background {
                Circle()
                    .fill(.glassSheen(lit ? 0.26 : 0.20, lit ? 0.09 : 0.06))
                    .overlay {
                        RadialGradient(
                            gradient: Gradient(colors: [
                                tint.opacity(active ? 0.38 : (hovering ? 0.30 : 0.20)),
                                tint.opacity(0)
                            ]),
                            center: .center, startRadius: 0, endRadius: size * 0.52
                        )
                        .clipShape(Circle())
                    }
            }
            .overlay(
                Circle().strokeBorder(
                    active ? tint.opacity(0.55) : Color.white.opacity(hovering ? 0.34 : 0.26),
                    lineWidth: 1
                )
            )
            // The top inner highlight, so the bubble looks lit rather than
            // filled.
            .overlay(
                Circle()
                    .trim(from: 0.55, to: 0.95)
                    .stroke(Color.white.opacity(0.30), lineWidth: 1)
                    .blur(radius: 0.5)
                    .padding(1)
            )
            .shadow(color: .black.opacity(0.35), radius: pressed ? 3 : 7, x: 0, y: pressed ? 1 : 4)
            .shadow(color: tint.opacity(active ? 0.28 : 0), radius: 10)
            // It lifts under the pointer and dips when pressed, so clicking
            // the strip feels like pressing something rather than like
            // nothing happening until a file panel appears.
            .scaleEffect(pressed ? 0.94 : (hovering ? 1.06 : 1))
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .animation(.easeOut(duration: 0.2), value: active)
    }
}

extension View {
    func bubbleSurface(
        size: CGFloat,
        hovering: Bool = false,
        pressed: Bool = false,
        active: Bool = false,
        tint: Color = .muroAccent
    ) -> some View {
        modifier(BubbleSurface(size: size, hovering: hovering, pressed: pressed, active: active, tint: tint))
    }
}

/// The liquid-glass "+" shared by the import drop zone, New Playlist, New
/// Automation and the top bar. It replaces the flat accent-tinted circle and,
/// with it, the dashed borders those surfaces used to advertise themselves
/// with.
struct PlusBubble: View {
    var size: CGFloat = 56
    var hovering = false
    var pressed = false

    var body: some View {
        PlusGlyph(span: size * 0.36, thickness: size * 0.054, colour: .muroAccent)
            .shadow(color: Color.muroAccent.opacity(0.55), radius: hovering ? 5 : 3)
            .bubbleSurface(size: size, hovering: hovering, pressed: pressed)
    }
}

/// The press half of a bubble. A `ButtonStyle` is what reads the real press
/// state: tracking it with a gesture of our own would fight the button for the
/// same clicks, and a `@State` written from a gesture cannot know about a
/// press that ends outside the control.
struct BubbleButtonStyle: ButtonStyle {
    var size: CGFloat
    var hovering: Bool
    var active: Bool
    var tint: Color = .muroAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bubbleSurface(
                size: size,
                hovering: hovering,
                pressed: configuration.isPressed,
                active: active,
                tint: tint
            )
            .contentShape(Circle())
    }
}

/// A top-bar control: the import bubble's glass and springs with a symbol in
/// the middle instead of the plus.
///
/// White, not accent. The Library's "+" is accent because it is the one thing
/// on that page asking to be pressed; a row of four accent bubbles in the top
/// bar just turns the corner of the window blue, and it fought the white nav
/// pill next to it (owner, 2026-08-24).
struct GlassBubbleButton: View {
    var systemName: String
    var size: CGFloat = 42
    /// Glyph size as a share of the bubble. Symbols carry their own optical
    /// weight, so a magnifier and a gear do not want the same number.
    var glyphScale: CGFloat = 0.40
    var weight: Font.Weight = .semibold
    var tint: Color = .white
    /// On, as opposed to merely hovered.
    var active = false
    /// The gear turns a little under the pointer. Nothing else does.
    var turns = false
    /// An accent dot on the shoulder of the bubble. One thing in the app uses
    /// it: What's New, when there is a newer Muro to install.
    var badged = false
    var help: String?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * glyphScale, weight: weight))
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.45), radius: hovering ? 5 : 3)
                .rotationEffect(.degrees(turns && hovering ? 40 : 0))
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(BubbleButtonStyle(size: size, hovering: hovering, active: active, tint: tint))
        .overlay(alignment: .topTrailing) {
            // Drawn over the bubble rather than inside the label, so the dot
            // is not dimmed and scaled by the press state with the glyph.
            NotificationDot(size: size * 0.235)
                .offset(x: size * 0.04, y: -size * 0.04)
                .opacity(badged ? 1 : 0)
                .scaleEffect(badged ? 1 : 0.4)
                .animation(.spring(response: 0.4, dampingFraction: 0.62), value: badged)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        // `.help("")` still arms a tooltip, and an empty one flashing under
        // the pointer is worse than none.
        .modifier(OptionalHelp(text: help))
    }
}

/// The unread dot. Accent fill, dark ring so it reads against both the glass
/// bubble and whatever wallpaper is playing behind it, and a slow breath so it
/// catches the eye once without ever becoming the loudest thing on screen.
struct NotificationDot: View {
    var size: CGFloat = 10

    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(Color.muroAccent)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: size * 0.16))
            .shadow(color: Color.muroAccent.opacity(0.85), radius: breathing ? size * 0.7 : size * 0.3)
            .scaleEffect(breathing ? 1.06 : 1)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathing)
            .onAppear { breathing = true }
    }
}

private struct OptionalHelp: ViewModifier {
    var text: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.help(text) } else { content }
    }
}

// MARK: - Chips

/// A small glass chip. The playlist and automation cards use these instead of
/// one run-on meta sentence, so the three facts can be read separately.
struct MetaChip: View {
    var systemImage: String?
    var text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle((tint ?? .white).opacity(tint == nil ? 0.75 : 1))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Color.white.opacity(0.82))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.07 : 0.15)))
        .overlay(Capsule().strokeBorder((tint ?? .white).opacity(tint == nil ? 0.11 : 0.3), lineWidth: 1))
    }
}

/// The green "PLAYING" marker on a running playlist or automation.
struct PlayingChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.muroGreen).frame(width: 5.5, height: 5.5)
            Text("PLAYING")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.42)))
        .overlay(Capsule().strokeBorder(Color.muroGreen.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Play control

/// The round play/pause on a card: a glass bubble that fills solid white while
/// its schedule is the one running.
struct GlassPlayButton: View {
    var playing: Bool
    var enabled: Bool = true
    var diameter: CGFloat = 46
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.28, weight: .semibold))
                .foregroundStyle(playing ? Color.black : Color.white)
                // The play triangle's ink sits left of its box; nudging it
                // back is what makes it look centred in a circle.
                .offset(x: playing ? 0 : 1)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(playing ? AnyShapeStyle(Color.white) : AnyShapeStyle(LinearGradient.glassSheen(0.16, 0.06)))
                )
                .overlay {
                    if !playing { Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1) }
                }
                .shadow(color: .black.opacity(0.32), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Segmented glass bar

/// One option in a `PillSegments` bar.
struct PillOption: Identifiable, Equatable {
    var id: String
    var label: String
    var systemImage: String?
    /// Shown as a small pill after the label, for the library tab counts.
    var count: Int?

    init(_ id: String, _ label: String, systemImage: String? = nil, count: Int? = nil) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.count = count
    }
}

/// Where each segment sits, so the travelling pill can be drawn once at the
/// right place instead of being handed between segments.
private struct SegmentFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The big glass segmented control: library tabs, the playlist interval, the
/// Timer/Clock switch.
///
/// The white pill is ONE view positioned from the measured frame of the
/// selected segment, not a `matchedGeometryEffect` handed from one segment to
/// the next. That effect re-derives its geometry from whichever segment is
/// currently the source, so any relayout mid-flight (a tab count changing from
/// 8 to 9, a label re-rendering at a new weight) restarts the interpolation
/// and the pill visibly shakes. Measuring once and moving one shape cannot do
/// that.
struct PillSegments: View {
    var options: [PillOption]
    @Binding var selection: String
    var height: CGFloat = 38
    var labelSize: CGFloat = 13
    var horizontalPadding: CGFloat = 18
    /// Where each segment sits inside this bar, for anyone who needs to hang
    /// something off one of them. The playlist editor anchors its custom
    /// interval card under the "Custom" segment with it, so the card opens
    /// where the thing that opened it is rather than at the left edge of the
    /// whole control.
    var onSegmentFrames: (([String: CGRect]) -> Void)? = nil

    @State private var frames: [String: CGRect] = [:]

    private static let travel = Animation.spring(response: 0.34, dampingFraction: 0.86)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(5)
        .background(alignment: .topLeading) { pill }
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 9, x: 0, y: 4)
        .coordinateSpace(name: "segments")
        .onPreferenceChange(SegmentFrames.self) { value in
            frames = value
            onSegmentFrames?(value)
        }
    }

    @ViewBuilder private var pill: some View {
        if let rect = frames[selection], rect.width > 0 {
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .animation(Self.travel, value: selection)
                .animation(nil, value: rect.width)
        }
    }

    @ViewBuilder private func segment(_ option: PillOption) -> some View {
        let on = selection == option.id
        HStack(spacing: option.count == nil ? 7 : 8) {
            if let symbol = option.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: labelSize * 0.85, weight: .medium))
                    .foregroundStyle(on ? Color.black : Color.white.opacity(0.7))
            }
            Text(option.label)
                // Without this "Every 15 min" wrapped onto two lines and the
                // segment grew taller than the bar it sits in.
                .font(.system(size: labelSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.78))
            if let count = option.count {
                Text("\(count)")
                    .font(.system(size: labelSize * 0.81, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(on ? Color.black.opacity(0.55) : Color.muroAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    // A fixed width, so a count going from 9 to 10 cannot
                    // resize the segment the pill is sitting on.
                    .frame(minWidth: 22)
                    .background(
                        Capsule().fill(on ? Color.black.opacity(0.10) : Color.muroAccent.opacity(0.16))
                    )
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: SegmentFrames.self,
                    value: [option.id: geo.frame(in: .named("segments"))]
                )
            }
        }
        .contentShape(Capsule())
        // No "already selected, do nothing" guard. A segment can stand for
        // something that opens rather than something that is set, and the
        // playlist editor's "Custom" is exactly that: tapping it again has to
        // bring the picker back.
        .onTapGesture { selection = option.id }
    }
}


// MARK: - Window chrome

/// Takes away the sheet AppKit paints behind a sheet or a popover.
///
/// `presentationBackground(.clear)` is supposed to do this and does not, at
/// least not here: a lighter rounded panel kept showing through wherever our
/// own card curved away from it, which is why every menu and both editors had
/// a halo around their corners. The reason is that the chrome is not part of
/// the presented content at all. It is drawn by the window's frame view, a
/// level above anything SwiftUI hands us, so no modifier on the content can
/// reach it.
///
/// This reaches it: clear the window itself, then hide everything in the frame
/// view that is not our content view. For a popover that is the material sheet
/// and the little arrow; for a sheet it is the background panel. Our own views
/// live inside the content view and are never touched, which matters because
/// some of them are `NSVisualEffectView`s of their own.
struct ClearWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.strip()
    }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            strip()
            // A popover finishes assembling its frame view after the content
            // is installed, so a second pass on the next turn of the run loop
            // catches what the first one could not see.
            DispatchQueue.main.async { [weak self] in self?.strip() }
        }

        func strip() {
            guard let window else { return }
            window.backgroundColor = .clear
            window.isOpaque = false
            guard let content = window.contentView, let frame = content.superview else { return }
            frame.wantsLayer = true
            frame.layer?.backgroundColor = NSColor.clear.cgColor
            for sibling in frame.subviews where sibling !== content {
                sibling.isHidden = true
            }
        }
    }
}

// MARK: - Sheet surface

/// The background of the two editor sheets: the same coloured glass as a page,
/// with the rounded corner the old flat `Color.muroBG` sheets never had.
struct SheetSurface: ViewModifier {
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x11151C), Color(hex: 0x0B0E14)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.muroAccent.opacity(0.16), Color.muroAccent.opacity(0)
                            ]),
                            center: UnitPoint(x: 0.12, y: -0.06), startRadius: 0, endRadius: 480
                        )
                        .clipShape(shape)
                    )
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.3), .white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: 1)
                        .padding(.horizontal, 90)
                    }
            }
            // Sheets are their own window on macOS, so the rounded corners
            // only show once the window's own background is out of the way.
            .background(ClearWindowChrome())
            .presentationBackground(.clear)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func sheetSurface(cornerRadius: CGFloat = 28) -> some View {
        modifier(SheetSurface(cornerRadius: cornerRadius))
    }

    /// The close button every sheet carries in its top right corner.
    func glassCircleChrome(diameter: CGFloat = 32) -> some View {
        self
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.glassSheen(0.13, 0.05)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

// MARK: - Sheet chrome

/// Title and close button. Both editor sheets open with this, so they are
/// recognisably the same kind of surface.
struct SheetHeader: View {
    var title: String
    var onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .glassCircleChrome()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// The small accent caps that head a section inside a sheet.
struct SectionLabel: View {
    var text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Color.muroAccent)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
            }
        }
    }
}

/// A named field. The label lives inside the box, so renaming reads as one
/// object rather than a caption floating above a control.
struct GlassTextField: View {
    var label: String
    var placeholder: String
    @Binding var text: String
    /// Said inside the field rather than under it, so nothing below moves when
    /// it appears and nothing has to be left empty for it while it is absent.
    var problem: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(problem == nil ? Color.muroAccent : Color.muroWarn)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if let problem {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(problem)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.muroWarn)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.muroWarn.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Color.muroWarn.opacity(0.32), lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 50)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.glassSheen(0.085, 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    problem == nil ? Color.white.opacity(0.13) : Color.muroWarn.opacity(0.5),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.16), value: problem)
    }
}

/// One wallpaper in a picker grid, shared by both editors.
struct PickerTile: View {
    let item: WallpaperItem
    var selected: Bool
    var titleSize: CGFloat = 11
    var action: () -> Void

    var body: some View {
        // A Button, not an onTapGesture. These tiles sit inside a scroller
        // that is itself inside a sheet full of drag gestures, and a bare tap
        // recogniser is the first thing to lose that argument.
        Button(action: action) { tile }
            .buttonStyle(.plain)
    }

    private var tile: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(ThumbImage(item: item, maxPixels: 480))
            .overlay(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center, endPoint: .bottom
                )
            )
            .overlay { if selected { Color.muroAccent.opacity(0.14) } }
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(9)
            }
            .overlay(alignment: .topTrailing) {
                SelectionTick(isSelected: selected, size: 21).padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        selected ? Color.muroAccent.opacity(0.85) : Color.white.opacity(0.09),
                        lineWidth: selected ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

/// The fixed bar at the bottom of a sheet: what you are about to make on the
/// left, what to press on the right.
struct SheetFooter<Info: View, Actions: View>: View {
    @ViewBuilder var info: Info
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) { info }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
        }
    }
}

struct PrimaryPill: View {
    var title: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 22)
                .frame(height: 38)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .keyboardShortcut(.defaultAction)
    }
}

struct GhostPill: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(Capsule().fill(.glassSheen(0.11, 0.05)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct DangerPill: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.muroDanger)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(Color.muroDanger.opacity(0.13)))
                .overlay(Capsule().strokeBorder(Color.muroDanger.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A switch drawn by hand. The stock `Toggle` drags AppKit's own blue and its
/// light-mode chrome into a dark sheet.
struct MiniSwitch: View {
    var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.muroAccent : Color.white.opacity(0.16))
            .frame(width: 34, height: 20)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(on ? Color(hex: 0x0B0E14) : Color.white.opacity(0.85))
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2.5)
            }
    }
}

extension View {
    /// Soft fades at both ends of a scroll area, so content dissolves instead
    /// of being sliced off at the clip edge.
    @ViewBuilder
    func scrollFade(top: CGFloat = 22, bottom: CGFloat = 0) -> some View {
        if top <= 0 && bottom <= 0 {
            // No mask at all rather than a mask that happens to be opaque: a
            // mask costs an offscreen pass and dims anything drawn inside it.
            self
        } else {
            mask(
                VStack(spacing: 0) {
                    if top > 0 {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: top)
                    }
                    Color.black
                    if bottom > 0 {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottom)
                    }
                }
            )
        }
    }
}

// MARK: - Scrolling

private struct GlassScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
}

private struct GlassScrollKey: PreferenceKey {
    static let defaultValue = GlassScrollMetrics()
    static func reduce(value: inout GlassScrollMetrics, nextValue: () -> GlassScrollMetrics) {
        let next = nextValue()
        if next.content > 0 { value = next }
    }
}

/// Holds the `NSScrollView` SwiftUI made, so a drawn indicator can move it.
@MainActor
final class ScrollViewHandle: ObservableObject {
    weak var scrollView: NSScrollView?

    /// Scrolls so that `y` points of content sit above the top edge.
    func scroll(to y: CGFloat, maximum: CGFloat) {
        guard let scrollView else { return }
        let clamped = min(max(y, 0), max(maximum, 0))
        let clip = scrollView.contentView
        // SwiftUI's document view is flipped, so its origin counts downwards.
        // Handle the other case too rather than assume it.
        let flipped = scrollView.documentView?.isFlipped ?? true
        let target = flipped ? clamped : max(maximum - clamped, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Walks up from inside the scroller to find it.
private struct ScrollViewFinder: NSViewRepresentable {
    let handle: ScrollViewHandle

    func makeNSView(context: Context) -> NSView { Finder(handle: handle) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Finder: NSView {
        let handle: ScrollViewHandle

        init(handle: ScrollViewHandle) {
            self.handle = handle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // It is a probe, not a surface. Left hit-testable it would be an
        // invisible AppKit view stretched across the whole scrolling content,
        // which is exactly the shape of bug this file has already paid for
        // once.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view: NSView? = superview
            while let current = view {
                if let scroller = current as? NSScrollView {
                    let handle = handle
                    Task { @MainActor in handle.scrollView = scroller }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// A vertical scroller that draws its own indicator.
///
/// AppKit's is one of two things and neither belongs here. Left to itself it is
/// an overlay scroller that only exists while the wheel is turning, so a grid
/// with more below it looks like a grid with nothing below it. Forced visible,
/// or on a Mac set to "Show scroll bars: Always", it becomes the legacy
/// scroller: a wide light track with a fat knob, flush to the edge, lifted out
/// of a different decade of the operating system.
///
/// So it is drawn here, the same way the switches, menus and segmented bars in
/// this app are drawn: a thin capsule, inset from the edge, as long as the
/// share of the content you can see, and only present when there is something
/// to scroll to. It is a working scroller and not a painted marker: the knob
/// drags, and a click on the track above or below it moves a page that way.
struct GlassScrollView<Content: View>: View {
    /// Soft fades at the ends of the content. The indicator is added after
    /// them, so it never fades out at the moment it reaches the end of its
    /// travel.
    var fadeTop: CGFloat = 0
    var fadeBottom: CGFloat = 0
    var inset: CGFloat = 6
    @ViewBuilder var content: Content

    @StateObject private var handle = ScrollViewHandle()
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Where the content sat when the knob was picked up. The knob moves as
    /// the content moves, so measuring each frame against the previous one
    /// would have the pointer and the knob chasing each other.
    @State private var grabbedAt: CGFloat?
    @State private var hovering = false

    private static var space: String { "muro.glassScroll" }
    private static var lane: CGFloat { 13 }

    private var overflow: CGFloat { contentHeight - viewportHeight }
    private var track: CGFloat { viewportHeight - inset * 2 }
    private var knob: CGFloat {
        guard contentHeight > 0 else { return 0 }
        return max(28, min(track, track * viewportHeight / contentHeight))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: GlassScrollKey.self,
                            value: GlassScrollMetrics(
                                offset: -geo.frame(in: .named(Self.space)).minY,
                                content: geo.size.height
                            )
                        )
                    }
                }
                .background(ScrollViewFinder(handle: handle))
        }
        .onPreferenceChange(GlassScrollKey.self) { metrics in
            offset = metrics.offset
            contentHeight = metrics.content
        }
        .scrollFade(top: fadeTop, bottom: fadeBottom)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in viewportHeight = height }
            }
        }
        .overlay(alignment: .topTrailing) { indicator }
        // Named last, so both the content and the indicator sit inside it. A
        // drag measured against the knob itself would be measured against a
        // view the drag is moving.
        .coordinateSpace(name: Self.space)
    }

    @ViewBuilder private var indicator: some View {
        if overflow > 1, track > 24 {
            let travel = track - knob
            let progress = min(max(offset / overflow, 0), 1)
            ZStack(alignment: .top) {
                // The lane. Invisible until the pointer is near, but always
                // there to be clicked.
                Capsule()
                    .fill(Color.white.opacity(hovering ? 0.05 : 0))
                    .frame(width: 5)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(Color.white.opacity(hovering || grabbedAt != nil ? 0.42 : 0.28))
                    .frame(width: grabbedAt != nil ? 5 : 4, height: knob)
                    .frame(width: Self.lane)
                    .contentShape(Rectangle())
                    .offset(y: travel * progress)
                    .gesture(knobDrag(travel: travel))
            }
            .frame(width: Self.lane)
            .padding(.vertical, inset)
            .padding(.trailing, 3)
            .contentShape(Rectangle())
            // A click on the lane above or below the knob moves a page that
            // way, which is what a scroller does everywhere else.
            .gesture(pageTap(travel: travel, progress: progress))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.12), value: grabbedAt != nil)
        }
    }

    private func pageTap(travel: CGFloat, progress: CGFloat) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.space))
            .onEnded { value in
                let knobTop = inset + travel * progress
                let page = max(viewportHeight * 0.9, 40)
                let target = value.location.y < knobTop ? offset - page : offset + page
                handle.scroll(to: target, maximum: overflow)
            }
    }

    private func knobDrag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = grabbedAt ?? offset
                if grabbedAt == nil { grabbedAt = start }
                guard travel > 0 else { return }
                let moved = value.translation.height / travel * overflow
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    handle.scroll(to: start + moved, maximum: overflow)
                }
            }
            .onEnded { _ in grabbedAt = nil }
    }
}

// MARK: - Popover surface

/// The surface under every dropdown, right-click menu and custom-value picker.
///
/// A macOS popover draws its own background: square-ish corners, a grey sheet
/// and a little arrow pointing at whatever opened it. None of that belongs in
/// this app, and no amount of styling the content hides it, because it sits
/// behind the content. Menus are drawn inside the window instead (see
/// `menuHost`), and this is what they are drawn on.
///
/// Real glass, not a dark card. It used to be a 97% opaque panel with an
/// accent bloom across it, which read as a purple box floating over the page
/// rather than as a pane of the same material as the bar it opened from. Now
/// it is the preview bar's recipe: a blur of whatever is behind it, a black
/// wash heavy enough to keep white text readable over a bright 4K wallpaper,
/// a hairline rim, the top catch-light, and a trace of accent that is a tint
/// rather than a colour wash (owner, 2026-08-24).
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20
    /// How dark the glass is tinted. Menus open over 4K video, so this and
    /// the base fill below decide whether their text can be read.
    var tint: Double = 0.32

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            // A trace of accent, under the text and over the glass. The old
            // card had this at 10% across a nearly opaque panel, which is
            // what made every menu read as a purple box.
            .background {
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.muroAccent.opacity(0.07), Color.muroAccent.opacity(0)
                    ]),
                    center: UnitPoint(x: 0.15, y: -0.15), startRadius: 0, endRadius: 240
                )
                .clipShape(shape)
            }
            .modifier(GlassMaterial(shape: shape, tint: tint))
            // A dark base behind the glass. Two reasons: white text over a
            // bright 4K wallpaper needs it, and the menu bar's menus live in a
            // transparent window of their own, where a material with nothing
            // behind it has nothing to blur.
            .background(shape.fill(Color(hex: 0x0B0E14).opacity(0.38)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            // The top edge catch-light, the detail that makes glass read as
            // glass rather than as a lighter rectangle.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.34), .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, cornerRadius * 1.8)
            }
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
            .preferredColorScheme(.dark)
    }
}

/// Real liquid glass where the system has it, a blurred material where it does
/// not. Written once so every menu, card and picker is made of the same thing.
private struct GlassMaterial: ViewModifier {
    let shape: RoundedRectangle
    let tint: Double

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.black.opacity(tint)), in: shape)
        } else {
            content
                .background(shape.fill(Color.black.opacity(tint)))
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// The visual surface only, for a menu drawn inside the window.
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

/// The body of a custom-value picker: an amount, a unit, and one button that
/// says exactly what it is about to set.
struct CustomValueCard<Unit: View>: View {
    var title: String
    var amount: Binding<Int>
    var applyLabel: String
    /// Must match the width the caller anchors the card at, or the card
    /// floats inside a frame of a different size.
    var width: CGFloat = 272
    @ViewBuilder var unit: Unit
    var apply: () -> Void

    var body: some View {
        // Centred, not left-aligned. The card is a small floating panel with
        // one job, and a title and a field pushed into its left corner left a
        // ragged margin down the right of it (owner, 2026-08-24).
        VStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 12) {
                TextField("", value: amount, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(.glassSheen(0.16, 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                unit
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Button(action: apply) {
                Text(applyLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Capsule().fill(Color.white))
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: width)
    }
}

// MARK: - Menus drawn inside the window

/// Menus stopped being popovers.
///
/// A macOS popover paints its own background, and unlike a sheet it does not
/// paint it in a subview that can be hidden: it draws it in the window frame's
/// own draw pass, above anything SwiftUI hands us and out of reach of both
/// `presentationBackground(.clear)` and any AppKit view surgery. Whatever the
/// content looked like, a lighter rounded panel sat behind it, larger than the
/// card and with its own corner radius. The only way to not have it is to not
/// have a popover.
///
/// So a menu is now an overlay inside the window that opened it. Nothing else
/// paints, there is no arrow, the corner radius is ours, and it can be animated
/// like anything else. Each window that can raise a menu installs one host:
/// the main window, the two editor sheets and Settings.
/// Which edge of a menu lines up with the control that opened it.
///
/// A menu is nearly always wider than the control, so this decides which way
/// the extra width goes. Left for a control at the left of its row, right for
/// one at the right (otherwise the menu reaches past the edge of the page),
/// centred for a control in a bar, where either side would look like a
/// mistake.
enum MenuAlign {
    case leading, center, trailing
}

@MainActor
final class MenuPresenter: ObservableObject {
    static let space = "muro.menuHost"

    struct Presentation: Identifiable {
        let id = UUID()
        var anchor: CGRect
        var width: CGFloat
        var align: MenuAlign
        var content: AnyView
    }

    @Published var current: Presentation?

    func show<C: View>(
        anchor: CGRect,
        width: CGFloat,
        align: MenuAlign = .leading,
        @ViewBuilder content: (@escaping () -> Void) -> C
    ) {
        let dismiss: () -> Void = { [weak self] in self?.dismiss() }
        current = Presentation(
            anchor: anchor, width: width, align: align,
            content: AnyView(content(dismiss))
        )
    }

    func dismiss() { current = nil }
}

private struct MenuPresenterKey: EnvironmentKey {
    static let defaultValue: MenuPresenter? = nil
}

extension EnvironmentValues {
    var menuPresenter: MenuPresenter? {
        get { self[MenuPresenterKey.self] }
        set { self[MenuPresenterKey.self] = newValue }
    }
}

/// Reports where its host view sits, so a menu can be anchored to it.
struct AnchorReader: View {
    var onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(MenuPresenter.space))
            Color.clear
                .onAppear { onChange(frame) }
                .onChange(of: frame) { _, new in onChange(new) }
        }
    }
}

private struct MenuSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct MenuOverlay: View {
    let presentation: MenuPresenter.Presentation
    let container: CGSize
    let dismiss: () -> Void

    @State private var size: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Catches the click that closes the menu without dimming the page.
            //
            // Only once the menu has measured itself. This sheet covers the
            // whole window, so a menu that somehow opened without ever
            // producing a size would leave an invisible pane over everything
            // and the window would look dead to every click.
            Color.black.opacity(0.0001)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .allowsHitTesting(size != .zero)
            presentation.content
                .frame(width: presentation.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MenuSizeKey.self, value: geo.size)
                    }
                )
                .offset(x: x, y: y)
                // Hidden for the one frame before its height is known, so it
                // cannot appear in the wrong place and jump.
                .opacity(size == .zero ? 0 : 1)
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
        }
        .onPreferenceChange(MenuSizeKey.self) { size = $0 }
    }

    /// Below the control by default, above it when there is no room below,
    /// and never off either side.
    /// Below the control, and far enough from it to read as a separate
    /// surface rather than an extension of the control.
    private static let gapBelow: CGFloat = 10
    /// More, when it has to flip above. A control that has no room below it
    /// is nearly always sitting in a bar at the bottom of the window, and the
    /// bar's own padding eats most of the gap: at 6 the menu's bottom corners
    /// ended up behind the bar (owner, 2026-08-24).
    private static let gapAbove: CGFloat = 18

    private var x: CGFloat {
        let ideal: CGFloat
        switch presentation.align {
        case .leading:  ideal = presentation.anchor.minX
        case .center:   ideal = presentation.anchor.midX - size.width / 2
        case .trailing: ideal = presentation.anchor.maxX - size.width
        }
        let limit = max(container.width - size.width - 10, 10)
        return min(max(ideal, 10), limit)
    }

    private var y: CGFloat {
        let below = presentation.anchor.maxY + Self.gapBelow
        let above = presentation.anchor.minY - size.height - Self.gapAbove
        if below + size.height > container.height - 10, above > 10 { return above }
        return min(below, max(container.height - size.height - 10, 10))
    }
}

private struct MenuHost: ViewModifier {
    @StateObject private var presenter = MenuPresenter()

    func body(content: Content) -> some View {
        // The geometry reader lives in an overlay, never around the content.
        // A GeometryReader is greedy: it takes all the space offered and pins
        // its child top-leading, so wrapping a fixed-size sheet in one leaves
        // the sheet with no size of its own to give the window.
        content
            .environment(\.menuPresenter, presenter)
            .coordinateSpace(name: MenuPresenter.space)
            .overlay {
                GeometryReader { geo in
                    if let current = presenter.current {
                        MenuOverlay(
                            presentation: current,
                            container: geo.size
                        ) { presenter.dismiss() }
                    }
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.86), value: presenter.current?.id)
                // With no menu up this layer must be as good as absent. It
                // covers the whole window, and a host that ever took a click
                // while empty would look like the window below it had died.
                .allowsHitTesting(presenter.current != nil)
            }
            .onExitCommand { presenter.dismiss() }
    }
}

extension View {
    /// Install once per window that can raise a menu.
    func menuHost() -> some View { modifier(MenuHost()) }
}

/// A control that opens a list of options anchored to itself.
struct MenuButton<Label: View>: View {
    var width: CGFloat = 180
    var align: MenuAlign = .leading
    var options: () -> [MenuOption]
    @ViewBuilder var label: () -> Label

    @Environment(\.menuPresenter) private var presenter
    @State private var anchor: CGRect = .zero
    @State private var screenAnchor = ScreenAnchor()

    var body: some View {
        Button {
            let items = options()
            guard let presenter else {
                // The menu bar panel: no host to draw in, so the menu opens in
                // a window of its own. Never a popover, which would bring its
                // own glass sheet with it.
                MenuBarMenuPanel.shared.show(
                    options: items,
                    width: width,
                    anchor: screenAnchor.frame ?? .zero,
                    parent: screenAnchor.window
                )
                return
            }
            presenter.show(anchor: anchor, width: width, align: align) { dismiss in
                GlassMenuList(width: width, options: items, dismiss: dismiss)
            }
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader { anchor = $0 })
        .background(ScreenAnchorReader(anchor: screenAnchor))
    }
}

/// Where a control sits on screen, for a menu that opens in its own window.
@MainActor
final class ScreenAnchor {
    weak var view: NSView?

    var window: NSWindow? { view?.window }

    var frame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// Hands a `ScreenAnchor` an AppKit view to measure. It reports nothing and
/// takes no clicks; it exists to be somewhere in the window.
struct ScreenAnchorReader: NSViewRepresentable {
    let anchor: ScreenAnchor

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// A right-click menu in the app's own glass, drawn inside the window.
    func glassContextMenu(width: CGFloat, options: @escaping () -> [MenuOption]) -> some View {
        modifier(GlassContextMenu(width: width, options: options))
    }

    /// Arbitrary content anchored to this view, for the custom-value pickers.
    func anchoredCard<C: View>(
        isPresented: Binding<Bool>,
        width: CGFloat,
        align: MenuAlign = .leading,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        modifier(AnchoredCard(isPresented: isPresented, width: width, align: align, card: content))
    }
}

private struct GlassContextMenu: ViewModifier {
    var width: CGFloat
    var options: () -> [MenuOption]

    @Environment(\.menuPresenter) private var presenter
    @State private var anchor: CGRect = .zero
    @State private var screenAnchor = ScreenAnchor()

    func body(content: Content) -> some View {
        content
            .background(AnchorReader { anchor = $0 })
            .background(ScreenAnchorReader(anchor: screenAnchor))
            .overlay(RightClickCatcher {
                let items = options()
                guard !items.isEmpty else { return }
                guard let presenter else {
                    MenuBarMenuPanel.shared.show(
                        options: items, width: width,
                        anchor: screenAnchor.frame ?? .zero, parent: screenAnchor.window
                    )
                    return
                }
                presenter.show(anchor: anchor, width: width) { dismiss in
                    GlassMenuList(width: width, options: items, dismiss: dismiss)
                }
            })
    }
}

private struct AnchoredCard<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    var width: CGFloat
    var align: MenuAlign = .leading
    var card: () -> C

    @Environment(\.menuPresenter) private var presenter
    @State private var anchor: CGRect = .zero
    @State private var screenAnchor = ScreenAnchor()

    func body(content: Content) -> some View {
        content
            .background(AnchorReader { anchor = $0 })
            .background(ScreenAnchorReader(anchor: screenAnchor))
            .onChange(of: isPresented) { _, now in
                guard let presenter else {
                    // The menu bar panel, which has nowhere inside itself to
                    // draw. Never a popover: it would bring its own sheet.
                    if now {
                        MenuBarMenuPanel.shared.show(
                            width: width,
                            anchor: screenAnchor.frame ?? .zero,
                            parent: screenAnchor.window
                        ) {
                            card().glassCard(cornerRadius: 22)
                        }
                    } else {
                        MenuBarMenuPanel.shared.close()
                    }
                    return
                }
                if now {
                    presenter.show(anchor: anchor, width: width, align: align) { _ in
                        card()
                            .glassCard(cornerRadius: 22)
                            // Fires whether the card closed itself or the user
                            // clicked away, so the flag never gets stuck on.
                            .onDisappear { isPresented = false }
                    }
                } else {
                    presenter.dismiss()
                }
            }
    }
}
