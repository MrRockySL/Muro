import SwiftUI
import MuroKit

// The clock schedule, drawn as the day it describes.
//
// Before this, a clock automation was four numbers in two 62pt fields and you
// had to hold the whole day in your head to see whether it made sense. Here
// the day is 24 hours wide, each wallpaper occupies the slot it actually owns,
// and a gap is a visible hole rather than a sentence in the footer.

/// One drawn piece of the day. A window that runs past midnight is one step
/// but two pieces, which is exactly how it behaves.
struct DaySpan: Identifiable {
    var id: String
    var stepID: String
    var start: Int          // minute of day, 0 ..< 1440
    var length: Int         // minutes
    var item: WallpaperItem?
    /// False for the tail of a wrapped window, so only the first piece is
    /// labelled and the pair does not read as two separate windows.
    var leading: Bool
    var trailing: Bool
}

enum DayLayout {
    static let minutesPerDay = 1440

    /// Splits every step into the pieces that fit inside one day.
    static func spans(for steps: [Automation.Step], resolve: (String) -> WallpaperItem?) -> [DaySpan] {
        var out: [DaySpan] = []
        for step in steps {
            let item = resolve(step.wallpaperID)
            // Same start and end means all day, which is what `covers` does.
            let length = step.start == step.end ? minutesPerDay : step.clockLength
            let start = step.start
            if start + length <= minutesPerDay {
                out.append(DaySpan(id: step.id, stepID: step.id, start: start, length: length,
                                   item: item, leading: true, trailing: true))
            } else {
                let head = minutesPerDay - start
                out.append(DaySpan(id: step.id + "-head", stepID: step.id, start: start, length: head,
                                   item: item, leading: true, trailing: false))
                out.append(DaySpan(id: step.id + "-tail", stepID: step.id, start: 0, length: length - head,
                                   item: item, leading: false, trailing: true))
            }
        }
        return out
    }

    /// The same gap list the footer states, as drawable pieces.
    static func gapSpans(_ automation: Automation) -> [(start: Int, length: Int)] {
        automation.uncoveredWindows.flatMap { gap -> [(start: Int, length: Int)] in
            let length = gap.end > gap.start ? gap.end - gap.start : gap.end + minutesPerDay - gap.start
            if gap.start + length <= minutesPerDay {
                return [(gap.start, length)]
            }
            let head = minutesPerDay - gap.start
            return [(gap.start, head), (0, length - head)]
        }
    }

    static func minuteOfNow() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: - Read-only strip (automation card)

/// The version on a card: no handles, no dragging, just the day at a glance.
struct DayTimelineStrip: View {
    @EnvironmentObject var store: AppStore
    let automation: Automation
    var height: CGFloat = 40
    var showsHourLabels = true

    private var spans: [DaySpan] {
        DayLayout.spans(for: automation.steps) { store.item(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    DayTrack(height: height)
                    ForEach(Array(DayLayout.gapSpans(automation).enumerated()), id: \.offset) { _, gap in
                        GapBlock(width: barWidth(gap.length, in: width), height: height - 8, labelled: false)
                            .offset(x: offset(gap.start, in: width))
                    }
                    ForEach(spans) { span in
                        SpanBlock(span: span, width: barWidth(span.length, in: width), height: height - 8, compact: true)
                            .offset(x: offset(span.start, in: width))
                    }
                    NowMarker(height: height)
                        .offset(x: offset(DayLayout.minuteOfNow(), in: width) - 1)
                }
            }
            .frame(height: height)
            if showsHourLabels { HourLabels() }
        }
    }

    private func offset(_ minute: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(minute) / CGFloat(DayLayout.minutesPerDay)
    }

    private func barWidth(_ minutes: Int, in width: CGFloat) -> CGFloat {
        max(width * CGFloat(minutes) / CGFloat(DayLayout.minutesPerDay), 3)
    }
}

// MARK: - Pieces

private struct DayTrack: View {
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
            .overlay {
                GeometryReader { geo in
                    ForEach(Array(stride(from: 3, to: 24, by: 3)), id: \.self) { hour in
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 1)
                            .offset(x: geo.size.width * CGFloat(hour) / 24)
                    }
                }
            }
            .frame(height: height)
    }
}

