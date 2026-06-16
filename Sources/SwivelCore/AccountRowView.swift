import SwiftUI

/// One account row, shared by the popover and the desktop widget so the
/// two surfaces render usage identically. Layout mirrors the retired
/// `UsageHeaderView` two-line format:
///
///     ▣ Personal               ▓▓▓▓▓▓░░░░   73%   ⌘⌥1
///       Claude Max 5x · 1 msg left · resets in 2h 47m
///
/// The row body is display-only; the trailing switch button is the sole
/// click-to-switch affordance. Switching quits and relaunches Claude, so it
/// must be a deliberate target — never a stray click in the usage area
/// (especially on the floating overlay). The active row shows a ✓ and no
/// switch button. The `widget` style drops the hover overflow menu and
/// shortcut hints — the widget is a glanceable surface, management lives in
/// the popover.
struct AccountRowView: View {
    enum Style {
        case popover
        case widget
    }

    let account: AccountDisplay
    let style: Style
    let actions: UIActions

    @State private var hovering = false

    private var stale: Bool { UsageFormatting.isStale(account.usage) }
    private var dim: Double { stale ? UsageFormatting.staleDimming : 1.0 }

    var body: some View {
        // Display-only row. Switching quits and relaunches Claude, so it has
        // to be a deliberate target (`switchButton`), never a click anywhere
        // in the usage area — a stray click on the floating overlay must not
        // blow away a session. Hover still scopes the row (locates its switch
        // and "…" controls).
        rowContent
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
            .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if hovering && !account.isActive && style == .popover {
            return Color.primary.opacity(0.08)
        }
        if account.isActive && style == .widget {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    private var isWidget: Bool { style == .widget }

    private var rowContent: some View {
        // Outer HStack so the ✓/⇄ marker centers vertically across the whole
        // row: in live mode a row is three lines tall (name + 5h + 7d), and
        // the marker should sit at the row's middle, not pinned to the top
        // name line. The text lines stack on the left; the marker is a
        // centered trailing column (HStack defaults to .center alignment).
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: isWidget ? 0 : 2) {
                primaryLine
                if let live = account.liveUsage {
                    // Two independent windows, each with its own reset.
                    windowLine("5h", live.fiveHour)
                    windowLine("7d", live.sevenDay)
                } else if let usage = account.usage {
                    Text(UsageFormatting.secondaryLine(usage: usage, isActive: account.isActive))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .opacity(dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 17)   // align under name, past swatch
                }
            }

            statusActionSlot
        }
        .padding(.vertical, isWidget ? 2 : 4)
        .padding(.horizontal, 6)
    }

