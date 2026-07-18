import SwiftUI
import VoxglassCore

struct ListeningStatsView: View {
    @ObservedObject private var storeManager = StoreManager.shared
    @EnvironmentObject private var stats: ListeningStatsStore
    @Environment(\.dismiss) private var dismiss

    @State private var totalTime: TimeInterval = 0
    @State private var streak = 0
    @State private var dailyBars: [DayBar] = []
    @State private var topAuthors: [(term: String, seconds: TimeInterval)] = []
    @State private var topSubjects: [(term: String, seconds: TimeInterval)] = []
    @State private var loaded = false
    @State private var showPaywall = false

    struct DayBar: Identifiable {
        let id = UUID()
        let label: String
        let seconds: TimeInterval
    }

    var body: some View {
        ZStack {
            VoxglassBackground()
            if ProFeature.isEnabled(.listeningStats) {
                content
            } else {
                lockedTeaser
            }
        }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .paywallSheet(isPresented: $showPaywall)
        .task(id: storeManager.isPro) {
            guard ProFeature.isEnabled(.listeningStats), !loaded else { return }
            await load()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline
                weeklyChart
                if !topAuthors.isEmpty {
                    termsCard(title: "Top Authors", terms: topAuthors)
                }
                if !topSubjects.isEmpty {
                    termsCard(title: "Top Genres", terms: topSubjects)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var headline: some View {
        HStack(spacing: 12) {
            statTile(value: durationString(totalTime), label: "Total time")
            statTile(value: "\(streak)", label: streak == 1 ? "day streak" : "days streak")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .scaledFont(size: 24, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text(label)
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassSurface(cornerRadius: 16)
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 7 days")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink)
            let maxSeconds = max(dailyBars.map(\.seconds).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(dailyBars) { bar in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(height: max(4, CGFloat(bar.seconds / maxSeconds) * 120))
                        Text(bar.label)
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(Palette.ink3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
        .padding(15)
        .glassSurface(cornerRadius: 16)
    }

    private func termsCard(title: String, terms: [(term: String, seconds: TimeInterval)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink)
            ForEach(terms.indices, id: \.self) { index in
                HStack {
                    Text(terms[index].term.capitalized)
                        .scaledFont(size: 13)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                    Spacer()
                    Text(durationString(terms[index].seconds))
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 16)
    }

    private var lockedTeaser: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.fill")
                .scaledFont(size: 44)
                .foregroundStyle(Palette.brass)
            Text("Listening Stats")
                .scaledFont(size: 20, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("See your total listening time, daily streaks, and your most-heard authors and genres. A Voxglass Pro feature.")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button {
                showPaywall = true
            } label: {
                Text("Unlock Pro")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Color(hex: 0x221503))
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Palette.brass, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pro.lock.listeningStats")
        }
        .padding(24)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "0m" : TimeFormatting.compactDuration(seconds)
    }

    private func load() async {
        totalTime = await stats.totalTime()
        streak = await stats.currentStreak()
        topAuthors = await stats.topAuthors(limit: 5)
        topSubjects = await stats.topSubjects(limit: 5)
        dailyBars = await buildWeeklyBars()
        loaded = true
    }

    private func buildWeeklyBars() async -> [DayBar] {
        let calendar = Calendar.current
        let now = Date()
        let totals = await stats.dailyTotals(days: 7, calendar: calendar, now: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return (0..<7).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
            return DayBar(label: formatter.string(from: day), seconds: totals[day] ?? 0)
        }
    }
}
