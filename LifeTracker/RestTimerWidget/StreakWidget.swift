import SwiftUI
import WidgetKit

/// ホーム画面の継続ウィジェット (小: 連続＋今週のリング / 中: ＋今週 7 日の点)。
/// アプリが App Group に置いた元データから、0:00 ごとに計算し直す (アプリを開かなくても日付と週の切り替わりで進む・途切れる)
struct StreakEntry: TimelineEntry {
    let date: Date
    /// nil = 目標未設定 (またはアプリ未起動)
    let status: ContinuityStatus?
}

struct StreakProvider: TimelineProvider {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func entry(at date: Date, snapshot: ContinuityShare.Snapshot?) -> StreakEntry {
        guard let snapshot else { return StreakEntry(date: date, status: nil) }
        let status = Continuity.status(trainingDays: Set(snapshot.trainingDays), goals: snapshot.goals, today: date, calendar: calendar)
        return StreakEntry(date: date, status: status)
    }

    func placeholder(in context: Context) -> StreakEntry {
        StreakEntry(date: Date(), status: ContinuityStatus(streakDays: 45, weekCount: 2, weekTarget: 4,
                                                           weekDone: [true, false, true, false, false, false, false], daysLeftInWeek: 4))
    }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.entry(at: Date(), snapshot: ContinuityShare.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        let snapshot = ContinuityShare.load()
        let now = Date()
        let today = Self.calendar.startOfDay(for: now)
        let midnights = (1...7).map { Self.calendar.date(byAdding: .day, value: $0, to: today)! }
        let entries = [Self.entry(at: now, snapshot: snapshot)] + midnights.map { Self.entry(at: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct StreakWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StreakEntry

    var body: some View {
        Group {
            if let status = entry.status {
                switch family {
                case .systemMedium: medium(status)
                default: small(status)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "flame")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("アプリで週の目標回数を設定")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func small(_ status: ContinuityStatus) -> some View {
        VStack(spacing: 8) {
            StreakLabel(days: status.streakDays, font: .title2.bold())
            ZStack {
                WeekRing(status: status, lineWidth: 7)
                Text("\(status.weekCount)/\(status.weekTarget)")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 64, height: 64)
            Text(weekCaption(status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func medium(_ status: ContinuityStatus) -> some View {
        HStack(spacing: 16) {
            ZStack {
                WeekRing(status: status, lineWidth: 8)
                Text("\(status.weekCount)/\(status.weekTarget)")
                    .font(.title3.bold().monospacedDigit())
            }
            .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 8) {
                StreakLabel(days: status.streakDays, font: .title2.bold())
                WeekDots(status: status, size: 16)
                Text(weekCaption(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func weekCaption(_ status: ContinuityStatus) -> String {
        if status.isWeekAchieved { return "今週は達成" }
        return "今週あと\(status.remaining)回 · 残り\(status.daysLeftInWeek)日"
    }
}

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StreakWidget", provider: StreakProvider()) { entry in
            StreakWidgetView(entry: entry)
        }
        .configurationDisplayName("トレーニングの継続")
        .description("連続日数と、今週の目標回数までの進み具合")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
