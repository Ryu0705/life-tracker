# C: データ・実装面の制約とコスト（Gymwork 寄せ・記録画面以外）

作成: 2026-09-30 / 担当: データ・実装 / 読み取りのみ（コード・DB 無変更）

## 0. 実 DB の現状（2026-09-30 SELECT で確認）

| 項目 | 値 |
|---|---|
| workout_session | 1 件（進行中 1 = 今日の分） |
| workout_set | 4 件 |
| routine / routine_exercise | 0 / 0 |
| exercise | 159（note 入り 0） |
| workout_session.note 入り | 0 |
| RLS | 全 14 テーブル無効（既知の未決事項。新テーブルも同じ扱いになる） |
| workout 系 index | session: started_at DESC / 進行中部分 UNIQUE / actual_task_id UNIQUE、set: session_id / exercise_id / (session_id, exercise_id, set_index) UNIQUE |

→ データが実質空なので、**今ならマイグレーションのコストは最小**（roadmap 論点4: 「Round 5 完了＝実運用開始」以降は branch 検証必須に切り替わる。今は `apply_migration` 直適用で可）。

## 1. 現在のデータモデルと API

### テーブル（0003_training_domain.sql / domain-model.md v16 が SSOT）
- `exercise`: name(UNIQUE) / muscle_group(14 値, **1 種目 1 部位のみ・補助筋なし**) / equipment(8 値, NULL 可) / metric_kind(weight_reps / reps_only / duration / duration_distance) / note（種目マスタ単位のメモ） / is_archived / sort_order
- `routine`: name / note / is_archived / sort_order
- `routine_exercise`: PK (routine_id, exercise_id) → **同じ種目を 1 ルーティンに 2 回入れられない**。target_sets / target_reps / target_weight（セットごとの目標は持てない。1 種目 1 組）
- `workout_session`: actual_task_id(nullable UNIQUE, SET NULL) / routine_id(nullable) / started_at / ended_at(NULL=進行中, > started_at) / note。進行中は DB で同時 1 件
- `workout_set`: session_id(CASCADE) / exercise_id(RESTRICT) / set_index(>0) / weight / reps / duration_sec / distance_m / rpe(未使用) / is_warmup / completed_at(nullable)。UNIQUE (session_id, exercise_id, set_index)
- 体重・身体計測のテーブルは**無い**。day 単位属性は `day_meta(date DATE PK, applied_pattern_id)` のみ
- actual_task 連携口: `workout_session.actual_task_id` のみ（Round 3 では常に NULL。チェックインは Round 5）

### WorkoutDataSource（protocol、Supabase / Mock 2 実装）
読み: fetchExercises / fetchRoutines / fetchRoutineExercises(routineId) / fetchInProgressSession / fetchSets(sessionId) / fetchExerciseSets(exerciseId)（**その種目の全期間の全セット**） / fetchRecordedExerciseIds
書き: startSession / endSession / deleteSession / addSet / deleteSet
**無いもの**: セット UPDATE、セッション一覧（期間指定）、期間指定のセット取得、note 更新（session / exercise）、routine / routine_exercise の INSERT/UPDATE/DELETE、exercise の INSERT/UPDATE

### WorkoutSessionStore（@MainActor, 「今日」専用）
- 状態: exercises / session（今日）/ sets（今日）/ plannedExerciseIds（今日の並び・メモリのみ）/ drafts（未保存行・メモリのみ）/ recordedExerciseIds / history（種目 id → 全セット、表示中の種目だけ遅延ロード）
- 自動運用: その日最初の addSet で session 作成（todaySessionCreatingIfNeeded）、load 時に前日以前の進行中を閉じる（セット 0 なら削除、あれば最後のセット時刻で end）
- load() は「今日のセッション id が変わったら plannedExerciseIds / drafts を捨てる」「history を毎回クリア」
- 導出は pure: `WorkoutLogic`（set_index・下書き初期化・刻み・表示）/ `WorkoutProgress`（日ごと集計は **completed_at の JST 暦日**でまとめる。session ではない / 指標 / Epley 1RM）
- テスト: WorkoutTests.swift に 61 件（round-3-work-plan 記載）。Mock は進行中 1 件・set_index UNIQUE・CASCADE を再現、応答喪失・遅延の注入あり

