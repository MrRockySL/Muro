import SwiftUI
import MuroKit

enum AutomationEditorTarget: Identifiable {
    case new
    case edit(Automation)

    var id: String {
        if case .edit(let automation) = self { return automation.id }
        return "new"
    }
}

/// Create and edit an automation.
///
/// The shape follows the playlist editor: name at the top, the wallpaper
/// picker in its own scroller, the schedule below it, the buttons in a fixed
/// footer. What it adds is the schedule surface, and in clock mode that is a
/// drawing of the day rather than a column of numbers.
struct AutomationEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: AutomationEditorTarget

    @State private var name = ""
    @State private var mode = Automation.Mode.timer
    @State private var steps: [Automation.Step] = []
    @State private var loaded = false
    @State private var customFor: String?
    @State private var focusedStepID: String?
    @State private var reorderID: String?
    @State private var reorderOffset: CGFloat = 0
    /// How many slots the held row has committed to moving. Kept as state so
    /// it only changes once the row has clearly left the slot it is in.
    @State private var reorderJump = 0

    /// Row height plus the gap, the distance one place in the list is worth.
    private static let rowStride: CGFloat = 66

    /// A fixed frame to measure the pointer against. See `reorderGesture`.
    private static let listSpace = "muro.stepList"

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty && !steps.isEmpty && nameProblem == nil }

    /// Same rule as a playlist: three automations called "New Automation" are
    /// three rows nobody can tell apart. Compared without case or surrounding
    /// spaces.
    private var nameProblem: String? {
        let name = trimmedName
        guard !name.isEmpty else { return nil }
        let existing = store.automations.map { (id: $0.id, name: $0.name) }
        return nameIsTaken(name, in: existing, excluding: editingID)
            ? "Name already in use" : nil
    }

    private var editingID: String? {
        if case .edit(let automation) = target { return automation.id }
        return nil
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// The wallpaper picker is exactly two rows tall and always exactly two
    /// rows tall. The sheet has a fixed width, so this is arithmetic rather
    /// than something to measure: four columns 12pt apart inside 26pt margins,
    /// each one a 16:9 box.
    ///
    /// It matters that this is a constant. It used to grow to fill the sheet
    /// while nothing was picked and snap down to two rows as soon as something
    /// was, and a `LazyVGrid` that shrinks keeps drawing the row that has just
    /// left its bounds while no longer treating it as inside them. The second
    /// row stayed on screen and stopped answering clicks, so the first
    /// wallpaper could always be added and after that only the top row could.
    private static let sheetWidth: CGFloat = 760
    private static let tileWidth: CGFloat = (sheetWidth - 52 - 36) / 4
    private static let pickerHeight: CGFloat = (tileWidth * 9 / 16) * 2 + 12 + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: isNew ? "New Automation" : "Edit Automation") { dismiss() }
                .padding(.horizontal, 26)
                .padding(.top, 26)

            HStack(spacing: 14) {
                GlassTextField(
                    label: "NAME", placeholder: "Automation name",
                    text: $name, problem: nameProblem
                )
                modePicker
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)

            Text(modeHint)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muroSecondary)
                .padding(.horizontal, 26)
                .padding(.top, 10)

            SectionLabel("CHOOSE WALLPAPERS", trailing: "\(steps.count) in this schedule")
                .padding(.horizontal, 26)
                .padding(.top, 22)

            picker
                .padding(.top, 12)
                // The picker keeps its size before anything below it is
                // considered. See `schedule`.
                .layoutPriority(1)

            schedule

            footer
        }
        .frame(width: 760, height: 780)
        .sheetSurface()
        .menuHost()
        .onAppear(perform: load)
    }

    /// Everything below the picker, in one slot that is always there.
    ///
    /// This used to be an `if` in the middle of the sheet's own stack, so
    /// picking the first wallpaper changed the stack from five children to
    /// eight and the picker was relaid out as a side effect. That relayout is
    /// what broke it: the picker kept drawing its full height while the scroll
    /// view underneath kept the squeezed size it was offered mid-change, so
    /// only the top row of wallpapers answered a click, and the wheel only
    /// scrolled inside that same band. It showed up in clock mode and not in
    /// timer mode because the clock schedule is the taller of the two, so it
    /// was the one that squeezed.
    ///
    /// One slot, always present, always the same size: whatever changes inside
    /// it, the picker above never moves and never resizes.
    @ViewBuilder private var schedule: some View {
        Group {
            if steps.isEmpty {
                emptySchedule
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(
                        mode == .timer ? "HOW LONG EACH ONE PLAYS" : "WHEN EACH ONE PLAYS",
                        trailing: mode == .timer ? "Drag the handle to reorder" : "Drag an edge to change a time"
                    )
                    .padding(.horizontal, 26)
                    .padding(.top, 22)

                    if mode == .clock {
                        DayTimelineEditor(steps: $steps, focusedStepID: $focusedStepID, height: 54)
                            .padding(.horizontal, 26)
                            .padding(.top, 14)
                            .animation(.easeOut(duration: 0.2), value: steps)
                    }

                    GlassScrollView(fadeTop: 12, fadeBottom: 20) {
                        VStack(spacing: 8) {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                                let held = reorderID == step.id
                                stepRow(step)
                                    .offset(y: reorderShift(at: index))
                                    .scaleEffect(held ? 1.02 : 1)
                                    .shadow(color: .black.opacity(held ? 0.5 : 0), radius: 18, y: 9)
                                    .zIndex(held ? 1 : 0)
                                    // The held row must track the pointer
                                    // exactly, so it is the one thing here that
                                    // never animates. The rest glide to their
                                    // new slot.
                                    .animation(
                                        held ? nil : .spring(response: 0.3, dampingFraction: 0.86),
                                        value: reorderTarget
                                    )
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                        .coordinateSpace(name: Self.listSpace)
                    }

                    if mode == .timer { durationPresets }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the schedule area says before there is a schedule. The picker no
    /// longer stretches into this space, so something has to stand in it, and
    /// the useful thing to put there is what the next click will do.
    private var emptySchedule: some View {
        VStack(spacing: 7) {
            Image(systemName: mode == .timer ? "timer" : "clock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.white.opacity(0.22))
            Text("Nothing scheduled yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(mode == .timer
                 ? "Pick a wallpaper above and it plays for ten minutes. Every one you add gets its own length."
                 : "Pick a wallpaper above and it takes the whole day. Add another and the day splits between them.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 26)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            name = uniqueName(base: "New Automation", taken: store.automations.map(\.name))
        case .edit(let automation):
            name = automation.name
            mode = automation.mode
            steps = automation.steps
        }
    }

    // MARK: - Mode

    private var modePicker: some View {
        PillSegments(
            options: [
                PillOption(Automation.Mode.timer.rawValue, "Timer", systemImage: "timer"),
                PillOption(Automation.Mode.clock.rawValue, "Clock", systemImage: "clock")
            ],
            selection: Binding(
                get: { mode.rawValue },
                set: { raw in
                    guard let new = Automation.Mode(rawValue: raw) else { return }
                    mode = new
                    seedDefaults()
                }
            ),
            height: 40,
            labelSize: 12.5,
            horizontalPadding: 16
        )
        .fixedSize()
    }

    private var modeHint: String {
        mode == .timer
            ? "Each wallpaper plays for its own length of time, then the next one takes over and it loops."
            : "Each wallpaper owns a slot on the clock, and the same schedule repeats every day."
    }

    /// Moving between modes must not leave a step with nothing set. Clock
    /// windows are laid end to end across the day so a fresh clock schedule
    /// is already valid, and the values from the other mode are kept, so
    /// switching back and forth costs nothing.
    private func seedDefaults() {
        guard !steps.isEmpty else { return }
        switch mode {
        case .timer:
            for index in steps.indices where steps[index].seconds == nil {
                steps[index].seconds = 600
            }
        case .clock:
            guard steps.contains(where: { $0.startMinute == nil }) else { return }
            steps = Automation.fittedToDay(steps)
        }
    }

    // MARK: - Picker

    /// Its own scroller, capped in height. With a big library the schedule
    /// used to sit a full page below the grid and you had to scroll past every
    /// wallpaper you own to reach the thing you came to set.
    @ViewBuilder private var picker: some View {
        if store.localItems.isEmpty {
            Text("No wallpapers downloaded yet. Download some from Explore, or import your own with the + button in the Library.")
                .font(.system(size: 12))
                .foregroundStyle(Color.muroSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .glass(cornerRadius: 14, fill: 0.05, stroke: 0.1)
                .padding(.horizontal, 26)
        } else {
            // Two rows fit, and with a bigger library nothing else says there
            // is a third. See `GlassScrollView`.
            GlassScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.localItems) { item in
                        PickerTile(
                            item: item,
                            selected: steps.contains { $0.wallpaperID == item.id },
                            titleSize: 10.5
                        ) { toggle(item) }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 8)
            }
            // One height, never conditional. See `pickerHeight`.
            .frame(height: Self.pickerHeight)
        }
    }

    private func toggle(_ item: WallpaperItem) {
        if let index = steps.firstIndex(where: { $0.wallpaperID == item.id }) {
            remove(at: index)
        } else {
            add(Automation.Step(wallpaperID: item.id, seconds: 600))
        }
    }

    /// Adding always lands the wallpaper somewhere it can be seen.
    ///
    /// In clock mode that is the largest gap in the day if there is one, and a
    /// fresh division of the whole day if there is not. See
    /// `Automation.fittedAdding`: a full day is not a reason to refuse, and an
    /// arrangement that was made by hand is not something to overwrite just
    /// because one more wallpaper arrived.
    private func add(_ step: Automation.Step) {
        guard mode == .clock else {
            steps.append(step)
            return
        }
        steps = Automation.fittedAdding(step, to: steps)
    }

    private func remove(at index: Int) {
        guard steps.indices.contains(index) else { return }
        let step = steps[index]
        guard mode == .clock else {
            steps.remove(at: index)
            return
        }
        steps = Automation.fittedRemoving(step, from: steps)
    }

    // MARK: - Steps

    private static let durations = [10, 30, 60, 300, 900, 3600]

    @ViewBuilder private func stepRow(_ step: Automation.Step) -> some View {
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            let focused = focusedStepID == step.id
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(reorderID == step.id ? 0.9 : 0.4))
                    .frame(width: 22, height: 44)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(reorderGesture(step))
                Text("\(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(width: 14)
                Color.black
                    .frame(width: 76, height: 43)
                    .overlay {
                        if let item = store.item(id: step.wallpaperID) {
                            ThumbImage(item: item, maxPixels: 300)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
                Text(store.item(id: step.wallpaperID)?.title ?? "Missing wallpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if mode == .timer {
                    durationControl(step)
                } else {
                    clockControl(step)
                }
                Button {
                    remove(at: index)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Remove from this automation")
            }
            .padding(.horizontal, 13)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.glassSheen(focused ? 0.09 : 0.06, focused ? 0.04 : 0.028))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        focused ? Color.muroAccent.opacity(0.5) : Color.white.opacity(0.1),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .onTapGesture { focusedStepID = step.id }
        }
    }

    // MARK: - Reordering
    //
    // Two things had to go for this to stop dancing.
    //
    // `onDrag` had to go first: it hands the row to AppKit's drag-and-drop,
    // which paints its own translucent snapshot under the pointer while the
    // real row stays where it was. That was the second copy following the
    // mouse.
    //
    // Then the array had to stop moving. Reordering `steps` on every boundary
    // crossed meant the list re-laid out under the pointer while the pointer
    // was still down, and the correction that kept the row in place fought the
    // animation that was moving everything else. Nothing is reordered while a
    // drag is running now. The held row simply follows the pointer, the others
    // slide one slot out of its way, and the array is rewritten exactly once,
    // on release.

    /// Where the row currently sits, ignoring the drag.
    private var reorderFrom: Int? {
        reorderID.flatMap { id in steps.firstIndex { $0.id == id } }
    }

    /// The slot the held row would land in if it were dropped now.
    private var reorderTarget: Int? {
        guard let from = reorderFrom else { return nil }
        return min(max(from + reorderJump, 0), steps.count - 1)
    }

    /// How far a row has to move to make room. The held row gets the raw
    /// pointer translation; everything between it and its target shifts by
    /// exactly one slot.
    private func reorderShift(at index: Int) -> CGFloat {
        guard let from = reorderFrom, let to = reorderTarget else { return 0 }
        if index == from { return reorderOffset }
        if from < to, index > from, index <= to { return -Self.rowStride }
        if to < from, index >= to, index < from { return Self.rowStride }
        return 0
    }

    /// Measured against the list, not against the row.
    ///
    /// This is what was left of the dancing. A `DragGesture` with no
    /// coordinate space reports translation in the space of the view carrying
    /// it, and the handle sits inside the row that the drag is moving. The row
    /// moved, its coordinate space moved with it, the next translation came
    /// back measured from the new position, and the row moved again: pointer
    /// and row chasing each other. Naming a space on the list, which stays
    /// still, breaks the loop.
    private func reorderGesture(_ step: Automation.Step) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if reorderID != step.id {
                    reorderID = step.id
                    reorderJump = 0
                }
                reorderOffset = value.translation.height
                // The row has to travel past 62% of a slot before the list
                // rearranges, so a hand hovering on a boundary cannot flip it
                // back and forth.
                let slots = reorderOffset / Self.rowStride
                if abs(slots - CGFloat(reorderJump)) > 0.62 {
                    reorderJump = Int(slots.rounded())
                }
            }
            .onEnded { _ in
                NSCursor.arrow.set()
                let from = reorderFrom
                let to = reorderTarget
                // The row is already sitting where it will land, so the commit
                // must not animate or it would slide there a second time.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let from, let to, from != to {
                        steps = Automation.reordered(
                            steps, from: from, to: to, carryingSlots: mode == .clock
                        )
                    }
                    reorderID = nil
                    reorderOffset = 0
                    reorderJump = 0
                }
            }
    }

    /// A binding into one step, found by id rather than held by position.
    ///
    /// These used to close over the row's index. A binding outlives the body
    /// that made it, so removing the last step left a control still holding
    /// the index of a row that no longer existed, and the next read of it was
    /// an out-of-range crash. Nothing here can name a row that has gone.
    private func stepValue(
        _ id: String,
        get: @escaping (Automation.Step) -> Int,
        set: @escaping (inout Automation.Step, Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: { steps.first { $0.id == id }.map(get) ?? 0 },
            set: { value in
                guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
                set(&steps[index], value)
            }
        )
    }

    private func durationControl(_ step: Automation.Step) -> some View {
        let id = step.id
        return DurationStepper(
            seconds: stepValue(id, get: { $0.duration }, set: { $0.seconds = $1 }),
            presets: Self.durations
        ) { customFor = id }
        .anchoredCard(
            isPresented: Binding(
                get: { customFor == id },
                set: { if !$0 { customFor = nil } }
            ),
            width: 300,
            align: .trailing
        ) {
            CustomDurationPicker(
                seconds: stepValue(id, get: { $0.duration }, set: { $0.seconds = $1 })
            ) { customFor = nil }
        }
    }

    private func clockControl(_ step: Automation.Step) -> some View {
        let id = step.id
        return HStack(spacing: 8) {
            TimeChip(
                minute: stepValue(id, get: { $0.start }, set: { $0.startMinute = $1 }),
                focused: false
            )
            Text("to")
                .font(.system(size: 11))
                .foregroundStyle(Color.muroSecondary)
                .fixedSize()
            TimeChip(
                minute: stepValue(id, get: { $0.end }, set: { $0.endMinute = $1 }),
                focused: focusedStepID == id
            )
        }
    }

    /// Sets every step at once. Giving eight wallpapers the same length used
    /// to be eight trips through a dropdown.
    private var durationPresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set every step at once")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
            HStack(spacing: 8) {
                ForEach(Self.durations, id: \.self) { seconds in
                    Button {
                        for index in steps.indices { steps[index].seconds = seconds }
                    } label: {
                        Text(durationLabel(seconds))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 13)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        SheetFooter {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLine)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if warningLine != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.muroWarn)
                    }
                    Text(secondLine)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            warningLine != nil ? Color.muroWarn.opacity(0.92) : Color.muroSecondary
                        )
                        .lineLimit(1)
                }
            }
            // Two lines always, so a gap appearing while an edge is dragged
            // cannot resize the footer and shove the schedule up and down.
            .frame(height: 36, alignment: .leading)
        } actions: {
            if !isNew {
                DangerPill(title: "Delete") {
                    if case .edit(let automation) = target { store.deleteAutomation(automation) }
                    dismiss()
                }
            }
            GhostPill(title: "Cancel") { dismiss() }
            PrimaryPill(title: isNew ? "Create Automation" : "Save", enabled: canSave) { save() }
        }
    }

    private var summaryLine: String {
        guard !steps.isEmpty else { return "Pick the wallpapers this automation should use" }
        if mode == .timer {
            let total = steps.reduce(0) { $0 + $1.duration }
            return "Cycle: \(durationLabel(total)) across \(steps.count) wallpaper\(steps.count == 1 ? "" : "s")"
        }
        let covered = 1440 - draft.uncoveredWindows.reduce(0) { total, gap in
            total + (gap.end > gap.start ? gap.end - gap.start : gap.end + 1440 - gap.start)
        }
        return covered >= 1440
            ? "Covers the whole day across \(steps.count) wallpaper\(steps.count == 1 ? "" : "s")"
            : "Covers \(durationLabel(covered * 60)) of the day across \(steps.count) wallpaper\(steps.count == 1 ? "" : "s")"
    }

    /// Overlaps and gaps are allowed on purpose, so they are stated rather
    /// than blocked: an automation that only changes the wallpaper in the
    /// evening is a perfectly reasonable thing to want.
    private var warningLine: String? {
        guard mode == .clock, !steps.isEmpty else { return nil }
        let gaps = draft.uncoveredWindows
        guard let first = gaps.first else { return nil }
        let text = "\(clockLabel(first.start)) to \(clockLabel(first.end)) is not covered"
        return gaps.count > 1
            ? "\(text), and \(gaps.count - 1) other gap\(gaps.count == 2 ? "" : "s"). Whatever is playing stays."
            : "\(text). Whatever is playing stays."
    }

    /// Always present, so the footer keeps its height.
    private var secondLine: String {
        if let warningLine { return warningLine }
        if steps.isEmpty { return "Pick at least one to get started." }
        return mode == .timer
            ? "It loops back to the first wallpaper and starts again."
            : "The same schedule repeats every day."
    }

    private var draft: Automation {
        Automation(name: trimmedName, mode: mode, steps: steps)
    }

    private func save() {
        switch target {
        case .new:
            store.addAutomation(Automation(name: trimmedName, mode: mode, steps: steps))
        case .edit(let original):
            var updated = original
            updated.name = trimmedName
            updated.mode = mode
            updated.steps = steps
            store.updateAutomation(updated)
            // Editing the schedule that is currently running has to take
            // effect now, not at the next boundary.
            if store.activeAutomationID == updated.id { store.startAutomation(updated) }
        }
        dismiss()
    }
}

