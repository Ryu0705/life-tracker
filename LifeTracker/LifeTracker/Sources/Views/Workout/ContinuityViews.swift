import SwiftUI

/// トレーニング画面の週帯の上の 1 行: 「🔥 45日  ◔ 今週 2/4 · あと2回」。タップで週の目標回数を変える。
/// 目標が未設定なら設定への入口だけを出す (docs/continuity-design.md)
struct ContinuityRow: View {
    let status: ContinuityStatus?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let status {
                    StreakLabel(days: status.streakDays, font: .subheadline.bold())
                    WeekRing(status: status, lineWidth: 3)
                        .frame(width: 18, height: 18)
                    Text(Self.weekText(status))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                } else {
                    Label("週の目標回数を決める", systemImage: "flame")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.map { "連続 \($0.streakDays)日、\(Self.weekText($0))。目標回数を変更" } ?? "週の目標回数を決める")
    }

    static func weekText(_ status: ContinuityStatus) -> String {
        let head = "今週 \(status.weekCount)/\(status.weekTarget)"
        if status.isWeekAchieved { return head + " · 達成" }
        return head + " · あと\(status.remaining)回"
    }
}

/// 週の目標回数 (1〜7)。今週から有効で、過去の週は当時の目標のまま
struct WeeklyGoalSheet: View {
    @ObservedObject var continuity: ContinuityStore
    let today: Date

    @Environment(\.dismiss) private var dismiss
    @State private var target: Int
    @State private var message: String?
    @State private var isSaving = false

    private let current: Int?

    init(continuity: ContinuityStore, today: Date) {
        self.continuity = continuity
        self.today = today
        current = continuity.currentTarget
        _target = State(initialValue: continuity.currentTarget ?? 3)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("週の目標", selection: $target) {
                        ForEach(1...7, id: \.self) { Text("週 \($0) 回").tag($0) }
                    }
                    .pickerStyle(.wheel)
                } footer: {
                    if let message {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("今週から適用します。週 \(target) 回に届いていれば、休みの日があっても連続は途切れません。月〜日で \(target) 回に届かずに週が終わると、連続が 0 に戻ります。")
                    }
                }
            }
            .navigationTitle("週の目標回数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            if let error = await continuity.setWeeklyTarget(target, today: today) {
                                message = "保存できませんでした: \(error.localizedDescription)"
                                isSaving = false
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving || target == current)
                }
            }
        }
    }
}

/// 分析画面のヒートマップ: 直近 26 週 (列) × 月〜日 (行)。色の濃さはその日のボリューム (5 段階)
struct TrainingHeatmap: View {
    /// 日 → ボリューム (記録はあるがボリュームが出ない種目だけの日は 0 より大きい最小値で渡す)
    let volumes: [Date: Double]
    let today: Date
    let calendar: Calendar

    static let weekCount = 26

    var body: some View {
        let currentWeek = Continuity.weekStart(containing: today, calendar: calendar)
        let weeks = (0..<Self.weekCount).reversed().map { calendar.date(byAdding: .day, value: -7 * $0, to: currentWeek)! }
        let thresholds = Self.thresholds(Array(volumes.values))
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let cell = (geo.size.width - gap * CGFloat(Self.weekCount - 1)) / CGFloat(Self.weekCount)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(weeks, id: \.self) { week in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { offset in
                                let day = calendar.date(byAdding: .day, value: offset, to: week)!
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day > today ? Color.clear : Self.color(level: Self.level(volumes[day], thresholds: thresholds)))
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .aspectRatio(CGFloat(Self.weekCount) / 7, contentMode: .fit)
            HStack(spacing: 4) {
                Text(WorkoutSummary.dayLabel(weeks.first!, calendar: calendar))
                Spacer()
                Text("少")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(level: level)).frame(width: 10, height: 10)
                }
                Text("多")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("直近\(Self.weekCount)週のトレーニング \(volumes.keys.filter { $0 <= today }.count)日")
    }

    /// 記録がある日のボリュームの 4 分位 (25/50/75%)。日ごとの差を相対的に見せる
    static func thresholds(_ values: [Double]) -> [Double] {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    /// 0 = 記録なし、1〜4 = ボリュームの分位
    static func level(_ volume: Double?, thresholds: [Double]) -> Int {
        guard let volume, volume > 0 else { return 0 }
        return 1 + thresholds.filter { volume >= $0 }.count
    }

    static func color(level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Color.orange.opacity([0, 0.35, 0.55, 0.75, 1][min(level, 4)])
    }
}
