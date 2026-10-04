# 同じ種目を 2 回・記録画面での種目の並べ替え 設計（2026-10-04）

状態: 設計案（本人決裁待ち。コード・DB は未変更）。親ドキュメントは `gymwork-alignment-design.md` 末尾「同じ種目を 2 回・記録画面での種目の並べ替え」。本ファイルがこの論点の SSOT。実装後は DDL を `domain-model.md`（v17）へ取り込み、ここには判断根拠だけ残す。

## 0. 本人の要望・決定

- 要望（2026-10-04 原文）: 「プログラムに同じ種目を2つ記録できない。最初に種目Aをやって、その後別種目を色々やった後に最後にもう一度種目Aをやりたいという場面が存在する。また、記録画面において種目の並べ替えをさせて。」
- 決定（2026-10-04・本人。聞き直さない）: **「並べ替えの結果を残す。トレーニングを実施した順番を意味するもの。」** → 記録画面の種目の並びは DB に保存する（再起動・別端末でも同じ並び）。並びの意味は「その日に実施した順番」であって予定の順ではない。したがって**記録済みのカードも並べ替えられる**（実施した順を直す操作）。

この決定から導かれる前提（AI の整理）:
- 「実施した順番」を持つのは記録済みのカードだけ。未記録のカード（予定）の並びは今までどおり端末メモリ（再起動で消える現状と同じ）。カードが最初の ✓ で「実施したもの」になった時点で、そのときの画面上の位置が DB に入る
- 並びは時刻（completed_at）から導出せず、**明示的に保存した順**を正とする。時刻順は移行時の初期値と、未保存のものの既定にだけ使う

## 1. 今の作り（事実。コードと DDL で確認）

| 箇所 | 事実 |
|---|---|
| `supabase/migrations/0003_training_domain.sql:56-64` | `routine_exercise` の PK は `(routine_id, exercise_id)`。同じ種目を 1 プログラムに 2 行入れられない。`sort_order INT NOT NULL`、target_* は NULL 運用（変更 1 P-2） |
| `0003:99-114` / `0008_workout_set_renumber.sql:30-32` | `workout_set` は `UNIQUE (session_id, exercise_id, set_index)`（0008 で `DEFERRABLE INITIALLY IMMEDIATE`、名前 `workout_set_session_id_exercise_id_set_index_key`）。セットは種目 id を持つだけで「何回目のブロックか」を持たない |
| `0008:39-59` | `workout_set_delete(p_id)` は削除後に **同じ (session_id, exercise_id)** の残りを 1..n に詰める。`GRANT EXECUTE … TO anon, authenticated`（RLS 無効・anon キー構成） |
| `Services/WorkoutDataSource.swift:111-114` | `WorkoutLogic.nextSetIndex(for: exerciseId, in:)` = その種目の最大 + 1 |
| 同 `:118-127` | `removingAndRenumbering` は (sessionId, exerciseId) 単位で詰め直す（RPC の写し） |
| 同 `:130-141` | `groupByExercise` は種目 id でまとめ、並びは「最初に記録した時刻順」。同じ種目は必ず 1 グループ |
| `Services/WorkoutSessionStore.swift:16-20, 41-48` | `plannedExerciseIds: [UUID]`・`drafts: [UUID: [DraftSet]]`・`history: [UUID: [WorkoutSet]]`・`sets(for: exerciseId)` がすべて**種目 id がキー**。`todayExerciseIds` = planned ＋ 記録済みで planned に無いもの |
| 同 `:84-92` | `load()` はセッションが同じなら `plannedExerciseIds` を保ち、違えば捨てて記録順（`groupByExercise`）で作り直す。**並びは DB に無い** |
| 同 `:106`, `:122` | `addPlannedExercise` は `todayExerciseIds.contains` で二重追加を拒否。`replacePlannedExercise` も「すでに今日にある種目」への差し替えを拒否 |
| 同 `:131-134`, `:180-186` | 「前回」列 = `previousDay(for: exerciseId).sets[position]`（前回の日の、その種目の全セットを時刻順に並べた位置対応）。行の初期値も同じ（`initialDrafts`） |
| 同 `:199-241` | `addSet` は `nextSetIndex` で番号を振り INSERT。成功したら `plannedExerciseIds` に無ければ末尾に足す |
| 同 `:276-284` | `undoSet` は `drafts[set.exerciseId]` の先頭に戻す（種目 id で戻し先を決める） |
| `Services/ProgramStore.swift:66-67` | `save` は種目 id の重複を**黙って 1 つにまとめる**。`MockWorkoutDataSource.saveRoutine:66` は重複を `duplicateRoutineExercise` で拒否（PK の再現） |
| `Services/SupabaseWorkoutDataSource.swift:50-84` | `saveRoutine` は routine を INSERT/UPDATE → `routine_exercise` を全 DELETE → `sort_order` 1..n で INSERT（原子的でない。変更 1 P-6） |
| `Views/Workout/WorkoutView.swift:242-246` | 記録画面は `ForEach(store.todayExerciseIds, id: \.self)` で**種目 id ごとに 1 枚**の `Section`。カード＝List の Section なので、`.onMove` でセクションは動かせない（`onMove` は ForEach の行に効く。Section を動かす API は AI の知識の範囲では無い。Web 未検索） |
| 同 `:296-393` | `exerciseCard` は `sets(for:)`・`drafts[exercise.id]`・`previousSummary`・`cardHeadline`（今日のその種目の全セット）を種目 id で引く。⋮ は未記録カードだけ（`:374`）で「入れ替え」「今日から外す」 |
| 同 `:397` | 種目追加・入れ替えの候補は `todayExerciseIds` に無い種目だけ（同じ種目を 2 回追加できない） |
| 同 `:575-578`, `:587-589` | ✓ 後の「次の行」は `todayExerciseIds` を種目 id で辿る。休憩・Live Activity の題名は「種目名 セットn」で n = その種目の今日の本番セット数 |
| `Views/Workout/PastDayView.swift:22` | 過去日も `groupByExercise` → 同じ種目は 1 枚に合流する |
| `Views/Workout/ProgramViews.swift:71, 292` | 確認シート・編集画面の `ForEach(exerciseIds, id: \.self)`。重複 id があると SwiftUI の ForEach の id が重なる（行の識別が崩れる） |
| 同 `:7, 65-67, 95` | 確認シートの「追加済み」判定は種目 id の集合（`alreadyAdded: Set<UUID>`） |
| 同 `:351` | プログラム編集の種目追加は `exerciseIds` に無い種目だけを候補にする |
| `Services/WorkoutSummary.swift:18` | 合計バーの「種目数」は `Set(sets.map(\.exerciseId)).count`（種目の種類数） |
| `Services/WorkoutHistoryStore.swift` | 週単位でセットだけを持つ読み取り専用 store。書き込み API なし（§6 の grep で担保） |
| `Services/RestAlerts.swift:54` | Live Activity は題名が同じなら update、違えば作り直す |
| 実機の状態（`gymwork-alignment-design.md`「実機確認」） | 本人の実機には 10/3 のビルド。0008 は本番適用済 |

## 2. 影響の棚卸し（2 枚のカードにしたとき、今のままだと起きること）

