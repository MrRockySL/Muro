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

/// Create and edit an automation. Deliberately the same shape as the playlist
/// editor the owner already approved: name at the top, the wallpaper grid in
/// the middle, the schedule and the buttons in a fixed footer.
///
/// The one thing it adds is the ordered list of chosen wallpapers below the
/// grid, because in an automation each one carries its own setting: a duration
/// in timer mode, a from and to time in clock mode.
struct AutomationEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: AutomationEditorTarget

    @State private var name = ""
    @State private var mode = Automation.Mode.timer
    @State private var steps: [Automation.Step] = []
    @State private var loaded = false
    @State private var customFor: String?

    private static let danger = Color(hex: 0xFF6B6B)

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty && !steps.isEmpty }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
            HStack(spacing: 12) {
                nameField
                modePicker
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            Text(modeHint)
                .font(.system(size: 11))
                .foregroundStyle(Color.muroSecondary)
                .padding(.horizontal, 24)
                .padding(.top, 9)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("CHOOSE WALLPAPERS", trailing: "\(steps.count) in this schedule")
                        .padding(.top, 16)
                    if store.localItems.isEmpty {
                        emptyLibrary.padding(.top, 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.localItems) { item in
                                tile(item)
                            }
                        }
                        .padding(.top, 12)
                    }
                    if !steps.isEmpty {
                        sectionLabel(
                            mode == .timer ? "HOW LONG EACH ONE PLAYS" : "WHEN EACH ONE PLAYS",
                            trailing: mode == .timer ? "Drag to reorder" : "First match wins"
                        )
                        .padding(.top, 24)
                        VStack(spacing: 8) {
                            ForEach(steps) { step in
                                stepRow(step)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .topFade(16)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
        }
        .frame(width: 720, height: 640)
        .background(Color.muroBG)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            name = "New Automation"
        case .edit(let automation):
            name = automation.name
            mode = automation.mode
            steps = automation.steps
        }
    }

    // MARK: - Header and mode

    private var header: some View {
        HStack {
            Text(isNew ? "New Automation" : "Edit Automation")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var nameField: some View {
        TextField("Automation name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(cornerRadius: 10, fill: 0.06, stroke: 0.12)
    }

    private var modePicker: some View {
        CapsuleSegments(
            options: [("Timer", Automation.Mode.timer.rawValue),
                      ("Clock", Automation.Mode.clock.rawValue)],
            selection: Binding(
                get: { mode.rawValue },
                set: { raw in
                    guard let new = Automation.Mode(rawValue: raw) else { return }
                    mode = new
                    seedDefaults()
                }
            )
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
            let slot = 1440 / steps.count
            for index in steps.indices {
                steps[index].startMinute = steps[index].startMinute ?? (index * slot)
                steps[index].endMinute = steps[index].endMinute
                    ?? ((index + 1) * slot % 1440)
            }
        }
    }

    // MARK: - Wallpaper grid

    private func sectionLabel(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Color.muroAccent)
            Spacer()
            Text(trailing)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
        }
    }

    private var emptyLibrary: some View {
        Text("No wallpapers downloaded yet. Download some from Explore or import your own with the + button.")
            .font(.system(size: 12))
            .foregroundStyle(Color.muroSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glass(cornerRadius: 12, fill: 0.05, stroke: 0.1)
    }

    private func tile(_ item: WallpaperItem) -> some View {
        let picked = steps.contains { $0.wallpaperID == item.id }
        return Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(ThumbImage(item: item))
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                SelectionTick(isSelected: picked, size: 19).padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        picked ? Color.muroAccent.opacity(0.8) : Color.white.opacity(0.08),
                        lineWidth: picked ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { toggle(item) }
    }

    private func toggle(_ item: WallpaperItem) {
        if let index = steps.firstIndex(where: { $0.wallpaperID == item.id }) {
            steps.remove(at: index)
        } else {
            steps.append(Automation.Step(wallpaperID: item.id, seconds: 600))
            seedDefaults()
            if mode == .clock, steps.count == 1 {
                steps[0].startMinute = 8 * 60
                steps[0].endMinute = 20 * 60
            }
        }
    }

    // MARK: - Steps

    private static let durations = [10, 30, 60, 300, 900, 1800, 3600, 7200, 21600]

    @ViewBuilder private func stepRow(_ step: Automation.Step) -> some View {
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(width: 16)
                Color.black
                    .frame(width: 72, height: 41)
                    .overlay {
                        if let item = store.item(id: step.wallpaperID) { ThumbImage(item: item) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(store.item(id: step.wallpaperID)?.title ?? "Missing wallpaper")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if mode == .timer {
                    durationControl(index)
                } else {
                    clockControl(index)
                }
                Button {
                    steps.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muroSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove from this automation")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glass(cornerRadius: 12, fill: 0.05, stroke: 0.1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onDrag {
                dragging = step.id
                return NSItemProvider(object: step.id as NSString)
            }
            .onDrop(of: [.text], delegate: StepDropDelegate(
                stepID: step.id, steps: $steps, dragging: $dragging
            ))
        }
    }

    @State private var dragging: String?

    private func durationControl(_ index: Int) -> some View {
        GlassDropdown(width: 150, options: {
            Self.durations.map { seconds in
                MenuOption(
                    title: durationLabel(seconds),
                    checked: steps[index].duration == seconds
                ) { steps[index].seconds = seconds }
            } + [.divider, MenuOption(title: "Custom…") { customFor = steps[index].id }]
        }) {
            pill(icon: "timer", text: durationLabel(steps[index].duration))
        }
        .popover(isPresented: Binding(
            get: { customFor == steps[index].id },
            set: { if !$0 { customFor = nil } }
        )) {
            CustomDurationPicker(seconds: Binding(
                get: { steps[index].duration },
                set: { steps[index].seconds = $0 }
            )) { customFor = nil }
        }
    }

    private func clockControl(_ index: Int) -> some View {
        HStack(spacing: 6) {
            TimeField(minute: Binding(
                get: { steps[index].start },
                set: { steps[index].startMinute = $0 }
            ))
            Text("to")
                .font(.system(size: 11))
                .foregroundStyle(Color.muroSecondary)
            TimeField(minute: Binding(
                get: { steps[index].end },
                set: { steps[index].endMinute = $0 }
            ))
        }
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassCapsule(fill: 0.08, stroke: 0.14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summaryLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if let warning = warningLine {
                    Text(warning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.muroSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !isNew {
                Button {
                    if case .edit(let automation) = target { store.deleteAutomation(automation) }
                    dismiss()
                } label: {
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.danger)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Self.danger.opacity(0.13)))
                        .overlay(Capsule().strokeBorder(Self.danger.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button { save() } label: {
                Text(isNew ? "Create Automation" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            .keyboardShortcut(.defaultAction)
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
            : "Covers \(durationLabel(covered * 60)) of the day"
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

// MARK: - Reordering

/// Timer steps play in order, so the order has to be editable. Drag one row
/// onto another and they swap places, which is the lightest thing that works
/// inside a sheet that is already scrolling.
private struct StepDropDelegate: DropDelegate {
    let stepID: String
    @Binding var steps: [Automation.Step]
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != stepID,
              let from = steps.firstIndex(where: { $0.id == dragging }),
              let to = steps.firstIndex(where: { $0.id == stepID })
        else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            steps.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Small controls

/// Hours and minutes, typed or stepped. A native `DatePicker` here would drag
/// the system's light control chrome into a dark sheet.
struct TimeField: View {
    @Binding var minute: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(clockLabel(minute))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 62)
            VStack(spacing: 0) {
                stepper("chevron.up", by: 15)
                stepper("chevron.down", by: -15)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .glassCapsule(fill: 0.08, stroke: 0.14)
    }

    private func stepper(_ icon: String, by delta: Int) -> some View {
        Button {
            minute = normalizedMinute(minute + delta)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 11)
        }
        .buttonStyle(.plain)
    }
}

/// Any number of seconds, minutes or hours, for the durations the fixed list
/// does not cover.
struct CustomDurationPicker: View {
    @Binding var seconds: Int
    var done: () -> Void

    @State private var amount = 1
    @State private var unit = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom duration")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                TextField("", value: $amount, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glass(cornerRadius: 8, fill: 0.07, stroke: 0.13)
                CapsuleSegments(
                    options: [("sec", "1"), ("min", "60"), ("hr", "3600")],
                    selection: Binding(
                        get: { String(unit) },
                        set: { unit = Int($0) ?? 60 }
                    )
                )
            }
            Button {
                seconds = min(max(amount * unit, 10), 86_400)
                done()
            } label: {
                Text("Set \(durationLabel(min(max(amount * unit, 10), 86_400)))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 260)
        .background(Color(hex: 0x14171D))
        .onAppear {
            if seconds % 3600 == 0 && seconds >= 3600 { amount = seconds / 3600; unit = 3600 }
            else if seconds % 60 == 0 && seconds >= 60 { amount = seconds / 60; unit = 60 }
            else { amount = seconds; unit = 1 }
        }
    }
}