    /// One window's line in live mode — label, mini gauge, %, and its own
    /// reset. Fixed-width columns so 5h and 7d line up under each other and
    /// across rows. Mirrors how claude.ai's own usage panel lists windows.
    @ViewBuilder
    private func windowLine(_ label: String, _ w: LiveUsage.Window?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .leading)
            miniGauge(w?.utilization)
            Text(w.map { "\(Int(($0.utilization * 100).rounded()))%" } ?? "—")
                .foregroundStyle(w.map { UsageFormatting.usageColor($0.utilization) } ?? Color(.tertiaryLabelColor))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            // Just the countdown, no "resets" label: trailing a % in a usage
            // row, the time already reads as "until reset", and dropping the
            // word keeps it on one line — it was wrapping in the narrow
            // overlay. lineLimit guards against any wrap in edge cases.
            Text(w?.resetsAt.map { UsageFormatting.shortResetDelta(to: $0) } ?? "")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.leading, 17)   // align under name, past swatch
    }

    /// Right side of the name line in live mode: plan tier + an "overage"
    /// chip when active.
    @ViewBuilder
    private func liveTrailingCluster(_ live: LiveUsage) -> some View {
        HStack(spacing: 6) {
            if let tier = UsageFormatting.compactTier(live.tier) {
                Text(tier)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if live.overageActive {
                Text("overage")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(.systemOrange))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(.systemOrange).opacity(0.18)))
            }
        }
    }

    private func miniGauge(_ util: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.quaternaryLabelColor))
                if let u = util, u > 0 {
                    Capsule()
                        .fill(UsageFormatting.usageColor(u))
                        .frame(width: max(geo.size.width * u, 3))
                }
            }
        }
        .frame(width: style == .popover ? 64 : 50, height: 5)
    }

    private var primaryLine: some View {
        HStack(spacing: 8) {
            swatch

            Text(account.name)
                .font(.system(size: 12, weight: account.isActive ? .bold : .regular))
                .foregroundStyle(.primary)
                .opacity(dim)
                .lineLimit(1)
                .truncationMode(.tail)

            // Keyboard shortcut sits right next to the name, like a label.
            // Popover only — the overlay stays glanceable without hints.
            if style == .popover, let hint = account.shortcutHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // In live mode the per-window lines below carry the gauges, so
            // the name line shows the plan + overage instead. Otherwise keep
            // the single 5h gauge.
            if let live = account.liveUsage {
                liveTrailingCluster(live)
            } else if account.usage != nil {
                gauge
                trailingLabel
            } else {
                Text("no data")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if style == .popover {
                trailingAccessory
            }
        }
    }

    /// Trailing status/action marker: ✓ for the active account, the switch
    /// button for every other row. Both occupy the same fixed-width slot,
    /// vertically centered across the row by `rowContent`'s outer HStack, so
    /// the marker forms a clean aligned column down the list no matter how
    /// many usage lines a row carries.
    @ViewBuilder
    private var statusActionSlot: some View {
        if account.isActive {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .help("\(account.name) — active account")
        } else {
            switchButton
        }
    }

    /// Explicit, always-visible switch control for inactive rows. Switching
    /// quits and relaunches Claude, so it's a deliberate target rather than
    /// the whole row. Reuses the popover's row-button hover highlight so it
    /// reads as a control, calmly, at rest.
    private var switchButton: some View {
        Button {
            actions.switchTo(account.name)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .help("Switch to \(account.name)")
    }

    private var swatch: some View {
        let color = account.colorHex.flatMap { Color(hexString: $0) }
            ?? Color(.systemGray)
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
            .frame(width: 9, height: 9)
    }

    /// Capsule gauge for the non-live (local cache) path — track always
    /// drawn; fill only when the account is approaching/over its limit
    /// (signal-by-absence, ported rule). Live mode uses `miniGauge` per
    /// window instead.
    private var gauge: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.quaternaryLabelColor))
                if let usage = account.usage,
                   let fraction = UsageFormatting.gaugeFillFraction(usage) {
                    Capsule()
                        .fill(usage.status == .limitReached
                              ? Color(.systemRed)
                              : UsageFormatting.usageColor(fraction))
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
                        .opacity(dim)
                }
            }
        }
        .frame(width: style == .popover ? 72 : 56, height: 6)
    }

    private var trailingLabel: some View {
        let label = UsageFormatting.trailingLabel(account.usage)
        return Text(label.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(label.color)
            .opacity(dim)
            .frame(width: 34, alignment: .trailing)
            .monospacedDigit()
    }

    /// Far-right slot for the "…" management menu, revealed on hover.
    /// Reserves a fixed width even at rest so showing the menu doesn't shift
    /// the row's other columns. (The keyboard shortcut now sits next to the
    /// name instead of here.)
    @ViewBuilder
    private var trailingAccessory: some View {
        ZStack(alignment: .trailing) {
            if hovering {
                manageMenu
            }
        }
        .frame(width: 24, alignment: .trailing)
    }

    private var manageMenu: some View {
        Menu {
            Button("Rename…") { actions.rename(account.name) }

            Menu("Change Color") {
                Button {
                    actions.setColor(account.name, nil)
                } label: {
                    labelWithCheck("None", checked: account.colorHex == nil)
                }
                Divider()
                ForEach(MenuStyle.colorPresets, id: \.hex) { preset in
                    Button {
                        actions.setColor(account.name, preset.hex)
                    } label: {
                        Label {
                            labelWithCheck(
                                preset.name,
                                checked: account.colorHex?.uppercased() == preset.hex.uppercased()
                            )
                        } icon: {
                            Image(nsImage: MenuStyle.colorSwatch(hex: preset.hex) ?? NSImage())
                        }
                    }
                }
            }

            if !account.backups.isEmpty {
                Menu("Restore Backup") {
                    ForEach(account.backups, id: \.directoryName) { backup in
                        Button(UsageFormatting.relativeTimeLabel(for: backup.date)) {
                            actions.restoreBackup(account.name, backup.directoryName)
                        }
                    }
                }
            }

            Divider()

            Button("Delete…", role: .destructive) { actions.delete(account.name) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func labelWithCheck(_ title: String, checked: Bool) -> Text {
        checked ? Text("\(title) ✓") : Text(title)
    }
}
