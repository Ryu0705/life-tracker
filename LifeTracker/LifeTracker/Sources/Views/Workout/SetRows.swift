import SwiftUI

/// セット行の値の列。metric_kind ごとに並びが決まる (ウェイト=kg・回 / 自重=回 / 時間=秒 / 有酸素=分・km)
struct SetColumn: Identifiable {
    let title: String
    /// 入力の単位 (値 = 入力 × unit。分は 60、km は 1000)
    let unit: Double
    let keyPath: WritableKeyPath<WorkoutSetInput, Double?>
    /// 入力シートの ± ボタン (小刻み・大刻み)。値の単位 (kg / 回 / 秒 / m) で持つ
    var steps: [(amount: Double, label: String)] = []
    /// 空欄から ± を押したときの値
    var emptyStart: Double = 0

    var id: String { title }

    static func columns(for exercise: Exercise) -> [SetColumn] {
        switch exercise.metricKind {
        case .weightReps: return [weight(for: exercise.equipment), reps]
        case .repsOnly: return [reps]
        case .duration:
            return [SetColumn(title: "秒", unit: 1, keyPath: \.durationSeconds,
                              steps: [(5, "5秒"), (15, "15秒")], emptyStart: 60)]
        case .durationDistance:
            return [SetColumn(title: "分", unit: 60, keyPath: \.durationSeconds,
                              steps: [(60, "1分"), (300, "5分")], emptyStart: 20 * 60),
                    SetColumn(title: "km", unit: 1000, keyPath: \.distanceM,
                              steps: [(100, "0.1km"), (1000, "1km")], emptyStart: 1000)]
        }
    }

    private static func weight(for equipment: Exercise.Equipment?) -> SetColumn {
        let steps = WorkoutLogic.weightSteps(for: equipment)
        return SetColumn(title: "kg", unit: 1, keyPath: \.weight,
                         steps: [(steps.small, "\(WorkoutLogic.formatWeight(steps.small))kg"),
                                 (steps.large, "\(WorkoutLogic.formatWeight(steps.large))kg")],
                         emptyStart: 20)
    }

    private static let reps = SetColumn(title: "回", unit: 1, keyPath: \.repsValue,
                                        steps: [(1, "1回"), (5, "5回")], emptyStart: 10)

    func display(_ value: Double?) -> String {
        value.map { NumberField.plain($0 / unit) } ?? "—"
    }
}

/// 列を Double? に揃えるための橋渡し (reps / duration_sec は整数)
extension WorkoutSetInput {
    var repsValue: Double? {
        get { reps.map(Double.init) }
        set { reps = newValue.map { Int($0.rounded()) } }
    }

    var durationSeconds: Double? {
        get { durationSec.map(Double.init) }
        set { durationSec = newValue.map { Int($0.rounded()) } }
    }
}

enum SetRowLayout {
    static let labelWidth: CGFloat = 28
    static let valueWidth: CGFloat = 64
    static let checkWidth: CGFloat = 44
}

struct SetHeaderRow: View {
    let columns: [SetColumn]