| 観点 | 今の前提 | 2 枚にすると |
|---|---|---|
| DB | セットは (session, exercise) で一意に番号付け | 2 枚目のセットが 1 枚目と同じ番号空間に入る（4, 5…）。「どのカードのセットか」を表す列が無い |
| 前回の値 | 前回の日のその種目の全セット（時刻順）を位置で対応 | 2 枚目も先頭から対応してしまう（1 枚目と同じ前回） |
| PR / 1RM / 推移 | 種目×日で集計 | **影響なし**（日単位の指標はカードに依らない） |
| 履歴（ExerciseDetailView） | その日のセットを `/` で連結 | 2 ブロックが続けて並ぶだけ（区切りが無い） |
| 週の集計・継続・ウィジェット | セット単位・日単位 | **影響なし** |
| Live Activity | 題名「種目名 セットn」 | 2 枚目で n が 1 枚目の続き（4, 5…）になる |
| プログラムから始める | 確認シートは種目 id 単位、追加は二重追加を拒否 | A が 2 行あっても 2 行目は黙って落ちる（`addPlannedExercise` のガード） |
| 入れ替え（⇄） | 今日にある種目へは差し替えない | A → B（B が今日にある）が拒否される |
| 削除の番号詰め | (session, exercise) 単位 | 1 枚目で消すと 2 枚目の番号も詰まる（ブロックの境目が無い） |
| 過去日 | 種目で 1 枚 | 2 ブロックが 1 枚に合流 |
| 並び | 端末メモリ、再起動で記録順 | **本人決定で DB 保存が要る**。記録済みカードの順を直したら、その順で再起動・過去日・別端末に出る |

## 3. 持ち方の候補（現状 → 採用後の差分）

| | A. 表示だけで分ける | B. `workout_set` に枠の列（`exercise_block`） | **C. セッションの種目の表 `workout_entry`（推奨）** |
|---|---|---|---|
| 要点 | DB 不変。今日のセットを時刻順に並べ「同じ種目の連続」を 1 ブロックと見なす | セットに「その日その種目の何回目のブロックか」を足す。UNIQUE を (session, exercise, block, set_index) に | 「その日に実施した種目 1 回分（＝カード）」を 1 行にする表。`sort_order`（実施順）を持ち、セットは `entry_id` で紐づく |
| DB 変更 | なし | 列 1 本・UNIQUE 付け直し・`workout_set_delete` 差し替え | 表 1 つ・`workout_set.entry_id`・UNIQUE 付け直し・`workout_set_delete` 差し替え・並べ替え RPC 1 本 |
| 既存データの移行 | 不要 | 全行 block = 1（DEFAULT） | (session, exercise) ごとに entry を 1 行ずつ作り、最初の completed_at 順で sort_order を振る（数十行） |
| RLS 無効 / anon | — | 列は表の権限に従う（GRANT 不要） | 表は Supabase の既定権限（0005・0009 と同じ扱い）、関数は GRANT EXECUTE を明示（0008 と同じ） |
| 0008 の関数 | 不変 | 詰め直しの単位を block まで含める | 詰め直しの単位を entry に。空になった entry を消す |
| 前回の値 | ブロックを時刻の連なりで推定して対応 | block で対応（正確） | entry の順番で対応（正確） |
| PR/1RM/推移・週集計・ウィジェット | 不変 | 不変 | 不変 |
| 履歴 | 推定ブロックで区切る | block で区切る | entry で区切る |
| Live Activity | 題名だけ | 題名だけ | 題名だけ |
| プログラムから始める | 行ごとに追加（ガード撤去） | 同左 | 同左 |
| ⇄ | ガード撤去 | 同左 | 同左 |
| 削除の番号詰め | (session, exercise) のまま（ブロック境界を跨いで詰まる） | block 単位 | entry 単位 |
| 過去日 | 推定ブロックで分ける | block で分ける | entry で分け **sort_order 順に並ぶ** |
| **並びの保存（本人決定）** | **できない**（持ち場所が無い） | 持ち場所が無い。別途 `workout_session` に順序配列を持つ／各セットに sort_order を複製する等が要る（§9） | **`workout_entry.sort_order` に入る** |
| 弱点 | ✓ の取り消し→再 ✓ で completed_at が後ろに動き、ブロックが分裂する（10/3 に実際にあった操作）。スーパーセット（A,B,A,B）が 4 枚に割れる。並びを保存できない | 並びを保存できない。block は「カード」そのものではなく属性なので、将来の種目メモ・スーパーセット・休憩秒数の置き場にならない | 変更量が最大（§14）。移行後は旧ビルドで記録できない（§12） |

判定: 本人決定（並びを DB に残す・記録済みカードも動かす）により A は不成立、B は並びの持ち場所を別に足す必要があり結局「カードの行」が要る。**C を採用**。C は Hevy / Strong 型の「ワークアウト → 種目エントリ（順序あり）→ セット」と同じ構造（推測: 両アプリの画面構成からの類推。実装は未確認）。将来の「種目メモ（次バッチ P6）」「スーパーセット」「種目ごとの休憩秒数」の置き場にもなる（仕様変更耐久性: 変更の種類ごとに評価 → 並び・重複・メモ・グループの 4 種とも entry の列追加で済む）。

## 4. 推奨案（C）の設計

### 4.1 DDL（migration。番号は §12）

```sql
-- その日 (セッション) に実施した種目 1 回分 = 画面のカード。同じ種目を 2 回やれば 2 行。
-- sort_order は「実施した順番」(2026-10-04 本人決定)。並べ替えで直す。予定の並びは持たない (未記録のカードは行を作らない)
CREATE TABLE workout_entry (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  UUID NOT NULL REFERENCES workout_session (id) ON DELETE CASCADE,
  exercise_id UUID NOT NULL REFERENCES exercise (id) ON DELETE RESTRICT,
  sort_order  INT  NOT NULL CHECK (sort_order > 0),
  CONSTRAINT workout_entry_session_id_sort_order_key UNIQUE (session_id, sort_order) DEFERRABLE INITIALLY IMMEDIATE,
  CONSTRAINT workout_entry_id_exercise_id_key UNIQUE (id, exercise_id)   -- 下の複合 FK 用
);
CREATE INDEX workout_entry_session_idx ON workout_entry (session_id);

ALTER TABLE workout_set ADD COLUMN IF NOT EXISTS entry_id UUID;
-- 既存データ: (session, exercise) ごとに entry を 1 行。実施順の初期値は最初の completed_at 順
INSERT INTO workout_entry (session_id, exercise_id, sort_order)
SELECT session_id, exercise_id,
       row_number() OVER (PARTITION BY session_id ORDER BY min(completed_at) NULLS LAST, exercise_id)
  FROM workout_set WHERE entry_id IS NULL GROUP BY session_id, exercise_id;
UPDATE workout_set s SET entry_id = e.id
  FROM workout_entry e WHERE s.entry_id IS NULL AND e.session_id = s.session_id AND e.exercise_id = s.exercise_id;
ALTER TABLE workout_set ALTER COLUMN entry_id SET NOT NULL;
-- entry と set の exercise_id が食い違わないことを FK で担保 (トリガー不要)。ON DELETE は既定 (NO ACTION) を第一候補:
-- 単独で非空の entry を消すと失敗する (セットを守る)。セッション削除の CASCADE (set と entry が同じ文で消える) が
-- この検査順で通るかは **未検証** (§12-1 ⑨ でコンテナ確認。通らなければ ON DELETE CASCADE に変える。
-- アプリが entry を消すのは空のときだけなので、どちらでも運用上の差は無い)
ALTER TABLE workout_set ADD CONSTRAINT workout_set_entry_fk
  FOREIGN KEY (entry_id, exercise_id) REFERENCES workout_entry (id, exercise_id);
CREATE INDEX workout_set_entry_idx ON workout_set (entry_id);

-- set_index の一意性を entry 単位に (2 枚目のカードは 1 から)
ALTER TABLE workout_set DROP CONSTRAINT IF EXISTS workout_set_session_id_exercise_id_set_index_key;
ALTER TABLE workout_set ADD CONSTRAINT workout_set_entry_id_set_index_key
  UNIQUE (entry_id, set_index) DEFERRABLE INITIALLY IMMEDIATE;

-- routine_exercise: 同じ種目を 2 行持てるように PK を (routine_id, sort_order) へ
--   (saveRoutine は全 DELETE → 1..n で INSERT なので、並び = PK で足りる。念のため欠番・重複を詰めてから付け直す)
ALTER TABLE routine_exercise DROP CONSTRAINT IF EXISTS routine_exercise_pkey;
UPDATE routine_exercise r SET sort_order = x.n
  FROM (SELECT ctid, row_number() OVER (PARTITION BY routine_id ORDER BY sort_order, exercise_id) AS n FROM routine_exercise) x
 WHERE r.ctid = x.ctid AND r.sort_order <> x.n;
ALTER TABLE routine_exercise ADD CONSTRAINT routine_exercise_pkey PRIMARY KEY (routine_id, sort_order);
```

