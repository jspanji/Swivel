import SwiftUI

/// Main popover content — the successor to the old NSMenu. Same
/// information architecture, one glass surface:
///
///   ┌──────────────────────────────┐
///   │ ⚠ status banner (if degraded)│
///   │ ▣ Personal          [Update] │   header: active account
///   │ ──────────────────────────── │
///   │ Usage · 5-hour window        │
///   │ ▣ Personal    ▓▓▓░ 73%  ⌘⌥1  │   account rows (shared with widget)
///   │ ▣ Work        ░░░░  ✓   ⌘⌥2  │
///   │ ↩ Last: Work            ⌘⌥`  │
///   │ ＋ Add Account…              │
///   │ ──────────────────────────── │
///   │ ● operational           ⚙︎   │   footer
///   └──────────────────────────────┘
struct PopoverRootView: View {
    @ObservedObject var model: SwivelViewModel
    let actions: UIActions

    /// The card narrows in live mode: live moves the gauges onto per-window
    /// 5h/7d sub-lines, leaving the name line sparse, so the popover can be
    /// tighter (and match the overlay's width). Non-live keeps the gauge + %
    /// + controls on the name line and needs the extra room, or account names
    /// truncate. The popover already reshapes its height when you toggle the
    /// mode, so this width change rides along with that.
    private var popoverWidth: CGFloat { model.liveUsageEnabled ? 280 : 320 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = model.serviceStatus,
               status.level != .none, status.level != .unknown {
                statusBanner(status)
            }

            if model.accounts.isEmpty {
                onboarding
            } else {
                accountSection
            }

            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: popoverWidth)
        // The real glass is a behind-window NSVisualEffectView installed by
        // StatusItemController (a SwiftUI blur material can't blur through
        // the clear popover, and would just gray out flat). We layer only a
        // legibility scrim on top so the muted row text stays readable over
        // a bright wallpaper — same fix as the overlay.
        .glassLegibilityScrim()
    }

    // MARK: - Status banner

    private func statusBanner(_ status: ClaudeStatusSnapshot) -> some View {
        Button(action: actions.openStatusPage) {
            HStack(spacing: 8) {
                Circle()
                    .fill(MenuStyle.statusColor(for: status.level))
                    .frame(width: 8, height: 8)
                Text("Claude: \(status.description)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MenuStyle.statusColor(for: status.level).opacity(0.12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the Claude status page")
    }

    // MARK: - Accounts

    /// Section header: usage-mode label on the left, the re-save control on
    /// the right (only when there's an active account). The active account
    /// itself is identified by the bold ✓ row below — no separate header
    /// echoing it.
    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text(model.liveUsageEnabled ? "Live usage · 5h / 7d" : "Usage · 5-hour window")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if let active = model.activeName {
                Button(action: actions.updateCurrent) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Re-save \(active)'s snapshot from the current Claude session")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader

            ForEach(model.accounts) { account in
                AccountRowView(account: account, style: .popover, actions: actions)
                    .padding(.horizontal, 8)
            }

            if let prev = model.previousName,
               prev != model.activeName,
               model.accounts.contains(where: { $0.name == prev }) {
                flipRow(prev)
            }

            addAccountRow
                .padding(.top, 2)
                .padding(.bottom, 8)
        }
    }

    private func flipRow(_ prev: String) -> some View {
        Button(action: actions.flip) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Last: \(prev)")
                    .font(.system(size: 12))
                Text("⌘⌥`")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .padding(.horizontal, 8)
        .help("Flip back to \(prev)")
    }

    private var addAccountRow: some View {
        Button(action: actions.addAccount) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Add Account…")
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .padding(.horizontal, 8)
        .help("Save the current Claude session as a new account")
    }

    // MARK: - Onboarding (zero accounts)

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to Swivel")
                .font(.system(size: 13, weight: .bold))
            Text("Quickly switch between Claude accounts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Sign into your Claude account")
                Text("2. Save this session as an account")
                Text("3. Sign out, sign into another, save that too")
                Text("Then: ⌘⌥1 / ⌘⌥2 to switch any time")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Button("Save this session as an account…", action: actions.addAccount)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: actions.openStatusPage) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(footerStatusColor)
                        .frame(width: 7, height: 7)
                    Text(footerStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the Claude status page")

            Spacer()

            settingsMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footerStatusColor: Color {
        guard let status = model.serviceStatus else { return Color(.systemGray) }
        return MenuStyle.statusColor(for: status.level)
    }

    private var footerStatusText: String {
        guard let status = model.serviceStatus else { return "Checking Claude status…" }
        switch status.level {
        case .none: return "Claude service operational"
        case .minor, .major, .critical: return "Claude: \(status.description)"
        case .maintenance: return "Claude: Maintenance in progress"
        case .unknown: return "Claude: Status unavailable"
        }
    }

    private var settingsMenu: some View {
        Menu {
            if model.loginItemAvailable {
                Button {
                    actions.toggleLoginItem()
                } label: {
                    checkedLabel("Launch at Login", checked: model.loginItemEnabled)
                }
            }
            Button {
                actions.toggleWidget()
            } label: {
                checkedLabel("Show Usage Overlay", checked: model.widgetVisible)
            }
            Button {
                actions.toggleLiveUsage()
            } label: {
                checkedLabel("Live Usage — Experimental", checked: model.liveUsageEnabled)
            }
            Divider()
            Button("Check for Updates…", action: actions.checkForUpdates)
            Button("Help & Documentation", action: actions.help)
            Button("About Swivel", action: actions.about)
            Divider()
            Button("Quit Swivel", action: actions.quit)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private func checkedLabel(_ title: String, checked: Bool) -> some View {
        // SwiftUI Menu on macOS 13 has no Toggle checkmark rendering for
        // borderless menus; a literal check suffix reads the same.
        Label {
            Text(title)
        } icon: {
            if checked { Image(systemName: "checkmark") }
        }
    }
}

/// Row-shaped button feedback: subtle rounded highlight on hover, a bit
/// stronger while pressed. Matches the NSMenu row affordance closely
/// enough that the popover doesn't feel foreign next to real menus.
struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // @State needs a real View for storage — a ButtonStyle struct
        // isn't installed in the hierarchy, so hover state lives in
        // this inner body view instead.
        HighlightBody(configuration: configuration)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.12)
                                : hovering ? Color.primary.opacity(0.08) : .clear
                        )
                )
                .onHover { hovering = $0 }
        }
    }
}