    var body: some View {
        HStack(spacing: 8) {
            Text("セット").frame(width: SetRowLayout.labelWidth + 8, alignment: .leading)
            Text("前回").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { Text($0.title).frame(width: SetRowLayout.valueWidth) }
            Color.clear.frame(width: SetRowLayout.checkWidth, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 記録済みの行 (読み取りのみ。削除はスワイプ、編集は Round 4)
struct CompletedSetRow: View {
    let label: String
    let previous: String?
    let set: WorkoutSet
    let columns: [SetColumn]

    var body: some View {
        let input = WorkoutLogic.input(from: set, keepWarmup: true)
        HStack(spacing: 8) {
            Text(label)
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(set.isWarmup ? .orange : .primary)
                .frame(width: SetRowLayout.labelWidth + 8, alignment: .leading)
            Text(previous ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                Text(column.display(input[keyPath: column.keyPath]))
                    .font(.body.monospacedDigit().bold())
                    .frame(width: SetRowLayout.valueWidth)
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: SetRowLayout.checkWidth, height: 44)
        }
        .listRowBackground(Color.green.opacity(0.12))
    }
}

/// 未保存の行。値は前回で埋まっている。行タップで入力シート、✓ でそのまま記録
struct DraftSetRow: View {
    let label: String
    let previous: String?
    let input: WorkoutSetInput
    let columns: [SetColumn]
    let isSelected: Bool
    let isWriting: Bool
    let onEdit: () -> Void
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(input.isWarmup ? Color.orange : Color.primary)
                        .frame(width: SetRowLayout.labelWidth + 8, alignment: .leading)
                    Text(previous ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns) { column in
                        Text(column.display(input[keyPath: column.keyPath]))
                            .font(.body.monospacedDigit().bold())
                            .foregroundStyle(Color.primary)
                            .frame(width: SetRowLayout.valueWidth, height: 40)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Button(action: onComplete) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .frame(width: SetRowLayout.checkWidth, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isWriting)
            .accessibilityLabel("セット\(label)を記録")
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }
}

/// 行をタップしたときの入力シート (Gymwork 型)。大きな数字 + 小刻み・大刻みの ± 、
/// 「残りのセットに適用」「セット完了」。完了すると次の未保存の行へ進む
struct SetEditorSheet: View {
    let title: String
    let columns: [SetColumn]
    @Binding var input: WorkoutSetInput
    let isWriting: Bool
    let message: String?
    /// 休憩の終わり。休憩中だけ題名の下に残り時間を出す (シートが休憩バーを隠すため)
    let restEndsAt: Date?
    let onApplyToRemaining: () -> Void
    let onComplete: () -> Void

    /// シートの中では .keyboard のツールバーが出ない (NavigationStack で包んでも出なかった) ため、
    /// キーボードが出ている間だけ題名の行に「完了」を出す
    @State private var isKeyboardShown = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Toggle("ウォームアップ", isOn: $input.isWarmup)
                        .toggleStyle(.button)
                        .font(.callout)
                    if isKeyboardShown {
                        Button("完了") { WorkoutView.dismissKeyboard() }
                            .font(.callout.bold())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let restEndsAt {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let remaining = RestTimerBar.remaining(until: restEndsAt, now: context.date)
                        Label(remaining > 0 ? "休憩 \(WorkoutLogic.formatDuration(remaining))" : "休憩終了",
                              systemImage: "timer")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns) { column in
                    VStack(spacing: 8) {
                        Text(column.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NumberField(value: $input[dynamicMember: column.keyPath], unit: column.unit, font: .largeTitle)
                        ForEach(column.steps, id: \.label) { step in
                            StepButtons(label: step.label) { sign in
                                let current = input[keyPath: column.keyPath]
                                input[keyPath: column.keyPath] = current.map { max(0, $0 + sign * step.amount) } ?? column.emptyStart
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(action: onApplyToRemaining) {
                    Text("残りのセットに適用")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                Button(action: onComplete) {
                    Label("セット完了", systemImage: "checkmark")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWriting)
            }
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardShown = false
        }
    }
}

/// − ラベル ＋ の 1 行
private struct StepButtons: View {
    let label: String
    let onStep: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { onStep(-1) } label: {
                Image(systemName: "minus").frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("\(label) 減らす")
            Text(label)
                .font(.callout.monospacedDigit())
                .frame(maxWidth: .infinity)
            Button { onStep(1) } label: {
                Image(systemName: "plus").frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("\(label) 増やす")
        }
        .buttonStyle(.borderless)
        .background(Capsule().stroke(Color(.separator)))
    }
}

/// 数値の直接入力。タップすると空欄になり (今の値は薄く表示)、打った値で置き換える。
/// 何も打たずに離れれば元の値のまま。打った時点で値に反映する (✓ を先に押しても取りこぼさない)
struct NumberField: View {
    @Binding var value: Double?
    let unit: Double
    var font: Font = .body

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(Self.text(for: value, unit: unit).isEmpty ? "—" : Self.text(for: value, unit: unit), text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .font(font.monospacedDigit().bold())
            .focused($focused)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
            .onAppear { text = Self.text(for: value, unit: unit) }
            .onChange(of: text) { _, newText in
                if let parsed = Self.parse(newText, unit: unit) { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                // 「前回」からのコピーなど外から値が変わったとき。入力中は打った文字を優先
                if !focused { text = Self.text(for: newValue, unit: unit) }
            }
            .onChange(of: focused) { _, isFocused in
                text = isFocused ? "" : Self.text(for: value, unit: unit)
            }
    }

    static func text(for value: Double?, unit: Double) -> String {
        value.map { plain($0 / unit) } ?? ""
    }

    static func parse(_ text: String, unit: Double) -> Double? {
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number >= 0 else { return nil }
        return number * unit
    }

    static func plain(_ number: Double) -> String {
        let rounded = (number * 100).rounded() / 100
        return rounded.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rounded)) : String(rounded)
    }
}

/// ✓ 後に自動で始まる休憩タイマー
struct RestTimerBar: View {
    let endsAt: Date
    let onChange: (Date?) -> Void

    static func remaining(until endsAt: Date, now: Date) -> Int {
        max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = Self.remaining(until: endsAt, now: context.date)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(WorkoutLogic.formatDuration(remaining))
                        .font(.largeTitle.monospacedDigit().bold())
                        .fixedSize()
                    Text("休憩")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("−15") { onChange(endsAt.addingTimeInterval(-15)) }
                    .buttonStyle(.bordered)
                Button("+15") { onChange(endsAt.addingTimeInterval(15)) }
                    .buttonStyle(.bordered)
                Button("スキップ") { onChange(nil) }
                    .buttonStyle(.borderedProminent)
            }
            // セット間に汗ばんだ指で押すので、ボタンの高さを 44pt 以上に (F-8)
            .controlSize(.large)
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