### 横断的な注意（既存コードの潜在問題を含む）
1. **PostgREST の 1 リクエスト上限（Supabase 既定 max-rows 1000）**: `fetchRecordedExerciseIds` は workout_set 全行の exercise_id を取っている → **セット 1000 件を超えると種目が推移一覧から欠ける**（週 4 回×20 セットで約 3 か月）。期間集計（c/k）も同じ罠を踏む。対策: `select distinct` 相当の RPC / View、または期間で必ず絞る＋ `.range()` でページング。今回の Round で直すのが安い
2. **日付の単位が 2 系統**: 「日」は completed_at の JST 暦日で集計、セッションは started_at。1 日 1 セッション運用なので現状一致するが、過去日にセットを足す（j）と completed_at の付け方次第でズレる
3. **週の始まり**: `HomeView.defaultCalendar` は timeZone だけ設定し firstWeekday は端末ロケール依存（ja_JP は日曜始まり）。週カレンダー・週集計を入れるなら「月曜始まり」を calendar に明示するか決める必要（本人決裁の小論点）
4. **下書き・並びはメモリのみ**: 今日の store に「別の日を選ぶ」状態を足すと、load() の「session id が変わったら drafts を捨てる」ロジックと衝突し、**過去日を見ただけで今日の未保存行が消える**。閲覧・分析は今日の store と別の読み取り専用 store に分けるのが安全

## 2. 候補ごとの評価

凡例 — DB: 要=マイグレーション要 / 不要。コスト: S=半日以内, M=1 日前後, L=数日

### (a) 週カレンダー帯＋選んだ日の記録表示
- 既存データ: 作れる（session.started_at / set.completed_at）
- 追加 API: `fetchSessions(from:to:)`（started_at 範囲、index あり）＋ `fetchSets(sessionIds:)`（`in` フィルタ）、または `fetchSets(completedFrom:to:)`。後者は completed_at に index が無い（件数的に当面問題なし）
- DB: 不要
- コスト: M（週ストリップ UI＋日選択＋読み取り store）
- 実装方針: `WorkoutHistoryStore`（読み取り専用、週単位でロード・キャッシュ）を新設。今日を選んだら既存の今日カード（書き込み可）を出し、過去日は (b) のカードで read-only 表示＝structural-conventions C-5（read-only は引数で、デフォルト引数なし）に合わせる
- テスト: 週の日付列の pure 関数（firstWeekday・JST・月またぎ）、日ごとのセッション有無マーク
- リスク: 上記 注意 3（週始まり）・4（store 分離）。今日の store と履歴 store の二重管理で「今日記録した直後に帯のマークが付かない」→ 今日分は今日の store から、過去分は履歴 store から取ると整合が取れる

### (b) 過去日の記録カード一覧（日付・種目・ボリューム・セット数）
- 既存データ: 作れる。ボリュームは `WorkoutProgress.value(.volume)` を種目横断に流用可
- 追加 API: (a) と同じ期間取得。一覧を無限スクロールにするなら `fetchSessions(before:limit:)`
- DB: 不要
- コスト: S〜M（(a) と同じ API を使えば S）
- 集計の注意: ボリュームは weight_reps のみ（自重・有酸素は 0 扱いではなく「対象外」）、warmup 除外、セット数は warmup を含めるか要決定（Gymwork は含める表示が多い。推移指標とは別定義になるので定義をコードコメントとテスト名に書く）
- リスク: 小。カード→詳細で (j) 編集に繋げるかどうかで構造が変わるので、(j) を採るかを先に決める

### (c) 週ごとの分析（週合計/平均ボリューム・曜日別棒グラフ・部位別セット数）
- 既存データ: 作れる（判断 D「導出、テーブル追加なし」の範囲内）。部位は exercise.muscle_group をメモリの exercises で引く
- 追加 API: 期間セット取得（(a) と共通）。直近 N 週を出すなら件数が 1000 を超え得る → **期間で分割取得 or RPC で日×部位の集計を DB 側で返す**
- DB: 不要（RPC/View を作るなら migration 1 本。ただし D-4 grep 規約は plan/actual の JOIN 禁止なので workout 内の集計 View は抵触しない）
- コスト: M（集計 pure 関数＋Swift Charts 2 種）
- 定義の決定が必要: 週平均＝「週合計 / トレーニングした日数」か「/ 7」か、部位別は「本番セット数」か「ボリューム」か（Gymwork は週あたりセット数）。1 種目 1 部位なので「ベンチ＝胸のみ（三頭 0）」になる点は現データモデルの限界として明記
- テスト: 週バケット（JST・週始まり・日曜深夜）、warmup 除外、metric_kind 混在、空週
- リスク: 小〜中（1000 行上限・週始まり）

