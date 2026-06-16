import SwiftUI

/// Content of the floating desktop widget — a glanceable glass card with
/// one row per account, sharing `AccountRowView` with the popover so the
/// two surfaces read identically. Management actions live in the popover;
/// the widget keeps only switch-on-click and a small context menu.
struct WidgetRootView: View {
    @ObservedObject var model: SwivelViewModel
    let actions: UIActions
    let onToggleAlwaysOnTop: () -> Void
    let onHide: () -> Void

    private static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleBar

            ForEach(model.accounts) { account in
                AccountRowView(account: account, style: .widget, actions: actions)
            }

            if model.accounts.isEmpty {
                Text("No accounts yet — add one from the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            } else if !model.liveUsageEnabled {
                // The HUD is most useful with live, always-on numbers. When
                // it's off we only have the local cache (pressure-only), so
                // nudge toward enabling it — one tap, routes through the
                // same confirmation as the popover toggle.
                Button(action: actions.toggleLiveUsage) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").font(.system(size: 8))
                        Text("Turn on Live Usage (experimental)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: Self.width, alignment: .leading)
        // Legibility backing over the behind-window glass: without it the
        // muted row text washes out against a bright wallpaper in light
        // mode. cornerRadius matches the card so the scrim clips cleanly.
        .glassLegibilityScrim(cornerRadius: 14)
        // Glass + corner rounding live in DesktopWidgetController's
        // NSVisualEffectView (behind-window blending — SwiftUI materials
        // can't blur through a clear panel). Only the hairline edge is
        // drawn here.
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .contextMenu {
            Button {
                onToggleAlwaysOnTop()
            } label: {
                if model.widgetAlwaysOnTop {
                    Label("Always on Top", systemImage: "checkmark")
                } else {
                    Text("Always on Top")
                }
            }
            Divider()
            Button("Hide Overlay", action: onHide)
        }
    }

    /// Title doubles as the drag handle — the rows below are buttons, so
    /// `isMovableByWindowBackground` only gets traction up here and in
    /// the card's padding.
    private var titleBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(model.liveUsageEnabled ? "Live usage" : "Usage")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if model.liveUsageEnabled {
                Text("· 5h / 7d")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Click to pin/unpin (always-on-top on/off).
            Button(action: onToggleAlwaysOnTop) {
                Image(systemName: model.widgetAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(model.widgetAlwaysOnTop ? Color.secondary : Color(.tertiaryLabelColor))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.widgetAlwaysOnTop ? "Unpin — drop behind windows" : "Pin on top")
            // Click to dismiss the overlay.
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabelColor))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide overlay")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }

    private var statusColor: Color {
        MenuStyle.statusColor(for: model.serviceStatus?.level)
    }
}