関数（0008 と同じ型。`CREATE OR REPLACE` は権限を保つが GRANT も書く）:
- `workout_set_delete(p_id uuid)`: 制約 `workout_set_entry_id_set_index_key` を DEFERRED → DELETE → 同じ entry の残りを 1..n → **残りが 0 件ならその entry を DELETE し、同じセッションの entry の sort_order を 1..n に詰める**（`workout_entry_session_id_sort_order_key` も DEFERRED） → IMMEDIATE に戻す。無い id は何もしない（0008 と同じ）
- `workout_entry_reorder(p_session uuid, p_entry_ids uuid[])`: 配列順に sort_order = 1..k（`unnest … WITH ORDINALITY`）、配列に無いそのセッションの entry は旧 sort_order 順で k+1.. に。1 トランザクション。並べ替えと「最初の ✓ で entry を画面の位置に差し込む」の両方に使う
- entry の作成は PostgREST の INSERT（`sort_order` = 既知の最大 + 1）。UNIQUE が二重作成（別端末）を止めるので、失敗したら entry を取り直して 1 回だけやり直す
- どちらも `GRANT EXECUTE … TO anon, authenticated`。`ON CONFLICT` は使わない（DEFERRABLE な UNIQUE は対象にできない。0008 の事前確認と同じ）
- 冪等: `IF NOT EXISTS` / `WHERE entry_id IS NULL` / DROP IF EXISTS → ADD。使い捨て Postgres コンテナで 2 回流して同じ状態になることを確認する（0008 と同じ手順）

`workout_training_day` view（0005）・`fetchRecordedExerciseIds`・`fetchSets(completedFrom:to:)` は `workout_set` の既存列しか見ないので不変。`workout_set.exercise_id` は残す（種目単位の読み取りを JOIN なしで保つ。整合は複合 FK）。

### 4.2 モデル・データ取得

- `WorkoutEntry { id, sessionId, exerciseId, sortOrder }`（Codable）。`WorkoutSet` に `entryId: UUID`（`with(setIndex:)` / `with(values:)` も写す）。`NewWorkoutSet` に `entryId`
- `WorkoutDataSource` 追加: `fetchEntries(sessionId:)` / `fetchEntries(sessionIds:)`（過去日用。`.in` を 50 件ずつ）/ `addEntry(sessionId:exerciseId:sortOrder:) -> WorkoutEntry` / `deleteEntry(id:)`（未記録の残骸用）/ `reorderEntries(sessionId:entryIds:)`（RPC）。`deleteSet` の契約文を「entry 単位で詰め、空なら entry も消す」に改める
- `WorkoutLogic`: `nextSetIndex(forEntry:in:)` / `removingAndRenumbering` を entryId 単位に（空になった entry の削除と sort_order の詰めも写す）/ `groupByExercise` → `groupByEntry(sets:, entries:)`（entry の sort_order 順。entry が無いセットは出さない）
- Mock: `entries` を持ち、UNIQUE (session, sort_order)・entry と set の exercise_id 一致・削除時の entry 削除を再現

### 4.3 今日の store（`WorkoutSessionStore`）

```swift
/// 画面のカード。entryId は最初の ✓ で入る (それまでは予定 = メモリだけ)
struct TodayCard: Identifiable, Hashable { let id: UUID; let exerciseId: UUID; var entryId: UUID? }
@Published private(set) var cards: [TodayCard]            // 画面順。plannedExerciseIds の置き換え
@Published private(set) var entries: [WorkoutEntry]       // 今日のセッションの entry
@Published private(set) var drafts: [UUID: [DraftSet]]    // key = card.id (種目 id から変更)
var todayExerciseIds: [UUID] { cards.map(\.exerciseId) }  // 重複あり。プログラムの保存・同一判定はこれで足りる
func sets(for card: TodayCard) -> [WorkoutSet]            // entryId で絞る
func sets(for exerciseId: UUID) -> [WorkoutSet]           // 既存。PR 判定・種目単位の用途に残す
func ordinal(of card: TodayCard) -> Int                   // 同じ種目のカードの中で何枚目か (画面順・1 始まり)
func addPlannedExercise(_ exerciseId: UUID) async -> TodayCard   // 二重追加のガードを外す
func removePlannedCard(_ card:) async                     // 未記録のみ。残骸 entry (空) があれば deleteEntry
func replacePlannedCard(_ card:, with exerciseId:) async  // 未記録のみ。今日にある種目への差し替えも可 (2 枚目になる)
func moveCard(fromOffsets:toOffset:) async                // メモリ → 記録済みカードの相対順が変わったら reorderEntries
func previousSet(for card:, position:) -> WorkoutSet?     // §5
```
- `load()`: セッションが同じなら `cards` を保つ。違えば `fetchSets` と `fetchEntries` を並列に取り、**entry の sort_order 順**でカードを作る（記録順ではない）。セットは entryId でカードに付く
- 最初の ✓（`addSet(card:)`）: セッションを作る → `card.entryId == nil` なら `addEntry`（sort_order = 最大 + 1）→ 画面上でそのカードより下に記録済みカードがあれば `reorderEntries`（画面順）→ セット INSERT（`set_index` = その entry の最大 + 1）。応答喪失時の取り直しは既存どおり（entries も取り直す）
- `undoSet` / `deleteSet`: RPC の写しでローカルも詰める。entry が空になったら `card.entryId = nil`（カードと下書きは残る。再 ✓ で entry を作り直し、画面の位置に差し込む）
- 書き込みは `isWriting` で直列化。並べ替えの書き込みは「進行中の書き込みが終わってから送る」（✓ と並べ替えが行き違って順が戻らないように）
- 残す不変条件: 開くだけではセッションも entry も作らない（INV-1・既存テスト `firstSetCreatesTodaySession`）/ 未記録カードと下書きはメモリだけ（C-5）/ `selectedDay` を持ち込まない

### 4.4 記録画面（`WorkoutView` ほか）

- `ForEach(store.cards)`（Identifiable）。`EditorTarget` / `messages` / `selectedDraftId` の種目 id を `card.id` に。`complete()` の「次の行」はカード順で辿る。`exerciseCard` は `TodayExerciseCard.swift` に挙動不変で切り出す（WorkoutView.swift は 673 行で §6 の目安 450 を既に超えている）
- カード見出し: 同じ種目が 2 枚以上あるときだけ名前の後ろに「（2回目）」（画面順の序数）。見出しのサブ行「今日 … · e1RM …（前回 …）」は**そのカードのセット**で出し、前回は §5 の対応する前回 entry（1 枚だけの日は今までと同じ結果）
- セット番号はカードごとに 1 から（DB の set_index も entry 単位で 1 から＝画面と一致）。休憩・Live Activity の題名は「ベンチプレス（2回目） セット1」（題名が変わるので Activity は作り直し＝種目が変わったときと同じ）
- ⋮ を**すべてのカード**に出す。未記録: 入れ替え・今日から外す・種目を並べ替え。記録済み: 種目を並べ替え だけ（§6）
- 種目追加・入れ替えの候補から「今日にある種目」の除外を外す。今日にある種目は行の右に「追加済み（n）」の薄字（部位名の代わり）。1 回のシートで同じ種目を 2 回選ぶことはできない（選び直しのトグルのまま。2 回目はシートを開き直す）
- 合計バーの種目数は種目の種類数のまま（A×2 = 1 種目。AI 既定、§11）