### (d) ルーティン保存（今日の種目構成を保存）と呼び出し
- 既存データ: テーブルはある（0 件）。保存は `routine` 1 行＋`routine_exercise` N 行
- 追加 API: `createRoutine(name, exercises: [(exerciseId, sortOrder, targetSets, targetReps, targetWeight)])`、rename / archive / 並び替え / 種目の出し入れ。**2 テーブル書き込みの原子性**が無い（supabase-swift に Tx なし）→ RPC（plpgsql 関数 1 本 = migration）か、失敗時に routine を消す補償処理
- 呼び出し: 開始ボタンが無いので「呼び出す＝今日の plannedExerciseIds に種目を積む（既存 addPlannedExercise のループ）」で DB 書き込み不要。`workout_session.routine_id` を残したいなら、セッションは最初の ✓ で作られるので「呼び出したルーティン id をメモリに持ち、session 作成時に渡す」（startSession は既に routineId 引数あり）。2 つ目のルーティンを足した日は routine_id が 1 つしか持てない
- 目標値: 保存時に「今日のセット数・最後のセットの重量×回数」を target に写せる。ただし行の初期値は現状「前回の日のセット」で埋まるため、**target と前回のどちらを優先するか**の決定が必要（推奨: 前回優先、target は前回が無い種目の初期行にだけ使う＝既存 initialDrafts の拡張で済む）
- DB: 不要（RPC にするなら要）
- コスト: M（保存＋呼び出し＋一覧）。編集画面まで入れると L
- テスト: 保存の補償（routine_exercise 失敗時に routine が残らない）を Mock の失敗注入で、呼び出し時に記録済み種目と重複しない、target → 初期行
- リスク: 中。PK (routine_id, exercise_id) で同一種目 2 回不可（例: ベンチを最初と最後に）。今日カードも同一種目 1 枚なので現状は整合

### (e) 種目の入れ替え
- 未記録カード（下書きのみ）: plannedExerciseIds の該当 id を差し替え＋drafts 再生成（前回値で埋め直し）。**DB 不要・S**。位置を保つ API（`replacePlannedExercise(old:new:)`）を store に 1 つ足すだけ
- 記録済みセットがあるカード: workout_set.exercise_id を UPDATE する必要 → UPDATE API 新設、set_index の UNIQUE 衝突（入れ替え先にも同日のセットがある場合）、metric_kind が違うと値の列が不整合（weight_reps → duration 等）。**推奨: 記録済みのカードは入れ替え不可（今の「外す」と同じ制約）**
- リスク: 記録済みを許すと M 以上＋データ不整合のリスク

### (f) 今日のサマリーヘッダー（総ボリューム・セット数・種目数）
- 既存データ: store.sets から pure に出せる。DB・API 不要
- コスト: S
- 決定: セット数に warmup を含めるか、ボリュームは weight_reps のみ（(b)(c) と同じ定義関数を共有して 3 か所の数字を一致させる）
- 「完了サマリー」は終了操作が無いので**トリガーが存在しない**。常時ヘッダー表示か、日付が変わった後に (b) のカードで見せる形になる
- リスク: ほぼ無し

### (g) セッションメモ / 種目メモ
- セッションメモ: `workout_session.note` 列あり → DB 不要。ただし**セッションは最初の ✓ まで存在しない** → メモ保存時に今日のセッションを作る（todaySessionCreatingIfNeeded を流用。セット 0 のセッションは翌日の load で削除される＝**メモだけの日はメモが消える**）か、メモ入力を最初の記録後に限る。後者が安全。API: `updateSessionNote(id:note:)`
- 種目メモ（マスタ単位＝「シート高さ 4」）: `exercise.note` 列あり、ExerciseDetailView で表示済み。API: `updateExerciseNote(id:note:)` を足すだけ。DB 不要・S
- 種目メモ（その日のその種目単位＝Gymwork の種目カード内メモ）: 置き場が無い。新テーブル `workout_session_exercise(session_id, exercise_id, note, sort_order)` が要る（migration 要）。ついでに sort_order を持てば今日の並び（plannedExerciseIds）を永続化でき、「アプリを落とすと並びが消える」も解ける
- コスト: セッションメモ S / マスタ種目メモ S / 日×種目メモ M（migration＋domain-model.md 改訂）
- リスク: セッションメモの「セッション未作成」問題、日×種目メモは Mock/テスト・SSOT 更新の手数