// MARK: - Small controls

/// A time you can read across the room and nudge without aiming. The old
/// field was 62pt wide with two 11pt chevrons stacked beside it.
struct TimeChip: View {
    @Binding var minute: Int
    var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Wide enough for a 12-hour locale's "12:00 AM". At 54pt this
            // wrapped to "8:00 A / M" on the owner's Mac, which is the whole
            // reason the old field was too small to read in the first place.
            Text(clockLabel(minute))
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                // Fixed, not minimum. While a timeline edge is being dragged
                // this text changes every frame, and a width that tracked the
                // text made the whole row breathe in and out.
                .frame(width: 74, alignment: .leading)
            VStack(spacing: 1) {
                stepper("chevron.up", by: 15)
                stepper("chevron.down", by: -15)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(focused ? AnyShapeStyle(Color.muroAccent.opacity(0.16)) : AnyShapeStyle(LinearGradient.glassSheen(0.10, 0.045)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    focused ? Color.muroAccent.opacity(0.45) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
        )
    }

    private func stepper(_ icon: String, by delta: Int) -> some View {
        Button {
            minute = normalizedMinute(minute + delta)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 18, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Minus, the length, plus. One tap changes a step instead of opening a menu
/// to pick from a list of nine.
struct DurationStepper: View {
    @Binding var seconds: Int
    var presets: [Int]
    var onCustom: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            side("minus") { seconds = step(down: true) }
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 20)
            MenuButton(width: 160, align: .center) {
                presets.map { value in
                    MenuOption(title: durationLabel(value), checked: seconds == value) { seconds = value }
                } + [.divider, MenuOption(title: "Custom…") { onCustom() }]
            } label: {
                HStack(spacing: 6) {
                    Text(durationLabel(seconds))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 76)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 20)
            side("plus") { seconds = step(down: false) }
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.glassSheen(0.10, 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func side(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Steps through the presets, then keeps going in sensible jumps so a
    /// long duration is not thirty clicks away.
    private func step(down: Bool) -> Int {
        let ladder = presets + [7200, 21600, 43200, 86400]
        if down {
            return ladder.last { $0 < seconds } ?? ladder.first ?? seconds
        }
        return ladder.first { $0 > seconds } ?? ladder.last ?? seconds
    }
}

/// Any number of seconds, minutes or hours, for the durations the preset
/// ladder does not cover. Also used by Settings for "Pause after".
struct CustomDurationPicker: View {
    @Binding var seconds: Int
    var done: () -> Void

    @State private var amount = 1
    @State private var unit = "60"

    private var resolved: Int { min(max(amount * (Int(unit) ?? 60), 10), 86_400) }

    var body: some View {
        CustomValueCard(
            title: "Custom duration",
            amount: $amount,
            applyLabel: "Set \(durationLabel(resolved))",
            // Wider than the playlist's card because this one has three units
            // rather than two, and at 272 the row filled the card edge to edge
            // and could not look centred however it was aligned.
            width: 300
        ) {
            PillSegments(
                options: [PillOption("1", "sec"), PillOption("60", "min"), PillOption("3600", "hr")],
                selection: $unit,
                height: 32,
                labelSize: 12,
                horizontalPadding: 13
            )
        } apply: {
            seconds = resolved
            done()
        }
        .onAppear {
            if seconds % 3600 == 0 && seconds >= 3600 { amount = seconds / 3600; unit = "3600" }
            else if seconds % 60 == 0 && seconds >= 60 { amount = seconds / 60; unit = "60" }
            else { amount = seconds; unit = "1" }
        }
    }
}