### 4.5 過去日・履歴・分析

- `WorkoutHistoryStore` に `entriesById: [UUID: WorkoutEntry]`（`ensureLoaded` でセットを取った後、その session_id 群の entry を 1 リクエスト）。書き込み API は増やさない
- `PastDayView(sets:, entries:, …)`: entry ごとに 1 枚、**sort_order 順**。セットが 0 件の entry（§7 の残骸）は出さない。同じ種目が 2 枚なら「（2回目）」。編集要素は増やさない（C-5 は引き続き未発火）
- `ExerciseDetailView` の履歴行: 同じ日の 2 ブロックを「60×10 / 65×8 ｜ 50×12 / 50×10」のように「｜」で区切る（ブロックの順は entry が無い store では最初の completedAt 順。近似）。プログラム確認シートの「前回」も同じ表記
- 推移グラフ・PR・週分析・継続・ウィジェット: 不変（セット・日単位）

### 4.6 プログラム側

- DB: PK を (routine_id, sort_order) に（§4.1）。`RoutineExercise` 型は不変
- `ProgramStore.save`: 重複をまとめる処理（`:66-67`）を外す。`program(withSameOrderAs:)` は `[UUID]` 比較のままで重複も区別できる
- `ProgramEditView`: 行を `ProgramRow { id: UUID; exerciseId }` にして `ForEach` の id を行の id に（`id: \.self` をやめる）。種目追加シートは除外せず「追加済み（n）」表記。保存時は `exerciseIds` に戻す
- `ProgramLoadSheet`: 行はプログラムの行ごと（A が 2 行なら 2 行）。「追加済み」は**件数で判定**: その種目の k 行目は、今日その種目のカードが k 枚以上あれば「追加済み」（off 固定）。例: 今日 A が 1 枚、プログラムが A・B・A → 1 行目の A は追加済み、B と 2 行目の A が選べる → 読み込みで A, B, A の並びになる
- `WorkoutView.loadPlanned`: 順に `addPlannedExercise`（ガード撤去で重複がそのまま入る）。種目追加シート側の「手で選んだ分はプログラムの後ろに足し、重なりは落とす」（`ExercisePickerView:113-115`）はそのまま
- 「今日の種目を新しいプログラムに保存 / 上書き」: `todayExerciseIds`（画面順・重複あり）がそのまま入る。**記録画面で並べ替えてから上書きすれば、実施した順がプログラムに残る**（並びの永続化の 2 本目の経路）

## 5. 「前回」列の論点（Q2）

前提: 前回の日の A が entry で分かれている（移行後は過去分も (session, exercise) で 1 entry）。

| 案 | 2 枚目の A の「前回」 | 行の初期値 | 良い点 / 弱点 |
|---|---|---|---|
| **a. 同じ順番の entry（推奨）** | 前回の日の A の **2 つ目の entry** のセットを位置対応。無ければ「—」 | 前回の 2 つ目の entry。無ければ**今日の A の最後のセット**を写した 1 行（ウォームアップは外す） | 「最後にもう一度 A」が習慣なら前回の 2 回目と比べられる。前回が 1 回だけの日は前回が出ない（見れば分かる） |
| b. 通しの位置 | 前回の日の A の全セットを通しで対応（2 枚目の 1 行目 = 前回の (1 枚目の行数 + 1) 番目） | 同左 | DB 変更なしでも同じ。今日の 1 枚目の行数が前回と違うとずれて、ずれが見えない |
| c. 今日の A の最後のセット | 1 枚目の最後のセット（さっきやったもの） | 同左 | 「前回」の意味が変わる（列名と合わない）。日をまたいだ比較ができない |
| d. 1 枚目と同じ | 前回の日の A の先頭から | 同左 | 2 枚とも同じ値。2 回目が 1 回目より軽い運用だと毎回直すことになる |

a の細部: 前回の日に A が 2 entry・今日は 1 枚 → 1 枚目は前回の 1 つ目だけと対応（その日の全セットではない）。見出しの「前回 e1RM」も同じ対応（PR トーストと推移は日単位のまま）。

## 6. 並べ替え（Q3）

### 6.1 実物（分かる範囲。記憶によるものは推測と明記）
- iOS 標準（記憶・実機で未確認）: リマインダーとメモのチェックリストは行を**長押しして直接ドラッグ**（編集モード不要）。時計のアラーム・ミュージックのプレイリスト・設定 > 言語 は**「編集」→ ≡ ハンドル**。ホーム画面は長押し（ジグル）→ ドラッグ。つまり「タップ・スワイプなど他の操作がある行は編集モード＋ハンドル」「単純な一覧は直接ドラッグ」が標準の使い分け
- SwiftUI: `ForEach.onMove` は行単位で、編集モードで ≡ が出る（事実・`ProgramEditView` で使用中）。List の `Section` を丸ごと動かす API は AI の知識の範囲では無い（Web 未検索）。iOS 16 以降は編集モードでなくても行の長押しでドラッグできる、という理解（推測。要実機確認）
- Gymwork: 本人の操作録画（9/30）のフレームは本セッションには無く、並べ替えの操作は**未確認**。`gymwork-discussion/A-gymwork.md` G11 は見出しに ⇄ と ⋮ があることまで（⋮ の中身は推進派の提案で、Gymwork の実物ではない）
- Hevy / Strong（推測・記憶）: 種目の「…」メニューに Reorder exercises があり、≡ ハンドルの一覧シートで並べ替える。同じ種目を 1 ワークアウトに 2 回入れられる
- 既存の自アプリ: `ProgramEditView:301, 318` は `.environment(\.editMode, .constant(.active))` で ≡ を常時表示。`final.md` A-10 の「プログラム同士の並べ替え」は 5 件超まで見送り（別論点・不変）。守護派 C-5「並び替え（ドラッグ）は可」

### 6.2 操作（AI 既定・違えば直す）
- 記録画面のカードは Section なので直接ドラッグできない → **「種目を並べ替え」シート**: 今日のカードを 1 行 1 カード（種目名・「（2回目）」・「3 セット記録済み / 未記録」の薄字）で並べ、`ProgramEditView` と同じく編集モード常時＋≡。閉じる以外のボタンは無い
- 入口: 各カードの ⋮（記録済みカードにも ⋮ を出し、項目は「種目を並べ替え」だけ）。ジムで片手・立位でも、見ているカードの右上から 1 タップで開ける。入口の種類は 1 つ（C-7。シートが唯一の面）
- 対象: **すべてのカード**（本人決定: 記録済みも動かす）。未記録カードを記録済みの間に置くのも可（最初の ✓ でその位置が実施順として入る）
- 書き込み: 行を落とすたびに記録済みカードの相対順を比べ、変わっていれば `reorderEntries` を 1 回。失敗はシート下に文言（カードの `messages` と同じ型）
- 再起動・別端末: 記録済みカードは entry の sort_order 順で復元（本人決定どおり）。未記録カードは今までどおり消える（予定はメモリだけ）

### 6.3 プログラム編集画面との関係
- 見た目と操作を同じにする（≡・編集モード常時・行の見出し）。部品は共有してよい（行の内容が違うので無理に 1 つにはしない）
- 意味は違う: プログラムの並び = 予定、記録画面の並び = 実施した順。「今日の種目で上書き」が実施した順をプログラムに持ち帰る唯一の経路（§4.6）