### (h) 体重記録
- 既存データ: **無い**。migration 要
- 置き場の選択肢:
  1. 新テーブル `body_measurement(date DATE PK /*JST 暦日*/, weight_kg NUMERIC(5,2) CHECK > 0, body_fat_pct NUMERIC(4,1) NULL, measured_at TIMESTAMPTZ)` — day 単位の独立属性として day_meta と同格。1 日 1 件（上書き）。DataSource は workout とは別 protocol か WorkoutDataSource に同居か要決定（独立アグリゲートなので別が筋）
  2. HealthKit 読み取り（体重計・ヘルスケアに既にあるなら二重入力が無い）— DB 不要だが entitlement・権限 UI・シミュレータ検証が面倒
- 境界線チェック: spec の「時刻に紐づく → LT / 頻度だけ → Grit」に照らすと体重は「値の推移」でどちらでもない。**スコープ判断は本人決裁**（B 担当の不変条件とも突き合わせ要）
- コスト: M（migration＋domain-model v17＋DataSource＋入力 UI＋推移グラフは ProgressChartView 流用可）
- リスク: 中（SSOT 文書の改訂・新規アグリゲート・RLS 無効のまま増える）

### (i) 1RM 計算機
- 既存: `WorkoutProgress.estimatedOneRM`（Epley）あり。DB・API 不要
- コスト: S（重量×回数入力→1RM と %表（95〜50%）の pure 関数＋シート）
- 注意: Epley は高回数で過大。式の選択は判断 D で「実装時に確定」扱い → 現状 Epley で確定済みとして流用
- リスク: 無し

### (j) 過去日のセット編集
- 追加 API: `updateSet(id:, weight/reps/duration/distance/isWarmup)`（新規）、過去日へのセット追加は「その日のセッションに addSet」。**その日にセッションが無い日に足す場合**は started_at/ended_at 付きで閉じたセッションを作る API が要る（startSession は ended_at を入れられない＝部分 UNIQUE に引っかかる恐れ → `insertClosedSession(startedAt:endedAt:)` 新設）
- completed_at: 過去日に足すセットの completed_at を**その日の中の時刻**にしないと、日ごと集計（completed_at 基準）で今日に入ってしまう。既存の「その日の最後のセット +1 秒」等のルールを pure 関数で決める
- 全セット削除でセッションが空になった過去日: close() の破棄判定は「進行中」にしか走らないので、閉じた空セッションが残る → deleteSet 後に空なら deleteSession する処理が要る
- store: 今日の store の sets/history を触らず、履歴 store 側で編集し、今日の store の history キャッシュ（前回列・推移の元）を**無効化する**必要（前日を直したら「前回」列が古いまま）
- DB: 不要
- コスト: M〜L（UPDATE・閉じたセッション作成・キャッシュ無効化・C-4 CRUD 対称性の全数）
- テスト: 過去日追加が当日に混ざらない、空セッション削除、編集後に今日の「前回」が更新される、set_index 採番
- リスク: **高**（1 日 1 セッション自動運用・日付境界・キャッシュの 3 点に同時に触る）。round-3-work-plan で「セットの編集は Round 4 送り（C-4）」と明記済み

### (k) 部位の回復マップ
- 既存データ: 作れる（部位ごとの最終トレーニング日・直近 7 日のセット数）。部位は 1 種目 1 部位なので**補助筋の疲労は出ない**（ベンチで三頭・肩前部が回復済み扱い）
- 追加 API: (c) の期間セット取得を流用
- DB: 不要（補助筋を入れるなら `exercise_muscle(exercise_id, muscle_group, weight)` の migration＋159 種目分の seed 作業 = L）
- コスト: リスト/チップ表示なら S（(c) の後）、人体図 UI なら L（画像アセット・14 部位の領域分け）
- リスク: 小（数字の意味が粗いことを表示で誤魔化さない）

### 付記: 候補外だが同時に出る見込みのもの
- セット中ストップウォッチ: View の @State のみ、DB 不要・S。duration 系種目なら計測値を下書き行の durationSec に入れられる（既存 updateDraft で済む）
- 種目詳細の拡充（自己ベスト表・全履歴）: history から pure に出せる・S。30 日で prefix している履歴を「もっと見る」にするだけ