private struct SpanBlock: View {
    @EnvironmentObject var store: AppStore
    let span: DaySpan
    let width: CGFloat
    let height: CGFloat
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        // Centred, not leading-aligned. A leading ZStack pins the artwork to
        // the left edge and crops everything off the right, so a wide window
        // showed a sliver of one side of the wallpaper instead of the middle.
        ZStack {
            Color.black
            if let item = span.item { ThumbImage(item: item, maxPixels: 240) }
            Color.black.opacity(0.45)
        }
        .frame(width: max(width - 4, 3), height: height)
        .clipShape(shape)
        // A window owns the clicks inside its own bar and not one point
        // outside it, whatever the artwork inside wants to be.
        .contentShape(shape)
        .overlay(alignment: .leading) {
            if width > 74, span.leading, let item = span.item {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    if width > 128, !compact || height > 34 {
                        Text(rangeLabel)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 11)
                .allowsHitTesting(false)
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        .padding(.leading, 2)
    }

    /// Midnight at the end of a window is 24:00, not 00:00. Reading
    /// "12:00 AM to 12:00 AM" for a whole day is the one place the clock
    /// format actively misleads.
    private var rangeLabel: String {
        guard span.length < DayLayout.minutesPerDay else { return "00:00 – 24:00" }
        let end = (span.start + span.length) % DayLayout.minutesPerDay
        return "\(clockLabel(span.start)) – \(end == 0 ? "24:00" : clockLabel(end))"
    }
}

/// A gap is allowed on purpose, so it is drawn as a stated fact in amber
/// rather than hidden or flagged as an error.
private struct GapBlock: View {
    var width: CGFloat
    var height: CGFloat
    var labelled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(Color.muroWarn.opacity(0.10))
            shape.strokeBorder(Color.muroWarn.opacity(0.22), lineWidth: 1)
            if labelled, width > 96 {
                Text("Not covered")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.muroWarn.opacity(0.95))
                    .padding(.horizontal, 11)
            }
        }
        .frame(width: max(width - 4, 3), height: height)
        .padding(.leading, 2)
    }
}

private struct NowMarker: View {
    var height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.muroAccent)
                .frame(width: 7, height: 7)
                .offset(y: 2)
            Rectangle()
                .fill(Color.muroAccent)
                .frame(width: 2)
        }
        .frame(height: height)
        .shadow(color: Color.muroAccent.opacity(0.6), radius: 4)
    }
}

private struct HourLabels: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in 0 }
                    .offset(
                        x: geo.size.width * CGFloat(hour) / 24
                            - (hour == 0 ? 0 : hour == 24 ? 11 : 5)
                    )
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Draggable editor