## 7. エッジケース

| # | 場面 | 挙動（推奨案） |
|---|---|---|
| E1 | ✓ の取り消し → 再 ✓（10/3 に実際にあった操作） | entry が空になれば消え、カードと下書きは残る。再 ✓ で entry を作り直し、画面の位置に差し込む。A 案と違いブロックは分裂しない |
| E2 | A の 1 枚目を全部削除して 2 枚目だけ残す | 1 枚目の entry が消え、2 枚目が sort_order 1 に詰まる。画面では A が 1 枚なので「（n回目）」は出ない |
| E3 | 2 枚目を先に ✓ する | 2 枚目が先に entry になる（sort_order は画面順で差し込むので下側）。表示の序数は画面順なので「2回目」のまま。実施順を本人が直すなら並べ替えで |
| E4 | 深夜 0 時またぎ | entry はセッション単位、過去日はセットの completed_at の JST 暦日で絞る（既知の制約と同型）。翌日側の過去日には、その日にセットがある entry だけが出る |
| E5 | 2 端末で同時に最初の ✓ | entry の UNIQUE (session, sort_order) で片方が失敗 → entry を取り直して 1 回やり直す |
| E6 | アプリが entry INSERT とセット INSERT の間で落ちた | 空の entry が残る。今日の画面では未記録カードとして出る（そのまま記録できる）。過去日では出さない。「今日から外す」で DELETE |
| E7 | 並べ替え中に ✓ が進行中 | 書き込みを直列化（§4.3）。順序: ✓（entry 作成＋差し込み）→ 並べ替え |
| E8 | プログラム A・B・A を、今日 A が 1 枚ある日に読み込む | 件数判定で 1 行目の A だけ「追加済み」（§4.6） |
| E9 | 前回の日は A が 1 回、今日は 2 枚 | 2 枚目の前回は「—」、行は今日の A の最後のセットを写す（§5 a） |
| E10 | 移行後に旧ビルド（実機の 10/3 ビルド）で ✓ | `entry_id NOT NULL` で INSERT が失敗（読み取りは通る）。§12 の順序で避ける |
| E11 | 入れ替え（⇄）で今日にある種目を選ぶ | 許可（2 枚目になる）。自分自身への入れ替えだけ候補から外す |
| E12 | スーパーセット（A, B, A, B と交互に ✓） | カードは A・B の 2 枚（entry は 2 つ）。セットは各 entry に時刻順で入る。A 案のように 4 枚にはならない |

## 8. 可逆性

- DB（§4.1）: 戻せる。`entry_id` と表を落とし、`UNIQUE (session_id, exercise_id, set_index)` に戻すには同じ種目の 2 entry のセットを 1 列に詰め直す（0008 と同型の UPDATE）。**同じ種目を 2 回やった日は 1 枚に合流し、並べ替えた順は失われる**。`routine_exercise` の PK を戻すには重複行を消す必要がある（重複を含むプログラムを作る前なら無傷）
- アプリ: 画面・store はコードだけ。並べ替えシートは消すだけ。「（n回目）」表記・前回の対応（§5）・題名はそれぞれ数行

## 9. 不採用案と理由

| 案 | 理由 |
|---|---|
| A. 表示だけで分ける（時刻の連なりでブロック推定） | 並びを保存できない（本人決定に反する）。取り消し→再 ✓ でブロックが分裂（E1）、スーパーセットが割れる（E12）。「2 回目の A」が DB から引けない（10/3 に本人が価値を認めた「AI からの参照で一意」が崩れる） |
| B. `workout_set` に枠の列 | 並びの持ち場所が無い。並びを持たせるなら下の B' か B'' が要り、結局 C と同じ量になる |
| B'. `workout_session` に並びの配列（JSONB / UUID[]） | 制約で守れない（消えたブロックの鍵が残る・無い鍵は時刻順に落ちる）。過去日の表示にもセッション行の読み取りが要り、C と読み取りコストが変わらない。DB は最後の砦（`feedback_db_constraints_last_defense`）に反する |
| B''. 各セットに sort_order を複製 | 同じブロックのセットで値が食い違っても制約で止められない（トリガーが要る）。並べ替えのたびにセット全行を UPDATE |
| 最初の ✓ でなくカード追加時に entry を作る | 予定を DB に書くことになり「開くだけではセッションを作らない」（INV-1・既存テスト）と「並び = 実施した順」（本人決定）の両方に反する |
| `workout_set_add` RPC（entry 作成とセット INSERT を 1 トランザクションに） | E6 の窓を閉じられるが、✓ の経路（PostgREST INSERT ＋ クライアントの二度押しガード）を丸ごと変える。残骸は §7 E6 の扱いで足りる。必要になったら足す（差し込み位置: `addSet(card:)`） |
| 旧ビルド救済の BEFORE INSERT トリガー（entry_id が NULL なら作る） | 表をまたいで行を作るトリガーは構造規約 D-4 NG4 と同じ型の魔法。移行〜新ビルド導入は本人の 1 端末で数分の窓なので運用で避ける（§12） |
| 並べ替えを未記録カードだけに限る | 本人決定（実施した順を直す）に反する |
| カードの長押しドラッグ | Section は動かせない（§6.1）。行を 1 枚のカードに作り替えるのは記録画面の全面変更 |
| 2 枚目のセット番号を 1 枚目の続き（4, 5…）にする | 画面の番号（`setNumbers`）はカードごとに振る作りで、DB も entry 単位にするので一致させる方が単純。「3 番目のセット」が (entry, set_index) で一意 |

## 10. 本人に聞く論点（1 問ずつ・推奨を先頭）

### Q1. 持ち方: 「その日の種目 1 回分」の表 `workout_entry` を足す（migration）
- 要点: 現状はセットが種目 id を持つだけで、カードは画面の中にしか無い → 採用後はカードが DB の 1 行（並び・何回目か・将来のメモの置き場）になり、セットはその行に紐づく。並べ替えはこの行の `sort_order` を書き換える。同時に `routine_exercise` の PK を (routine_id, sort_order) に変えて、プログラムに同じ種目を 2 行入れられるようにする
- エッジケース: 移行後は実機の旧ビルドで記録できない（E10。適用と新ビルド導入を同じタイミングで）。✓ 取り消し→再 ✓（E1）は entry を作り直して位置に差し込む
- 可逆性: 戻せるが、2 回やった日は 1 枚に合流し並べ替えた順は失われる（§8）
- 記録先: 本ファイル §4 / `domain-model.md` v17（DDL）/ `gymwork-alignment-design.md` 末尾（決定の 1 行）
- 他の選択肢: A 表示だけ（並びを残せない・ブロック分裂）/ B セットに枠の列（並びの置き場が別に要る）/ B' セッションに順序配列（制約で守れない）

**本人回答（2026-10-04）: 「A」**（カードの表 `workout_entry` を足す。不採用: B セットに枠の列＝並びの置き場が別に要る／C 表示だけ＝並びを残せない）。migration は 0010、予定の旧列削除は 0011 へ繰り下げ

### Q2. 2 枚目の A の「前回」列
- 要点（推奨 a）: 現状は前回の日の A の全セットを先頭から対応 → 採用後は**前回の日の同じ順番の entry**（2 枚目 ↔ 前回の 2 回目）。無ければ「—」で、行は今日の A の最後のセットを写す
- エッジケース: 前回は 2 回・今日は 1 枚 → 1 枚目は前回の 1 回目だけと比べる（その日の全セットではない）。見出しの「前回 e1RM」も同じ対応。PR 判定と推移は日単位のまま
- 可逆性: store の関数 1 つ（`previousSet(for card:position:)`）の差し替え
- 記録先: 本ファイル §5
- 他の選択肢: b 通しの位置（ずれが見えない）/ c 今日の最後のセット（「前回」でなくなる）/ d 1 枚目と同じ