## 3. 集約表

| # | 候補 | 既存で可 | 追加 API | DB 変更 | コスト | 主なリスク |
|---|---|---|---|---|---|---|
| a | 週カレンダー＋日表示 | ○ | 期間セッション/セット取得 | 不要 | M | 週始まり未設定・今日 store と混ぜると下書き消失 |
| b | 過去日カード一覧 | ○ | a と共通 | 不要 | S〜M | 集計定義（warmup・自重）の統一 |
| c | 週分析 | ○ | a と共通（＋任意 RPC） | 不要 | M | 1000 行上限・週平均/部位の定義・1 種目 1 部位 |
| d | ルーティン保存・呼び出し | テーブルのみ | routine CRUD（2 表書き込み） | 不要（原子性に RPC なら要） | M（編集まで L） | 原子性・target と前回の優先順位・同一種目 2 回不可 |
| e | 種目入れ替え | 未記録のみ○ | store に replace 1 つ | 不要 | S | 記録済みを許すと UNIQUE/metric_kind 不整合 |
| f | 今日サマリー | ○ | なし | 不要 | S | 完了操作が無く「完了サマリー」のトリガーが無い |
| g | メモ | session/マスタ○、日×種目× | note 更新 2 本 | 日×種目のみ要 | S / M | セッション未作成時のメモ・メモだけの日は消える |
| h | 体重 | × | 新 protocol | **要**（新テーブル）or HealthKit | M | スコープ境界（Grit/ヘルスケア）・SSOT 改訂 |
| i | 1RM 計算機 | ○ | なし | 不要 | S | なし |
| j | 過去日セット編集 | 部分 | updateSet・閉じたセッション作成 | 不要 | M〜L | **高**: 日付境界・空セッション・前回キャッシュ |
| k | 回復マップ | ○（粗い） | c と共通 | 不要（補助筋なら要・L） | S（リスト）/ L（人体図） | 補助筋なしで不正確 |

## 4. 依存関係と 1 Round での推奨順序

```
[0] 基盤: 期間取得 API（fetchSessions(from:to:) / fetchSets(sessionIds:)）＋ 1000 行上限対策（fetchRecordedExerciseIds の修正含む）
    ＋ 週始まり・集計定義（volume/セット数/warmup）の pure 関数 1 か所化 ＋ 読み取り専用 WorkoutHistoryStore
      ├─ [1] f 今日サマリー（定義関数を最初に使う・DB 不要）
      ├─ [2] a 週カレンダー帯 → [3] b 日カード（read-only）
      ├─ [4] c 週分析 → [5] k 回復リスト版
      └─ （独立）e 未記録カードの入れ替え / i 1RM 計算機 / ストップウォッチ / g のセッション・マスタメモ
[6] d ルーティン保存・呼び出し（今日 store の plannedExerciseIds / initialDrafts を拡張。a〜c と独立だが今日 store に触るので後段で）
[別 Round 推奨] j 過去日編集（b の read-only 表示が固まってから、C-4 対称性とセットで）
[本人決裁後] h 体重（migration・スコープ判断）、g の日×種目メモ（migration。やるなら plannedExerciseIds 永続化と同じテーブルで）
```

理由:
- a/b/c/k は同じ「期間取得＋集計定義」に乗るので、基盤を先に 1 回作れば残りは View 中心になる（手戻り最小）。定義関数を先に固めないと f/b/c で数字が食い違う
- 今日の store（下書き・自動セッション）に触るもの（d, e, g-session）と触らないもの（a, b, c, k, i）を分けると、既存 61 テスト＋記録画面の実機確認済み挙動への回帰リスクを局所化できる
- j は日付境界・空セッション・前回キャッシュの 3 つに同時に触るため、同じ Round に入れると検証範囲が倍になる。read-only の b が先にあれば j は「b に編集を足す」差分になる（feedback: 次 Round の差し込み位置の予約）
- h と日×種目メモは migration＋domain-model.md 改訂を伴う。データがほぼ空の今は適用コスト自体は低いが、スコープ判断が先

1 Round の現実的な上限（S 級 5〜7 件の目安）: [0] 基盤 / f / a+b / c / e / i（＋ストップウォッチ）/ d（保存・呼び出しのみ、編集なし）
