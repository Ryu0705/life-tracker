import Foundation
import Combine

/// プロフィール (性別・生年月日) と体重の記録。今日の記録 (WorkoutSessionStore) とは別に持ち、
/// 保存しても履歴 store を invalidate しない (INV-3。トレーニングの記録は変わらないため)
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile?
    /// recorded_on 順
    @Published private(set) var weights: [BodyWeightRecord] = []
    @Published private(set) var isLoaded = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource
    private let calendar: Calendar

    init(dataSource: WorkoutDataSource, calendar: Calendar) {
        self.dataSource = dataSource
        self.calendar = calendar
    }

    /// 強さブロックの状態 (レビュー A-10。初回入力は 2 表への 2 リクエストで非原子なので「体重だけ無い」を持つ)
    enum Setup: Equatable {
        case needsProfile
        case needsWeight
        case ready
    }

    var setup: Setup {
        if profile == nil { return .needsProfile }
        return weights.isEmpty ? .needsWeight : .ready
    }

    var latestWeight: BodyWeightRecord? { weights.last }

    func load() async {
        do {
            async let profile = dataSource.fetchProfile()
            async let weights = dataSource.fetchBodyWeights()
            self.profile = try await profile
            self.weights = try await weights.sorted { $0.recordedOn < $1.recordedOn }
            isLoaded = true
        } catch {
            if !WorkoutSessionStore.isCancellation(error) { self.error = error }
        }
    }

    /// 失敗は戻り値で返す (シートを開いたまま同じ操作でやり直せる。ProgramStore の P-6 と同じ)
    func saveProfile(sex: Sex, birthDate: Date) async -> Error? {
        let profile = UserProfile(sex: sex, birthDate: calendar.startOfDay(for: birthDate))
        do {
            try await dataSource.saveProfile(profile)
            self.profile = profile
            return nil
        } catch {
            return error
        }
    }

    /// その日の体重 (同じ日は上書き)
    func saveWeight(_ kg: Double, on day: Date) async -> Error? {
        let record = BodyWeightRecord(recordedOn: calendar.startOfDay(for: day), weightKg: (kg * 100).rounded() / 100)
        do {
            try await dataSource.saveBodyWeight(record)
            weights = (weights.filter { $0.recordedOn != record.recordedOn } + [record]).sorted { $0.recordedOn < $1.recordedOn }
            return nil
        } catch {
            return error
        }
    }
}