**本人回答（2026-10-04）: 「a」**（前回の日の同じ順番のカードと比べる。無ければ「—」・行は今日の 1 枚目の最後のセットを写す。不採用: b 通しの位置＝ずれが見えない／c 今日の最後のセット＝「前回」の意味が変わる／d 1 枚目と同じ＝2 回目を軽くすると毎回直す）

### Q3. 並べ替えの入口と操作
- 要点（推奨）: 現状は並べ替え不可 → 採用後は各カードの ⋮ →「種目を並べ替え」→ ≡ の一覧シート（プログラム編集と同じ見た目）。記録済みカードにも ⋮ を出す（項目はこれだけ）。すべてのカードを動かせる（本人決定）。落とすたびに保存
- エッジケース: 記録済みの間に未記録カードを置く → 最初の ✓ でその位置が実施順になる（E3 と組み合わせても矛盾しない）
- 可逆性: シートと ⋮ の項目を消すだけ
- 記録先: 本ファイル §6
- 他の選択肢: 画面下「種目を追加」の横に 1 つのボタン（下まで送る必要）/ 右上ツールバー（「プログラム」「分析」と並んで 3 つ目）/ カードの長押しドラッグ（Section は不可）/ 実機の Gymwork を見て合わせる（未確認なので、本人が録画を見て違えばここを直す）

**本人回答（2026-10-04）: 「A」**（各カードの ⋮ →「種目を並べ替え」→ ≡ の一覧シート。記録済みカードにも ⋮。不採用: B 画面下のボタン＝毎回下まで送る／C 右上に 3 つ目＝混む／D 長押しで直接ドラッグ＝Section のカードは動かせず画面の組み直しが要る【推測】）

### Q4. 2 枚目の見せ方（AI 既定でよいかの確認。まとめて 1 問）
- 要点: 名前の後ろに「（2回目）」（同じ種目が 2 枚以上の日だけ）/ セット番号はカードごとに 1 から（DB も）/ 休憩と Live Activity の題名は「ベンチプレス（2回目） セット1」/ 見出しの「今日 …」はそのカードのセット、「前回」は Q2 の対応 / 合計バーの種目数は種目の種類数（A×2 = 1）/ 履歴とプログラム確認シートの前回表示はブロックを「｜」で区切る
- エッジケース: 2 枚目を先に ✓ しても序数は画面順（E3）
- 可逆性: いずれも表示だけ
- 記録先: 本ファイル §4.4-4.5・§11
- 他の選択肢: 「②」表記 / 番号を続ける（不採用 §9）/ 種目数をカード数にする

**本人回答（2026-10-04）: 「表示上は2回目などは不要」** → 「（2回目）」の表記はどこにも出さない（カード・並べ替えシート・休憩・Live Activity の題名とも種目名だけ）。他の項目（番号はカードごとに 1 から・見出しはカード単位・種目数は種類数・履歴の「｜」区切り）は AI 既定のまま（本人は異議なし）

## 11. AI 既定（聞かずに進め、違えば直す）

- 表と列の名前: `workout_entry` / `entry_id` / `sort_order`（Swift は `WorkoutEntry` / `TodayCard`）
- entry は最初の ✓ で作る。未記録カードは DB に書かない
- 空になった entry は RPC が消し、同じセッションの sort_order を詰める（残骸は E6 のみ）
- 種目追加シートで同じ種目は 1 回のシートに 1 つまで（2 枚目はシートを開き直す）
- 並べ替えシートの保存は落とすたび。失敗の文言はシート下
- 「（2回目）」の序数は画面順。合計バーの種目数は種類数。履歴の区切りは「｜」
- `exerciseCard` を `TodayExerciseCard.swift` へ挙動不変で切り出す（WorkoutView.swift の行数）

## 12. 実装手順・移行手順（回帰防止）

0. 着手前に `xcodebuild test … -only-testing:LifeTrackerTests` を実行し全件 pass を記録（ベースライン。睡眠側の追加テストが並行しているので件数は当日の値）
1. migration を書く（番号: 今ある最大は `0009_sleep_record.sql`。`domain-model.md` 冒頭は 0010 を「task_template 旧列の削除」に予約している。0008 のときと同じく**この機能が 0010 を使い、旧列削除を 0011 に繰り下げる**案。親と睡眠側の作業に番号の衝突が無いことを確認してから確定）→ 使い捨て Postgres コンテナで ①新規適用 ②再適用（冪等）③既存データ風の seed（同じ種目 1 回の日・2 回に見える日）で entry の backfill と sort_order ④ `workout_set_delete` が entry 単位で詰め、空 entry を消し、sort_order を詰める ⑤ `workout_entry_reorder` が 1..n にし配列に無いものを後ろへ ⑥ 複合 FK が exercise_id の食い違いを拒む ⑦ `routine_exercise` に同じ exercise_id の 2 行が入り、同じ (routine_id, sort_order) は拒む ⑧ anon で両関数を実行できる ⑨ セットのあるセッションを DELETE したとき複合 FK (NO ACTION) が CASCADE を止めない（止めるなら ON DELETE CASCADE に変更）、を確認。migration は 1 トランザクションで適用する（MCP `apply_migration` の既存運用）
2. モデル・`WorkoutLogic`・Mock・テスト（UI なし）
3. `WorkoutSessionStore`（カード化・entry 作成・差し込み・並べ替え・取り消し）＋テスト
4. `WorkoutHistoryStore`（entries）＋テスト
5. プログラム側（store・編集・確認シート・ピッカー）＋テスト
6. 画面（`TodayExerciseCard` 切り出し → カード id 配線 → ⋮ → 並べ替えシート → 過去日 → 履歴の「｜」）→ モック（`-mock-workout`）で §13 のスクリーンショット
7. docs: `domain-model.md` v17（DDL・0010/0011 の番号）、`gymwork-alignment-design.md` 末尾に決定と本ファイルへのリンク、`implementation-roadmap.md` Round 4（過去日編集は entry 前提）
8. **本番適用の順序（本人）**: 0010 を MCP で適用 → すぐ新ビルドを実機に入れる。適用〜導入の間は旧ビルドで記録できない（読み取りは可）。適用後に MCP（読み取り）で entry が (session, exercise) ごとに 1 行・sort_order が 1..n・`workout_set.entry_id` に NULL が無いことを確認

## 13. 完了条件（機械チェック）

