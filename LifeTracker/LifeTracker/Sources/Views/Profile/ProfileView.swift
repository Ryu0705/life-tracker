import SwiftUI

/// 「プロフィール」タブのルート (2026-10-22 本人の決定。前はトレーニング → 分析 → プロフィールのボタンの奥にあり、分かりづらかった)。
/// 節「プロフィール」(性別・生年月日・体重を見せ、ProfileSheet・BodyWeightSheet で直す) と節「アカウント」(サインイン中のメールアドレス・サインアウト)。
/// ProfileStore はトレーニングのタブ (分析の強さ) と同じもの (MainTabView が 1 つ作る)。
/// 読み込み中・エラー (再読み込み)・未設定 (needsProfile / needsWeight) の出し分けは分析の強さ (BodyStrengthSections) と同じ
struct ProfileView: View {
    @ObservedObject var profileStore: ProfileStore
    /// サインイン中のメールアドレス (AuthStore.signedInEmail)。nil なら行を出さない
    let email: String?
    let calendar: Calendar

    @Environment(\.signOutAction) private var signOutAction
    @State private var sheet: SheetKind?

    private enum SheetKind: String, Identifiable {
        case profile, weight
        var id: String { rawValue }
    }

    private var today: Date { WorkoutSummary.dayKey(Date(), calendar: calendar) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    profileRows
                } header: {
                    Text("プロフィール")
                } footer: {
                    Text("強さの級の基準（体重比の表）を選ぶのに使います。")
                }
                if let signOutAction {
                    SignOutSection(action: signOutAction, email: email)
                }
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            // シートは List に 1 つだけ付ける (Section の行に付けると各行に配られて表示が競合する)
            .sheet(item: $sheet) { kind in
                switch kind {
                case .profile: ProfileSheet(profileStore: profileStore, today: today, calendar: calendar)
                case .weight: BodyWeightSheet(profileStore: profileStore, today: today, calendar: calendar)
                }
            }
        }
        .task { if !profileStore.isLoaded { await profileStore.load() } }
    }

    @ViewBuilder
    private var profileRows: some View {
        if let error = profileStore.error {
            HStack {
                Text("プロフィールを読めませんでした: \(error.localizedDescription)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Spacer()
                Button("再読み込み") { Task { profileStore.error = nil; await profileStore.load() } }
                    .buttonStyle(.borderless)
            }
        } else if !profileStore.isLoaded {
            Text("読み込み中…").foregroundStyle(.secondary)
        } else if let profile = profileStore.profile {
            LabeledContent("性別", value: profile.sex.displayName)
            LabeledContent("生年月日", value: Self.birthDateText(profile, today: today, calendar: calendar))
            weightRow
            // 体重がまだなら、プロフィールの画面で体重も一緒に入れる (分析の「体重を入力」と同じ。C-7: 同じ画面を開くボタンを並べない)
            if profileStore.setup == .needsWeight {
                Button { sheet = .profile } label: { Label("体重を入力", systemImage: "scalemass") }
                    .accessibilityIdentifier("profile.enterWeight")
            } else {
                Button { sheet = .profile } label: { Label("性別・生年月日を変更", systemImage: "person.crop.circle") }
                    .accessibilityIdentifier("profile.edit")
                Button { sheet = .weight } label: { Label("今日の体重を入力", systemImage: "scalemass") }
                    .accessibilityIdentifier("profile.enterWeight")
            }
        } else {
            Button { sheet = .profile } label: {
                Label("プロフィールを設定（性別・生年月日・体重）", systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("profile.setUp")
        }
    }

    /// 最新の体重と記録した日。まだ無ければ「未入力」
    @ViewBuilder
    private var weightRow: some View {
        if let latest = profileStore.latestWeight {
            LabeledContent {
                Text("\(WorkoutLogic.formatWeight(latest.weightKg))kg").monospacedDigit()
            } label: {
                Text("体重")
                Text(verbatim: "\(WorkoutSummary.dayLabel(latest.recordedOn, calendar: calendar)) の記録")
            }
        } else {
            LabeledContent("体重", value: "未入力")
        }
    }

    /// 生年月日の行の値 (「2000年1月1日（26歳）」)。日付は `calendar` の時間帯で読み、年齢は `today` の時点
    static func birthDateText(_ profile: UserProfile, today: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: profile.birthDate)
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日（\(profile.age(on: today, calendar: calendar))歳）"
    }
}