/// The editing version: the same day, with edges you can drag.
///
/// ## Why this is written the way it is
///
/// Two rewrites went into this. The first recomputed the drag limits every
/// frame from state the previous frame had already changed, so each frame
/// clamped against a different day and the block juddered between two answers.
/// That is fixed by capturing the limits once, at the moment the drag starts.
///
/// The second rewrite still stuttered, and the reason was subtler: **the shape
/// of the view tree changed while the drag was running.** A window that crossed
/// midnight went from one piece to two; a window that got narrow lost its
/// handles; the ring around the active window appeared and disappeared; the
/// number of gap blocks changed on every boundary crossed. Every one of those
/// is an insertion or a removal, and SwiftUI answers an insertion by building a
/// new view, which tears down the gesture recogniser attached to the old one.
/// Mid-drag. The pointer keeps moving, the gesture has gone, and a new one
/// starts from wherever the pointer now is: that is the jump, the flicker, and
/// the thumbnails reloading underneath.
///
/// So the tree here is **completely static**. Every step always draws exactly
/// two pieces (the second is empty unless the window wraps), the handles and
/// the selection ring are always present and vary only by opacity, and the gaps
/// are painted in a `Canvas`, which has no view identity to churn at all.
/// Nothing in the drag path is allowed to animate.
struct DayTimelineEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var steps: [Automation.Step]
    @Binding var focusedStepID: String?
    var height: CGFloat = 54

    private enum Edge { case start, end, whole }

    /// Everything a drag needs, captured once at the start.
    private struct DragState {
        var stepID: String
        var edge: Edge
        var originalStart: Int
        var originalEnd: Int
        /// The window sharing this edge, dragged along with it.
        var joinedID: String?
        var joinedOriginal: Int
        var minDelta: Int
        var maxDelta: Int
    }

    @State private var drag: DragState?
    @State private var hoveredID: String?
    /// The snapped delta currently applied, kept so the value only changes
    /// once the pointer has clearly left it.
    @State private var appliedDelta = 0

    /// A fixed frame to measure the pointer against. See `gesture(for:)`.
    private static let space = "muro.dayTimeline"

    private static let snap = 15
    /// A window can never be dragged shorter than this, or it would vanish
    /// under the pointer and be impossible to grab again.
    private static let minimumLength = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                // Leading, not topLeading. A window is ten points shorter than
                // the track it sits in, and pinned to the top it left all ten
                // of them in a strip along the bottom, so a full-day window
                // looked as though it had slipped out of its lane. The gap
                // canvas was already drawing itself centred, which is what
                // made the mismatch visible.
                ZStack(alignment: .leading) {
                    DayTrack(height: height)
                    gapLayer
                    ForEach(steps) { step in
                        window(step, width: width)
                    }
                    NowMarker(height: height)
                        .offset(x: offset(DayLayout.minuteOfNow(), in: width) - 1)
                        .allowsHitTesting(false)
                }
                .coordinateSpace(name: Self.space)
            }
            .frame(height: height)
            HourLabels()
        }
    }

    private var draft: Automation {
        Automation(name: "", mode: .clock, steps: steps)
    }

    // MARK: - Gaps

    /// Painted, not built. A gap appearing or closing as an edge is dragged
    /// would otherwise insert and remove views on almost every frame.
    private var gapLayer: some View {
        Canvas { context, size in
            for gap in DayLayout.gapSpans(draft) {
                let x = size.width * CGFloat(gap.start) / CGFloat(DayLayout.minutesPerDay)
                let w = max(size.width * CGFloat(gap.length) / CGFloat(DayLayout.minutesPerDay), 6)
                let rect = CGRect(x: x + 2, y: 5, width: w - 4, height: size.height - 10)
                let shape = Path(roundedRect: rect, cornerRadius: 11, style: .continuous)
                context.fill(shape, with: .color(Color.muroWarn.opacity(0.10)))
                context.stroke(shape, with: .color(Color.muroWarn.opacity(0.22)), lineWidth: 1)
                if rect.width > 96 {
                    context.draw(
                        Text("Not covered")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.muroWarn.opacity(0.95)),
                        at: CGPoint(x: rect.minX + 11, y: rect.midY),
                        anchor: .leading
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Windows

    /// Always two pieces, so the tree never changes shape when a window
    /// crosses midnight.
    @ViewBuilder private func window(_ step: Automation.Step, width: CGFloat) -> some View {
        let length = step.start == step.end ? DayLayout.minutesPerDay : step.clockLength
        let wraps = step.start + length > DayLayout.minutesPerDay
        let headLength = wraps ? DayLayout.minutesPerDay - step.start : length
        let active = focusedStepID == step.id || hoveredID == step.id || drag?.stepID == step.id

        piece(step, start: step.start, length: headLength, width: width,
              leading: true, trailing: !wraps, active: active, visible: true)
        piece(step, start: 0, length: wraps ? length - headLength : 0, width: width,
              leading: false, trailing: true, active: active, visible: wraps)
    }

    private func piece(
        _ step: Automation.Step,
        start: Int,
        length: Int,
        width: CGFloat,
        leading: Bool,
        trailing: Bool,
        active: Bool,
        visible: Bool
    ) -> some View {
        let w = barWidth(length, in: width)
        let handleWidth = min(16, max(w / 3, 6))
        let allDay = Automation.isAllDay(step)
        let span = DaySpan(
            id: step.id, stepID: step.id, start: start, length: length,
            item: store.item(id: step.wallpaperID), leading: leading, trailing: trailing
        )
        return SpanBlock(span: span, width: w, height: height - 10)
            .overlay(alignment: .leading) {
                handle(step, edge: .start, width: width, hitWidth: handleWidth)
                    .opacity(leading && w >= 40 && !allDay ? (active ? 0.9 : 0.5) : 0)
                    .allowsHitTesting(!allDay)
            }
            .overlay(alignment: .trailing) {
                handle(step, edge: .end, width: width, hitWidth: handleWidth)
                    .opacity(trailing && w >= 40 && !allDay ? (active ? 0.9 : 0.5) : 0)
                    .allowsHitTesting(!allDay)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.muroAccent.opacity(0.85), lineWidth: 1.5)
                    .frame(width: max(w - 4, 3), height: height - 10)
                    .padding(.leading, 2)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .offset(x: offset(start, in: width))
            .zIndex(drag?.stepID == step.id ? 2 : (active ? 1 : 0))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .onHover { inside in
                if inside { hoveredID = step.id }
                else if hoveredID == step.id { hoveredID = nil }
            }
            // The whole day starts at 00:00 and ends at 24:00. There is no
            // edge to pull and nowhere to slide it to.
            .gesture(gesture(for: step, edge: .whole, width: width), isEnabled: !allDay)
    }

    private func handle(_ step: Automation.Step, edge: Edge, width: CGFloat, hitWidth: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 3, height: height - 30)
            .frame(width: hitWidth, height: height - 10)
            .contentShape(Rectangle())
            .onHover { inside in
                // set(), not push()/pop(): a pushed cursor that never pops
                // because the view was rebuilt mid-hover leaves the whole app
                // stuck with a resize pointer.
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(gesture(for: step, edge: edge, width: width))
    }

    // MARK: - Dragging

    /// The gesture is measured against the bar, not against the block.
    ///
    /// This was the last and worst of the stutters. A `DragGesture` with no
    /// coordinate space reports translation in the space of the view it is
    /// attached to, and these blocks move as they are dragged. So the block
    /// shifted, its own coordinate space shifted with it, the next translation
    /// came back measured from the new position, and the block shifted again:
    /// a feedback loop between the pointer and the thing following it. That is
    /// the vibration, and no amount of holding the view tree still could fix
    /// it, because the numbers themselves were wrong.
    ///
    /// Naming a space on the bar, which never moves, breaks the loop.
    private func gesture(for step: Automation.Step, edge: Edge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let state: DragState
                if let existing = drag, existing.stepID == step.id, existing.edge == edge {
                    state = existing
                } else {
                    state = begin(step, edge: edge)
                    drag = state
                    appliedDelta = 0
                    focusedStepID = step.id
                }
                apply(minutes(value.translation.width, in: width), with: state)
            }
            .onEnded { _ in
                drag = nil
                appliedDelta = 0
                NSCursor.arrow.set()
            }
    }

    /// Captures the limits once, so every frame of the drag clamps against the
    /// same day rather than against the day the previous frame produced.
    private func begin(_ step: Automation.Step, edge: Edge) -> DragState {
        let length = step.start == step.end ? DayLayout.minutesPerDay : step.clockLength
        let busy = occupancy(excluding: step.id)
        var joinedID: String?
        var joinedOriginal = 0
        var minDelta = 0
        var maxDelta = 0

        switch edge {
        case .start:
            if let neighbour = steps.first(where: {
                $0.id != step.id && $0.start != $0.end && $0.end == step.start
            }) {
                joinedID = neighbour.id
                joinedOriginal = neighbour.end
                minDelta = -(neighbour.clockLength - Self.minimumLength)
            } else {
                minDelta = -freeRun(before: step.start, in: busy, limit: DayLayout.minutesPerDay - length)
            }
            maxDelta = length - Self.minimumLength
        case .end:
            if let neighbour = steps.first(where: {
                $0.id != step.id && $0.start != $0.end && $0.start == step.end
            }) {
                joinedID = neighbour.id
                joinedOriginal = neighbour.start
                maxDelta = neighbour.clockLength - Self.minimumLength
            } else {
                maxDelta = freeRun(after: step.end, in: busy, limit: DayLayout.minutesPerDay - length)
            }
            minDelta = -(length - Self.minimumLength)
        case .whole:
            minDelta = -freeRun(before: step.start, in: busy, limit: DayLayout.minutesPerDay - length)
            maxDelta = freeRun(after: step.end, in: busy, limit: DayLayout.minutesPerDay - length)
        }

        return DragState(
            stepID: step.id, edge: edge,
            originalStart: step.start, originalEnd: step.end,
            joinedID: joinedID, joinedOriginal: joinedOriginal,
            minDelta: minDelta, maxDelta: maxDelta
        )
    }

    private func apply(_ raw: Int, with state: DragState) {
        // Hysteresis. Rounding alone flips between two answers whenever the
        // pointer rests near a boundary, which is what made the times flicker
        // faster than they could be read.
        let candidate = snapped(raw)
        if abs(raw - appliedDelta) >= Int(Double(Self.snap) * 0.62) {
            appliedDelta = candidate
        }
        let delta = min(max(appliedDelta, state.minDelta), state.maxDelta)
        guard let index = steps.firstIndex(where: { $0.id == state.stepID }) else { return }
        let joined = state.joinedID.flatMap { id in steps.firstIndex { $0.id == id } }

        let newStart: Int
        let newEnd: Int
        switch state.edge {
        case .start:
            newStart = normalizedMinute(state.originalStart + delta)
            newEnd = state.originalEnd
        case .end:
            newStart = state.originalStart
            newEnd = normalizedMinute(state.originalEnd + delta)
        case .whole:
            newStart = normalizedMinute(state.originalStart + delta)
            newEnd = normalizedMinute(state.originalEnd + delta)
        }
        // Writing the same values again would still publish a change and
        // redraw the whole bar for nothing, sixty times a second.
        guard steps[index].start != newStart || steps[index].end != newEnd else { return }

        // Nothing here may animate. An implicit animation on a value that
        // changes every frame is what made the blocks and the times shiver.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            steps[index].startMinute = newStart
            steps[index].endMinute = newEnd
            if let joined {
                switch state.edge {
                case .start: steps[joined].endMinute = newStart
                case .end: steps[joined].startMinute = newEnd
                case .whole: break
                }
            }
        }
    }

    // MARK: - Room

    /// Minutes owned by every window except one.
    private func occupancy(excluding stepID: String) -> [Bool] {
        var busy = [Bool](repeating: false, count: DayLayout.minutesPerDay)
        for step in steps where step.id != stepID {
            let length = step.start == step.end ? DayLayout.minutesPerDay : step.clockLength
            for offset in 0..<length {
                busy[(step.start + offset) % DayLayout.minutesPerDay] = true
            }
        }
        return busy
    }

    private func freeRun(before minute: Int, in busy: [Bool], limit: Int) -> Int {
        var count = 0
        var probe = normalizedMinute(minute - 1)
        while count < limit && !busy[probe] {
            count += 1
            probe = normalizedMinute(probe - 1)
        }
        return count
    }

    private func freeRun(after minute: Int, in busy: [Bool], limit: Int) -> Int {
        var count = 0
        var probe = normalizedMinute(minute)
        while count < limit && !busy[probe] {
            count += 1
            probe = normalizedMinute(probe + 1)
        }
        return count
    }

    // MARK: - Geometry

    private func minutes(_ points: CGFloat, in width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int((points / width * CGFloat(DayLayout.minutesPerDay)).rounded())
    }

    private func snapped(_ minute: Int) -> Int {
        Int((Double(minute) / Double(Self.snap)).rounded()) * Self.snap
    }

    private func offset(_ minute: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(minute) / CGFloat(DayLayout.minutesPerDay)
    }

    private func barWidth(_ minutes: Int, in width: CGFloat) -> CGFloat {
        max(width * CGFloat(minutes) / CGFloat(DayLayout.minutesPerDay), 8)
    }
}
