import ShawnCore
import SwiftUI

private func stepNumber(_ index: Int) -> String {
    String(format: "%02d", index + 1)
}

// MARK: - Welcome: one toggle per step

struct WelcomeStepList: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    row(step, index: index)
                }
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.m)
        }
        .edgeFade(top: 4, bottom: 14)
    }

    private func row(_ step: PlannedStep, index: Int) -> some View {
        let enabled = model.isEnabled(step)
        let selected = model.selectedItemCount(in: step)
        return Toggle(isOn: Binding(get: { enabled }, set: { model.setStep(step, enabled: $0) })) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(stepNumber(index))
                    .foregroundStyle(palette.faint.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.config.title)
                        .font(Theme.mono(Theme.Size.body, .semibold))
                        .foregroundStyle(enabled ? palette.text.color : palette.dim.color)
                    if let subtitle = step.config.subtitle {
                        Text(subtitle)
                            .font(Theme.mono(Theme.Size.small))
                            .foregroundStyle(palette.dim.color.opacity(enabled ? 1 : 0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Text(enabled ? Format.count(selected, "item") : "off")
                    .font(Theme.mono(Theme.Size.small))
                    .foregroundStyle(enabled ? palette.dim.color : palette.faint.color)
                    .monospacedDigit()
            }
            .font(Theme.mono(Theme.Size.body))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(TerminalCheckboxStyle())
        .disabled(!model.isSelectionEditable)
        .accessibilityLabel("Step \(index + 1): \(step.config.title)")
        .accessibilityValue(enabled ? "\(selected) items" : "off")
    }
}

// MARK: - Running: live status per step, the current step's items expanded

struct RunningStepList: View {
    @Environment(\.motionEnabled) private var motionEnabled
    let model: InstallerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                StepStatusRows(model: model)
                    .padding(.vertical, Theme.Space.s)
            }
            .edgeFade(top: 8, bottom: 14)
            .onChange(of: model.currentItemID) { _, itemID in
                guard let target = itemID ?? model.currentStepID else { return }
                if motionEnabled {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                } else {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onAppear {
                if let target = model.currentItemID ?? model.currentStepID { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

/// One row per step with its live status, plus the item rows worth seeing under it.
struct StepStatusRows: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, index: index)
                ForEach(visibleItems(of: step)) { item in
                    itemRow(item)
                }
            }
        }
    }

    /// The current step shows every item; finished steps show only what went wrong or needs a look,
    /// including the item a STOP interrupted.
    private func visibleItems(of step: PlannedStep) -> [PlannedItem] {
        let enabled = step.items.filter { model.status(of: $0) != .disabled }
        if step.id == model.currentStepID && model.phase == .running { return enabled }
        return enabled.filter {
            switch model.status(of: $0) {
            case .failed, .needsAttention, .cancelled: return true
            default: return false
            }
        }
    }

    private func stepRow(_ step: PlannedStep, index: Int) -> some View {
        let status = model.status(of: step)
        let isCurrent = step.id == model.currentStepID && model.phase == .running
        let progress = model.progress(of: step)
        let look = model.look(of: step)
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            StatusGlyph(look: look)
            Text(stepNumber(index))
                .foregroundStyle(palette.faint.color)
            Text(step.config.title)
                .fontWeight(isCurrent ? .bold : .regular)
                .foregroundStyle(status == .disabled ? palette.faint.color : (isCurrent ? palette.text.color : palette.text.color.opacity(0.85)))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            Text(status == .disabled ? "off" : "\(progress.finished)/\(progress.total)")
                .foregroundStyle(isCurrent ? palette.pink.color : palette.faint.color)
                .monospacedDigit()
        }
        .font(Theme.mono(Theme.Size.body))
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(alignment: .leading) {
            if isCurrent {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(palette.pink.color.opacity(0.09))
                    Rectangle().fill(palette.pink.color).frame(width: 2)
                }
            }
        }
        .id(step.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1): \(step.config.title)")
        .accessibilityValue(status == .disabled ? "off" : "\(look.label), \(progress.finished) of \(progress.total) items finished")
    }

    private func itemRow(_ item: PlannedItem) -> some View {
        let status = model.status(of: item)
        let look = model.look(of: item)
        let isCurrent = item.id == model.currentItemID
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            StatusGlyph(look: look, size: Theme.Size.small)
            Text(item.title)
                .foregroundStyle(isCurrent ? palette.text.color : palette.text.color.opacity(status.isFinished ? 0.7 : 0.55))
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = look.detail ?? (isCurrent ? look.label : nil) {
                // Whole if it fits, else left out, so a long title never cuts it to a fragment such as
                // "already insta…". The glyph in front of the row still says how the item ended.
                ViewThatFits(in: .horizontal) {
                    Text(detail).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .foregroundStyle(palette.color(look.tone == .mint ? .faint : look.tone).opacity(0.85))
                .lineLimit(1)
                .layoutPriority(0.5)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.mono(Theme.Size.small))
        .padding(.leading, 26)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .id(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue([look.label, look.detail].compactMap { $0 }.joined(separator: ": "))
    }
}

// MARK: - Customize: every item, with checkboxes

struct CustomizeList: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    section(step, index: index)
                }
            }
            .padding(.vertical, Theme.Space.m)
            .padding(.trailing, Theme.Space.s)
        }
        .edgeFade()
    }

    /// Wide enough for the longest kind name in this config (within reason), plus a gap.
    private var kindColumnWidth: CGFloat {
        let longest = model.steps.flatMap(\.items).map(\.config.kind.count).max() ?? 4
        return CGFloat(min(16, max(4, longest)) + 2) * Theme.Size.small * Theme.monoAdvance
    }

    private func section(_ step: PlannedStep, index: Int) -> some View {
        let enabled = model.isEnabled(step)
        return VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { enabled }, set: { model.setStep(step, enabled: $0) })) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text(stepNumber(index)).foregroundStyle(palette.faint.color)
                    Text(step.config.title.uppercased())
                        .font(Theme.mono(Theme.Size.body, .bold))
                        .tracking(1.2)
                        .foregroundStyle(enabled ? palette.pink.color : palette.dim.color)
                    if let subtitle = step.config.subtitle {
                        Text(subtitle)
                            .font(Theme.mono(Theme.Size.small))
                            .foregroundStyle(palette.dim.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text(enabled ? "\(model.selectedItemCount(in: step))/\(step.items.count) selected" : "step off")
                        .font(Theme.mono(Theme.Size.small))
                        .foregroundStyle(palette.faint.color)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(TerminalCheckboxStyle())
            .accessibilityLabel("Step \(index + 1): \(step.config.title)")

            ForEach(step.items) { item in
                itemRow(item, stepEnabled: enabled)
            }
            .padding(.leading, 30)
        }
    }

    private func itemRow(_ item: PlannedItem, stepEnabled: Bool) -> some View {
        let isOn = model.isEnabled(item)
        return Toggle(isOn: Binding(get: { isOn }, set: { model.setItem(item, enabled: $0) })) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(item.config.kind)
                    .foregroundStyle(palette.faint.color)
                    .frame(width: kindColumnWidth, alignment: .leading)
                    .lineLimit(1)
                Text(item.title)
                    .foregroundStyle(isOn && stepEnabled ? palette.text.color : palette.dim.color)
                    .lineLimit(1)
                    .layoutPriority(1)
                if item.config.optional {
                    Chip(text: "OPTIONAL", tone: .cyan, compact: true)
                }
                if let note = item.config.note {
                    Text("# \(note)")
                        .foregroundStyle(palette.yellow.color.opacity(0.8))
                        .lineLimit(1)
                } else if let subtitle = item.subtitle {
                    Text(subtitle)
                        .foregroundStyle(palette.faint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.mono(Theme.Size.small))
            .padding(.vertical, 1)
        }
        .toggleStyle(TerminalCheckboxStyle())
        .disabled(!stepEnabled)
        .accessibilityLabel(item.title + (item.config.optional ? ", optional" : ""))
        .accessibilityHint(stepEnabled ? "" : "Switch the step on to choose its items")
    }
}
