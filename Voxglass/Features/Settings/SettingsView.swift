import SwiftUI

struct SettingsView: View {
    var body: some View {
        VoxglassScreen(title: "Settings") {
            VStack(alignment: .leading, spacing: 16) {
                settingsGroup("Playback") {
                    SettingsRow(icon: "speaker.wave.2.fill", title: "Background Audio", detail: "Enabled")
                    SettingsRow(icon: "airplayaudio", title: "AirPlay", detail: "System controls")
                }

                settingsGroup("Data & Privacy") {
                    SettingsRow(icon: "person.crop.circle.badge.xmark", title: "Accounts", detail: "None")
                    SettingsRow(icon: "chart.bar.xaxis", title: "Analytics", detail: "None")
                    SettingsRow(icon: "network.slash", title: "Network", detail: "Archive sources only")
                }

                settingsGroup("Open Source") {
                    SettingsRow(icon: "doc.text.fill", title: "License", detail: "GPLv3")
                    SettingsRow(icon: "heart.fill", title: "Tip Jar", detail: "Stub")
                    SettingsRow(icon: "info.circle.fill", title: "Version", detail: "0.1.0")
                }
            }
            .padding(.top, 12)
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)
            VStack(spacing: 0) {
                content()
            }
            .glassPanel()
        }
    }
}

private struct SettingsRow: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(VoxglassTheme.accent)
                .frame(width: 28, height: 28)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(VoxglassTheme.ink)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(VoxglassTheme.secondaryInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

