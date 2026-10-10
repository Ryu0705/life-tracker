import SwiftUI

/// 体重の入力 (数値＋±0.1kg)。体重の推移・食事を作るときも使い回す共通部品 (本人 Q2: 置き場はそのとき決め直す)
struct BodyWeightField: View {
    @Binding var kg: Double

    var body: some View {
        HStack(spacing: 12) {
            step("minus", -0.1, label: "0.1kg 減らす")
            TextField("体重", value: $kg, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .frame(minWidth: 80)
            Text("kg").foregroundStyle(.secondary)
            step("plus", 0.1, label: "0.1kg 増やす")
        }
    }

    private func step(_ symbol: String, _ delta: Double, label: String) -> some View {
        Button {
            kg = min(300, max(20, ((kg + delta) * 10).rounded() / 10))
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    static func isValid(_ kg: Double) -> Bool { (20...300).contains(kg) }
}

/// プロフィール (性別・生年月日) の設定。初回は体重も一緒に入れる (本人 2026-10-07)。
/// 2 表への 2 リクエストで非原子なので、体重だけ失敗したら理由を出し、もう一度「保存」で体重だけ送り直す (A-10)
struct ProfileSheet: View {
    @ObservedObject var profileStore: ProfileStore
    let today: Date
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss
    @State private var sex: Sex
    @State private var birthDate: Date
    @State private var kg: Double
    @State private var message: String?
    @State private var isSaving = false

    private let asksWeight: Bool

    init(profileStore: ProfileStore, today: Date, calendar: Calendar) {
        self.profileStore = profileStore
        self.today = today
        self.calendar = calendar
        asksWeight = profileStore.weights.isEmpty
        _sex = State(initialValue: profileStore.profile?.sex ?? .male)
        _birthDate = State(initialValue: profileStore.profile?.birthDate
                           ?? calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!)
        _kg = State(initialValue: profileStore.latestWeight?.weightKg ?? 65)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("性別", selection: $sex) {
                        ForEach(Sex.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("生年月日", selection: $birthDate, in: ...today, displayedComponents: .date)
                        .environment(\.timeZone, calendar.timeZone)
                } footer: {
                    Text("強さの級の基準（体重比の表）を選ぶのに使います。年齢は生年月日から計算します。")
                }
                if asksWeight {
                    Section("今日の体重") {
                        BodyWeightField(kg: $kg)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving || (asksWeight && !BodyWeightField.isValid(kg)))
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let changed = profileStore.profile.map { $0.sex != sex || !calendar.isDate($0.birthDate, inSameDayAs: birthDate) } ?? true
        if changed, let error = await profileStore.saveProfile(sex: sex, birthDate: birthDate) {
            message = "プロフィールを保存できませんでした: \(error.localizedDescription)"
            return
        }
        if asksWeight && profileStore.weights.isEmpty, let error = await profileStore.saveWeight(kg, on: today) {
            message = "プロフィールは保存しました。体重を保存できませんでした（もう一度「保存」で体重だけ送ります）: \(error.localizedDescription)"
            return
        }
        dismiss()
    }
}

/// 今日の体重 (同じ日は上書き)。保存メッセージはこの画面の @State (A-2 規約)
struct BodyWeightSheet: View {
    @ObservedObject var profileStore: ProfileStore
    let today: Date
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss
    @State private var kg: Double
    @State private var message: String?
    @State private var isSaving = false

    init(profileStore: ProfileStore, today: Date, calendar: Calendar) {
        self.profileStore = profileStore
        self.today = today
        self.calendar = calendar
        _kg = State(initialValue: profileStore.latestWeight?.weightKg ?? 65)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BodyWeightField(kg: $kg)
                        .frame(maxWidth: .infinity)
                } footer: {
                    if let message {
                        Text(message).foregroundStyle(.red)
                    } else if let latest = profileStore.latestWeight {
                        Text(verbatim: "前回 \(WorkoutLogic.formatWeight(latest.weightKg))kg（\(WorkoutSummary.dayLabel(latest.recordedOn, calendar: calendar))）。今日の分は上書きされます。")
                    }
                }
            }
            .navigationTitle("今日の体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            if let error = await profileStore.saveWeight(kg, on: today) {
                                message = "保存できませんでした: \(error.localizedDescription)"
                                isSaving = false
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving || !BodyWeightField.isValid(kg))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
