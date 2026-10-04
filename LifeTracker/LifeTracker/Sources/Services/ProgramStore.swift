import Foundation
import Combine

/// 自分で組んだプログラム (DB 上は routine)。種目は並び順
struct WorkoutProgram: Identifiable, Hashable {
    let routine: Routine
    let exerciseIds: [UUID]
    var id: UUID { routine.id }
    var name: String { routine.name }

    /// routine と routine_exercise を組み合わせる。routine の並びは入力順のまま
    static func assemble(routines: [Routine], routineExercises: [RoutineExercise]) -> [WorkoutProgram] {
        let byRoutine = Dictionary(grouping: routineExercises, by: \.routineId)
        return routines.map { routine in
            WorkoutProgram(routine: routine,
                           exerciseIds: (byRoutine[routine.id] ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseId))
        }
    }
}

/// プログラムの一覧と保存・削除。今日の記録 (WorkoutSessionStore) とは別に持ち、今日の下書きに触れない
/// (docs/gymwork-alignment-design.md「変更 1」)
@MainActor
final class ProgramStore: ObservableObject {
    @Published private(set) var programs: [WorkoutProgram] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource

    init(dataSource: WorkoutDataSource) {
        self.dataSource = dataSource
    }

    func load() async {
        do {
            async let routines = dataSource.fetchRoutines()
            async let routineExercises = dataSource.fetchAllRoutineExercises()
            programs = WorkoutProgram.assemble(routines: try await routines, routineExercises: try await routineExercises)
            isLoaded = true
        } catch {
            if !WorkoutSessionStore.isCancellation(error) { self.error = error }
        }
    }

    enum SaveError: Error, LocalizedError {
        case emptyName
        case noExercises
        var errorDescription: String? {
            switch self {
            case .emptyName: return "名前を入れてください"
            case .noExercises: return "種目を 1 つ以上入れてください"
            }
        }
    }

    /// 保存して一覧を取り直す。同じ種目を 2 行以上持てる (routine_exercise の PK は (routine_id, sort_order)・0010)。
    /// 失敗は戻り値で返す (編集画面を開いたまま、同じ操作でやり直せる)
    func save(id: UUID?, name: String, exerciseIds: [UUID]) async -> Error? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SaveError.emptyName }
        guard !exerciseIds.isEmpty else { return SaveError.noExercises }
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await dataSource.saveRoutine(id: id, name: trimmed, exerciseIds: exerciseIds)
            await load()
            return nil
        } catch {
            await load()
            return error
        }
    }

    /// 失敗は戻り値で返す (一覧の下に出す。push 先の画面では一番上の alert が出ないことがあるため)
    func archive(_ program: WorkoutProgram) async -> Error? {
        do {
            try await dataSource.archiveRoutine(id: program.id)
            programs.removeAll { $0.id == program.id }
            return nil
        } catch {
            return error
        }
    }

    /// 種目の並びまで同じプログラム (今日の種目の保存・上書きを押せなくする判定)。今日が空なら nil
    func program(withSameOrderAs exerciseIds: [UUID]) -> WorkoutProgram? {
        guard !exerciseIds.isEmpty else { return nil }
        return programs.first { $0.exerciseIds == exerciseIds }
    }
}