- [ ] `cd LifeTracker && xcodebuild test -project LifeTracker.xcodeproj -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -only-testing:LifeTrackerTests` が TEST SUCCEEDED。ベースラインの全件 pass ＋ 新規 ≥ 18（§14 の一覧）
- [ ] 使い捨て Postgres コンテナで §12-1 ①〜⑧ が通る（ログを `gymwork-alignment-design.md` に 1 行ずつ）
- [ ] `grep -n "ON CONFLICT" supabase/migrations/0010_*.sql` = 0
- [ ] `grep -rn "func fetchEntries\|func addEntry\|func deleteEntry\|func reorderEntries" LifeTracker/LifeTracker/Sources/Services/` が protocol・Supabase・Mock の 3 か所ずつ
- [ ] `grep -rn "duplicateRoutineExercise\|plannedExerciseIds\|groupByExercise(" LifeTracker/LifeTracker/Sources LifeTracker/LifeTrackerTests` = 0
- [ ] `grep -rn "todayExerciseIds.contains(" LifeTracker/LifeTracker/Sources` = 0（二重追加のガードが残っていない）
- [ ] `grep -n "entryId" LifeTracker/LifeTracker/Sources/Models/Workout.swift` ≥ 1、`grep -n "struct WorkoutEntry" …/Models/Workout.swift` = 1
- [ ] `grep -n "addSet\|deleteSet\|startSession\|endSession\|deleteSession\|addEntry\|deleteEntry\|reorderEntries" LifeTracker/LifeTracker/Sources/Services/WorkoutHistoryStore.swift` = 0（読み取り専用のまま）
- [ ] `grep -rn "selectedDay" LifeTracker/LifeTracker/Sources/Services/WorkoutSessionStore.swift` = 0
- [ ] `grep -n "onMove" LifeTracker/LifeTracker/Sources/Views/Workout/ReorderSheet.swift` ≥ 1、`grep -n 'id: \\.self' LifeTracker/LifeTracker/Sources/Views/Workout/ProgramViews.swift` = 0（重複 id の ForEach が無い）
- [ ] 構造規約 grep: `isReadOnly: Bool = false` 0 件（C-5）/ NavigationLink label 内の `Button|Toggle|DatePicker|TextField|Menu` 0 件（A-1）/ `@Binding var.*Toast` 0 件（A-2）/ `UIImpactFeedbackGenerator|UINotificationFeedbackGenerator` 0 件（B-1）
- [ ] `git diff --stat -- LifeTracker/LifeTracker/Sources/Views/Workout/SetRows.swift LifeTracker/LifeTracker/Sources/Views/Workout/ProgressChartView.swift LifeTracker/Shared LifeTracker/RestTimerWidget LifeTracker/LifeTracker/Sources/Views/Home LifeTracker/LifeTracker/Sources/Views/Sleep LifeTracker/LifeTracker/Sources/Models/SleepRules.swift` が空
- [ ] `git diff` の `complete(`・`editorSheet(`・`draftEditorSheet(` は「種目 id → カード id」の置き換え以外の差分が無い（目視）
- [ ] 行数: `ReorderSheet.swift` ≤ 120、`TodayExerciseCard.swift` ≤ 200、`WorkoutView.swift` ≤ 520、`WorkoutSessionStore.swift` ≤ 480
- [ ] モック（`-mock-workout`）スクリーンショット: ①プログラム編集に A が 2 行（≡ 付き）②読み込み後に A・B・A の 3 枚（「（1回目）」「（2回目）」）③ 2 枚目で ✓ → 番号 1・休憩バー・題名「…（2回目） セット1」④ ⋮ → 並べ替えシート → 3 枚目を 1 枚目に移す → 戻ると並びが変わり、下書きと休憩バーが残る ⑤ pull-to-refresh 後も並びがそのまま ⑥ 過去日（Fixture に A を 2 回やった日を足す）で 2 枚が sort_order 順 ⑦推移画面の履歴に「｜」
- [ ] 実 DB（本人）: 0010 適用 → 新ビルド → 1 セット記録 → MCP 読み取りで entry 1 行・`entry_id` 非 NULL・並べ替え後に sort_order が入れ替わる

## 14. 変更ファイル一覧（目安）

| 種別 | ファイル | 内容 | 目安 |
|---|---|---|---|
| 追加 | `supabase/migrations/0010_workout_entry.sql` | §4.1 の DDL・backfill・2 関数・GRANT | ≤ 120 行 |
| 変更 | `Sources/Models/Workout.swift` | `WorkoutEntry`、`WorkoutSet.entryId`、`with(...)` | +20 |
| 変更 | `Sources/Services/WorkoutDataSource.swift` | protocol 5 本、`NewWorkoutSet.entryId`、`WorkoutLogic`（nextSetIndex/renumber/groupByEntry） | ±50 |
| 変更 | `Sources/Services/SupabaseWorkoutDataSource.swift` | entries の fetch/insert/delete、RPC 2 本 | +45 |
| 変更 | `Sources/Services/MockWorkoutDataSource.swift` | entries、UNIQUE・FK の再現、`saveRoutine` の重複チェック撤去 | ±45 |
| 変更 | `Sources/Services/WorkoutSessionStore.swift` | `TodayCard` / `cards` / `entries` / 差し込み / `moveCard` / 取り消しの戻し先 | ±150（372 → ≤ 480） |
| 変更 | `Sources/Services/WorkoutHistoryStore.swift` | `entriesById` と取得 | +20 |
| 変更 | `Sources/Services/ProgramStore.swift` | 重複まとめの撤去 | −3 |
| 変更 | `Sources/Services/WorkoutFixtures.swift` | entries の生成、A を 2 回やった日 | +25 |
| 変更 | `Sources/Views/Workout/WorkoutView.swift` | カード id 配線、⋮、シート呼び出し、候補の除外撤去、`exerciseCard` の切り出し | 673 → ≤ 520 |
| 追加 | `Sources/Views/Workout/TodayExerciseCard.swift` | `exerciseCard` の切り出し（挙動不変）＋「（n回目）」 | ≤ 200 |
| 追加 | `Sources/Views/Workout/ReorderSheet.swift` | 並べ替えシート | ≤ 120 |
| 変更 | `Sources/Views/Workout/PastDayView.swift` | entry 単位・sort_order 順・空 entry 除外 | ±25 |
| 変更 | `Sources/Views/Workout/ExerciseDetailView.swift` | 履歴の「｜」 | ±8 |
| 変更 | `Sources/Views/Workout/ProgramViews.swift` | 行 id、件数判定、ピッカー除外撤去、「追加済み（n）」 | ±60 |
| 変更 | `Sources/Views/Workout/ExercisePickerView.swift` | 「追加済み（n）」表記（`todayCounts` 引数、デフォルト引数なし） | +20 |
| 変更 | `Sources/Services/WorkoutSummary.swift` | `latestDaySets` の「｜」用に entry で分ける小関数 | +10 |
| 変更 | `LifeTrackerTests/WorkoutTests.swift` | `set()` ヘルパーに entry、`group`/`nextSetIndex`/`mockDeleteRenumbers`/store 系の種目 id → カード | ±60 |
| 変更 | `LifeTrackerTests/WorkoutHistoryStoreTests.swift` | `duplicateRejected` を「2 枚目になる」に反転、entries の取得 | ±25 |
| 変更 | `LifeTrackerTests/ProgramStoreTests.swift` | `edit` の「重複をまとめる」を「重複を保つ」に反転 | ±10 |
| 追加テスト | 同上 3 ファイル＋`WorkoutSummaryTests` | nextSetIndex/renumber が entry 単位・groupByEntry の順・同じ種目 2 枚・最初の ✓ で entry と差し込み・load が sort_order 順・取り消しの戻し先・最後のセット削除で entry が消えカードが残る・前回の対応と fallback・今日にある種目への入れ替え・moveCard の書き込み有無・書き込みの直列化・Mock の reorder/空 entry 削除/重複 routine・件数判定・history の entries・デコード（entry_id）・種目数は種類数 | ≥ 18 件 |
| 変更 | `docs/domain-model.md` | v17: `workout_entry`、`workout_set` の列と UNIQUE、`routine_exercise` PK、冒頭の番号予約（0010 → 0011） | — |
| 変更 | `docs/gymwork-alignment-design.md` / `implementation-roadmap.md` | 末尾に決定と本ファイルへのリンク / Round 4 の前提 | — |
| 不変 | `SetRows.swift` / `ProgressChartView.swift` / `WeekAnalysisView.swift` / `ContinuityViews.swift` / `Shared/*` / `RestTimerWidget/*` / `Views/Home` / `Views/Sleep` / `SleepRules.swift` | 触らない（§13 の diff で担保） | — |

規模感: 作り直しではなく「手を入れる」範囲。行の入力（SetRows・入力シート・休憩・Live Activity・分析・継続）は不変で、変わるのは「カードの識別子」と「プログラムの重複」。0008（セット連番）の 2〜3 倍（migration に backfill と関数 2 本、store のキー変更、画面 1 枚追加）。

## 15. 未検証・推測の一覧

- iOS 標準アプリの並べ替え操作（§6.1）は記憶。実機で見てから文言を確定する
- SwiftUI の「編集モード無しで `onMove` の長押しドラッグ」は推測。シートは編集モード常時なので設計には影響しない
- Gymwork の並べ替え・同じ種目の 2 回目の扱いは未確認（録画が手元に無い）
- Hevy / Strong の挙動は記憶（推測）
- Supabase の既定権限で新しい表に anon が読み書きできること: 既存 migration（0005・0009）のコメントと運用実績から。適用後に MCP の読み取りで確認する
- `CREATE OR REPLACE FUNCTION` で GRANT が保たれるのは PostgreSQL の仕様（0008 でも依存している）。念のため GRANT を書く
- 本番 DB は読んでいない。`routine_exercise` の sort_order に重複が無いことは saveRoutine の作りから推定（migration は詰め直してから PK を付けるので、あっても通る）


## 本番適用の許可
- 2026-10-04 本人「DBへ当てて良い」（0010 の実装・使い捨て Postgres での検証が終わる前に受けた OK）。→ 検証が通ってから当てる。当てた時点で実機の旧ビルドでは記録できなくなる（本人には事前に説明済み）

## 実装結果（2026-10-04・未コミット・本番 DB 未適用）

### 検証（事実）
- SQL: 使い捨て Postgres 16（docker `postgres:16-alpine`・anon/authenticated ロールと Supabase の既定権限を再現）で 0001→0005 → 予定 seed → 0006→0009 → 本番相当のトレーニングデータ（3 セッション・複数種目・スーパーセット・completed_at NULL 1 行・routine_exercise の欠番）→ 0010 を 2 回。2 回目の後の状態は 1 回目と差分なし（冪等）。①〜⑨ 全項目 OK: backfill で (session, exercise) ごとに entry 1 行・最初の completed_at 順（NULL は最後）・entry_id の NULL 0 件／同じ種目 2 entry で 2 枚目の set_index は 1 から／UNIQUE (entry_id, set_index)・(session_id, sort_order)・(routine_id, sort_order) が重複を拒否／複合 FK が INSERT・UPDATE の種目不一致を拒否・セットのある entry 単独の DELETE を拒否／entry_id NULL の INSERT（旧ビルド相当）は not_null_violation／`workout_set_delete` は entry 単位で詰め、空 entry を消して sort_order を詰める・無い id は何もしない／`workout_entry_reorder` は配列順 1..k・配列外は旧順で後ろ・他セッションの id と重複は無視・他セッション不変／anon で両関数を実行可／**⑨ セッション DELETE の CASCADE は複合 FK（NO ACTION）に止められない**（set と entry が同じ文で消える。§15 の未検証は解消、ON DELETE は NO ACTION のまま）／routine_exercise に同じ種目 2 行。スクリプトと結果は作業メモ（scratchpad `workout_entry/`）
- Swift: `xcodebuild test -only-testing:LifeTrackerTests` TEST SUCCEEDED 216 件（着手前 196 件 + 20 件。新規は `WorkoutEntryTests.swift` 19 件ほか、既存の「重複をまとめる」「今日にある種目への入れ替えを拒む」は仕様どおり反転）
- §13 の grep: すべて期待値どおり。行数: ReorderSheet 59 / TodayExerciseCard 186 / WorkoutView 514 / WorkoutSessionStore 470
- シミュレータ（`-mock-workout -mock-day`）: プログラム編集で胸の日にベンチを 2 行目として追加・保存 → 確認シートの前回が「60×10 / 65×8 / 65×6 ｜ 50×12 / 50×10」→ 読み込みでカード 4 枚（ベンチ・インクライン・プッシュダウン・ベンチ）→ 2 枚目のベンチの前回は 50×12 / 50×10（前回の 2 回目）・✓ で番号 1・休憩バー → 1 枚目にも記録 → 記録済みカードの ⋮ は「種目を並べ替え」だけ・未記録は 3 項目 → シートで 4 行目を先頭へ → 戻ると並びが変わり下書きと休憩バーが残る → pull-to-refresh 後も同じ並び → 過去日（2 日前）にベンチが 2 枚 sort_order 順 → 推移画面の履歴に「｜」。種目追加シートは今日にある種目に「追加済み（1）」で、選ぶと 2 枚目になる

### AI が決めた細部（違えば直す）
- 2 枚目以降で前回の同じ順番のかたまりが無いときの行: 今日のその種目の最後のセット（ウォームアップは外す）。今日まだ記録が無ければ前回の日の最後のセット。行は 1 行。カードを足した時点で決め、後から 1 枚目を記録しても作り直さない
- 前回の対応の序数は画面順なので、並べ替えるとカードの「前回」列も入れ替わる（実施した順の 1 回目 ↔ 前回の 1 回目）。下書きの値は変えない
- 並べ替えシートの行の薄字: 記録済みは「n セット記録済み · 60×10 / 65×8」（同じ種目の行を見分けるため）、未記録は「未記録」
- 確認シートの読み込みボタンは行数（同じ種目 2 行なら 2 と数える）、左上メニューの「今日の種目（n種目）」は種類数
- entry 作成が失敗したら取り直し、応答だけ失われた自分の entry（同じ種目・セット無し・どのカードにも無い）があればそれを使い、無ければ 1 回だけやり直す。最初の ✓ の差し込み（reorder）の失敗はセット記録を止めない
- 記録済みカードの並びの保存が失敗したら、画面の並びはそのまま・シート下に文言。次の再読み込みで DB の並びに戻る
- `WorkoutSessionStore` の前回・履歴の導出は `WorkoutSessionStore+Previous.swift` に分けた（行数）。`TodayCard` とカードの突き合わせ（`WorkoutLogic.reconcile`）は `WorkoutDataSource.swift`
- Mock は entries の無いセットに migration と同じ規則で entry を作る（テストの組み立て用）

### 本番適用の手順（本人）
1. 0010 を MCP `apply_migration`（name: `v2_workout_entry`）で適用 → **すぐ新ビルドを実機に入れる**。適用〜導入の間、10/3 のビルドでは ✓（セット記録）が失敗する（entry_id NOT NULL）。読み取り・削除は通る（削除は新しい RPC で entry 単位に詰まる）
2. 適用後に MCP（読み取り）で確認: entry が (session, exercise) ごとに 1 行・sort_order が 1..n・`workout_set.entry_id` に NULL が無い・routine_exercise の PK が (routine_id, sort_order)。新しい表 workout_entry を anon が読み書きできること（Supabase の既定権限。コンテナでは既定権限を再現して確認しただけ）
3. 新ビルドで 1 セット記録 → entry 1 行・並べ替え後に sort_order が入れ替わることを読み取りで確認
- 2026-10-04 適用済み（MCP `v2_workout_entry`）。適用前（読み取り）: セッション 1・セット 12・(セッション, 種目) 4 組・プログラム 2・プログラムの種目 7・進行中 0。適用後（事実）: entry 4 行（sort_order 1..4・各 3 セット）・entry_id が NULL のセット 0・entry と set の種目一致・routine_exercise の PK (routine_id, sort_order)・7 行のまま・anon に workout_entry の select/insert/update/delete 権限、アプリと同じ anon キーで REST から読める（HTTP 200）。実機の新ビルドでの記録・並べ替えは本人確認待ち
