# サインインと複数人化（2026-10-19〜）

食事管理（`meal-weight-design.md`）の設計の途中で決まった、食事より先に行う作業。食事の段階 1 の着手条件。棚卸しは `auth-multiuser-inventory-2026-10-19.md`（以下「棚卸し」。D1〜D9・F1〜F3・A1〜A8 はそこでの番号）。

凡例: 【本人】本人の決定／【AI 既定】AI が置いた案（違えば直す）／【要確認】本人に聞く／【事実】【推測】

## 本人の決定（原文は `meal-weight-design.md` の本人回答「レビュー v3 の本人に聞く問い」）

- 2026-10-19 12:1x 「今サインインも入れる」: AI を呼ぶ入口をサインインで守る
- 12:1x 「DBの全部の表も (Recommended)」: 今ある表と新しい表のすべてに RLS
- 12:3x 「メールアドレス & パスワード（メール送信してリンクを踏んでもらい、メールアドレスの検証は行う）に加えてSSOとしてGoogleも。新規登録も開く。逆に閉じる意味は？」
- 12:3x 「将来ほかの人にも使ってもらう」（7/10 の「公開・マネタイズは視野外」と食い違う。`~/life/.life/personal-dev/life-tracker/positioning.md` に追記）
- 13:3x 「今ある表の複数人化まで先に」: サインインと、今ある全部の表の複数人化を終えてから食事に入る
- 14:0x 「両方を commit してから (Recommended)」: 実装の前に、連続週数と種目画像の未 commit の変更を別々に commit する（push しない）
- 14:1x AI が応急の手当て（anon から TRUNCATE などを外す・v1 の残りの関数 6 つを消す）を今するか聞いた → 本人（原文）「今はユーザが私一人だから削除のリスクはない。」→ 応急の手当てはしない。直すのは複数人化の migration（§4・§5）。AI の補足: 危険の元は「ほかのユーザー」ではなく「anon キーを手に入れた人」（キーはアプリの中と Mac の xcconfig にあり、repo には無い）
- 14:4x 今のデータの持ち主（元の問い B＋C の前半）: `auth.users` の 2 件（2026-04-14 作成の Gmail・パスワードあり／04-20 作成の `lifetracker.local` の架空のアドレス）を伏せ字で示し、Gmail を使う（推奨）／新しいアドレスで作る、を出した → 本人「ya***@gmail.com を使う (Recommended)」（公開 repo なのでアドレスは伏せ字のまま）。→ 今のデータは 2026-04-14 作成の Gmail のアカウントに付ける。04-20 の架空のアドレスのユーザーはテスト用の 2 人目にする（M27）。Gmail は Google のアカウントなので、同じアドレスで Google サインインすると同じユーザーにまとまる
- 14:4x 元の問い C: 「この Gmail は、Supabase にログインするときのアドレスと同じですか？」→ 本人「同じ」→ 標準のメール送信で、本人のパスワードの再設定メールが届く。外部の SMTP は他の人に配るときまで要らない。このアカウントは確認済みなので、確認メールは要らない

## 前提（調べた事実・10-19 12:2x〜13:5x）

- Sign in with Apple とパスキーは有料の Apple Developer Program が要る見込み。記録では Program は保留（無料の Personal Team）。他の人の iPhone に入れる（TestFlight・App Store）にも Program が要る
- Supabase 標準のメール送信は、プロジェクトのチームのメンバーのアドレスにしか送らず、1 時間 2 通まで。他の人に確認メールを送るには外部の SMTP が要る
- 同じ確認済みのメールアドレスの Google とメール＋パスワードは、1 人のユーザーに自動でまとまる。手動の連携（既定で無効）は有効にしない（乗っ取りの報告あり）
- 棚卸しの要点【事実】: 表 21・view 1・関数 28（ほかに本番に v1 の残り 6）。RLS は全部無効で、anon と authenticated が全表に TRUNCATE まで含む全権限を持つ。関数はすべて SECURITY INVOKER。1 人前提の形が 15。本番の行は計 365。`auth.users` に v1 の時期（2026-04）のユーザーが 2 件。アプリにサインインの入口・URL スキームが無い。テストのたびに本番 DB を読んでいる見込み【推測】
- RLS の付け忘れは、エラーでなく「空の画面」になる

## 進め方（完了条件）

1. 棚卸し（済・13:38〜13:51）
2. 設計（このファイル）→ deep-task のレビュー → 本人の確認
3. 実装計画 → 本人 OK で実装 → 単体テスト・シミュレータで全タブを確かめる → 本人確認 → commit・push → 本番 migration（本人 OK 後・バックアップを取ってから）
4. 【2026-10-23 済み】0013（00:27）・0014（00:43）を本番に。本人が実機でサインインして「全タブ OK」（00:4x）。docs の書き直し（計画の段階 4）は 10-23 05:2x〜。経過は計画の作業時間

---

## 設計（実装・本番適用済み。2026-10-23 の段階 4 で今の形に直した）

2026-10-23 05:2x〜 各節を今の形に直した（計画の段階 4）。サインイン（§7）と Supabase の設定（§8）は、10-22 のパスワードレスの形を「今の形」にし、それより前の案を「当時の案」に畳んだ。0015（トレーニングの日・10-23 04:31）・0016（種目の追加・05:06）で変わった所も直した。DB の今の形の一覧は `domain-model.md`、確かめは `supabase/test/checks.sql`。

レビュー `auth-multiuser-review-2026-10-19.md` の「AI が直してよい点」を 10-19 14:3x に反映した。括弧の M 番号はレビューの番号。本人の判断・操作を含む M13（バックアップ）・M19（Google の設定）は 14:4x に AI が §6・§7 に入れた（操作は本人）。10-19 15:4x、実装計画のレビュー `auth-multiuser-plan-review-2026-10-19.md`（P1〜P24）で分かった訂正を、各節に【計画…】の注記で入れた。本文の書き直しは計画の段階 4。

### 1. 誰のデータか（`user_id`）の持ち方【AI 既定】

- 人のデータを持つ表すべてに `user_id UUID NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE` を足す。子の表（`workout_set`・`routine_exercise`・`actual_task_tap` など）にも持たせる（RLS の式を全表で同じにし、親をたどる副問い合わせを避けるため）
- 例外は `exercise`。共有の行は `user_id` が NULL なので、NULL 可のまま既定値 `auth.uid()` だけを付ける（将来の自作は本人の物になる）（§3・M4）
- 既定値を `auth.uid()` にするので、アプリの書き込みと関数の中の INSERT（10 関数・17 か所）は変えずに本人の値が入る。関数の引数も変えない（PGRST203 と Swift の `ScheduleRPC` の書き換えを避ける・棚卸し §1-4）
- MCP（postgres）は BYPASSRLS で表の所有者なので、RLS を越えて読み書きできる。NULL になるのは既定値の `auth.uid()` だけ【事実】。MCP で INSERT するときは `user_id` を明示する（UID は memory。repo には書かない）。明示を忘れると NOT NULL で失敗するので、入れ忘れの行は作れない（`exercise` は NULL 可なので止まらず共有の種目になる・SQL レビュー S10・§9）。子の表は複合の外部キーが持ち主の食い違いを止める（M25。棚卸し §3-1 R-3）
- 親と子の持ち主の一致: 親に `UNIQUE (id, user_id)` を足し、子の外部キーを `(親の id, user_id)` の組にする。`ON DELETE SET NULL` の外部キーは列を指定する形（`ON DELETE SET NULL (template_id)`。PostgreSQL 15 以上。本番は 17.6【事実】）にして user_id は消さない
  - `UNIQUE (id, user_id)` を足す親は 8 表: category・scheduled_task・task_template・actual_task・pattern・task_template_version・routine・workout_session（M30）
  - 組にした外部キーは 19 本【事実・`checks.sql`「子の外部キー 19 本が user_id を含む組」】: 下の一覧（M30 の 19 本から、0013 で `task_template → category` が無くなって 18 本）と、SQL レビュー S2 で組にした `workout_set_entry_fk`:
    - actual_task → category・scheduled_task（SET NULL (scheduled_task_id)）・task_template（SET NULL (template_id)）
    - actual_task_tap → actual_task ／ day_meta → pattern
    - pattern_version_membership → pattern・task_template_version
    - routine_exercise → routine
    - scheduled_task → category・pattern・task_template ／ ~~task_template → category~~（0013 で列ごと消えた）／ task_template_exdate → task_template ／ task_template_version → category・task_template
    - workout_entry → workout_session ／ workout_set → workout_session（0015 で `(session_id, user_id, day)` に締めた。セットの日 = セッションの日）
    - workout_session → actual_task（SET NULL (actual_task_id)。`UNIQUE (actual_task_id)` は残す）・routine（SET NULL (routine_id)）
  - 組にしないもの: `exercise` を指す 3 本（`routine_exercise`・`workout_entry`・`workout_set`。共有の種目は user_id が NULL）。`pattern_template_membership` は先に 0013 で消した（§11・M14）
  - `workout_set_entry_fk`: 設計では `(entry_id, exercise_id)` のままの予定だったが、SQL レビュー S2 で `(entry_id, exercise_id, user_id)` の組にし（`workout_entry` に `UNIQUE (id, exercise_id, user_id)`）、0015 で `(entry_id, session_id, exercise_id, user_id)` に締めた（前の日の entry に今日のセットが付くのを止める）。DEFERRABLE でないので、entry とセットの種目を両方替えるときは 1 つの文（書き込む CTE）にする（0016）
  - 種目は組にできない（共有の行は user_id が NULL）。外部キーの検査は RLS を越えるので、他人の自作の種目の UUID を知っていれば参照できる。UUID は推測できず、他人の自作は RLS で見えないので受け入れる。種目以外は組にするので、他人の行があるかを外部キーのエラーで探ることもできない（M17）
- 索引: RLS の式で絞る `user_id` を、各表の主な索引の先頭に足す

### 2. 1 人前提の形の置き換え（棚卸し §1-2・§2-6）【AI 既定】

| # | 今 | 後 |
|---|---|---|
| D1 | `user_profile` は `id = 1` の 1 行 | 主キーを `user_id` にし、`id` 列と CHECK を消す。アプリの upsert は `onConflict: "user_id"`（A2） |
| D2 | `body_weight_record` の主キー `recorded_on` | 主キー `(user_id, recorded_on)`。upsert は `onConflict: "user_id,recorded_on"` |
| D3 | `day_meta` の主キー `date` | 主キー `(user_id, date)` |
| D4 | `training_goal` の一意 `effective_from` | 一意 `(user_id, effective_from)`。upsert も同じ |
| D5 | 進行中のセッションは全体で 1 件 | 人ごとに 1 件。部分 UNIQUE は表の制約では書けないので索引にする: `CREATE UNIQUE INDEX ... ON workout_session (user_id) WHERE ended_at IS NULL`（M30）。【0015 で消した: 前の日と今日が同時に開くので、`UNIQUE (user_id, day)`（1 人 1 日 1 セッション）に替えた。`training-day-implementation-plan.md`】 |
| D6 | 睡眠の重なりを全体で禁止 | `EXCLUDE USING gist (user_id WITH =, tstzrange(...) WITH &&)`。`CREATE EXTENSION btree_gist WITH SCHEMA extensions`（0001 の pgcrypto と同じ置き場。本番は未インストールで 1.7 を入れられる【事実・レビュー §0】） |
| D7 | 種目は名前で一意 | 「共有の中で」と「人ごとの中で」の 2 つの部分 UNIQUE（§3） |
| D8 | 曜日・祝日のパターンは全体で 1 件 | `CREATE UNIQUE INDEX ... ON pattern (user_id, apply_day) WHERE apply_day IS NOT NULL`（M9・M30） |
| D9 | view が所有者の権限で全員の行を返す | `ALTER VIEW public.workout_training_day SET (security_invoker = true)`。RLS で本人の行だけになる |
| A3 | ウィジェットは App Group の 1 キー | サインアウトで `continuity.v1` を消し（`removeObject`）、別のキー `auth.signedIn.v1`（Bool）を false にして `WidgetCenter.shared.reloadAllTimelines()`。サインインで true。ウィジェットは false なら「アプリでサインインしてください」、true でスナップショットが無ければ今の文言（「アプリで週の目標回数を設定」）。キーが無い（認証の前のビルドからの移り）ときはサインイン済みとみなす。`Snapshot` の形は変えない（変えると今の保存が読めなくなる）。設計の「`Snapshot` に `isSignedIn`」は計画レビュー P8 で別のキーに変えた（計画 §2-6・M21） |

一意の制約に user_id を含めるので、他の人の行とぶつかって保存が失敗することも、エラーから他の人の記録が漏れることもなくなる（棚卸し §1-2 の注）。

### 3. 初期データ（棚卸し §1-5・F1〜F3）

- **種目**【AI 既定・本人に一言で提示】（元の問い A。案 1＋M16 の view）
  - 159 件は共有のマスタ（`user_id` NULL）。API からはだれも書けず、MCP（postgres）だけが書ける。自作の種目は人ごと（`user_id` = 本人）。【10-23 の 0016 で共有に 1 件（スミスマシンインクラインベンチプレス・sort_order 120）を足して 160 件。`incline-smith-bench-plan.md`】
  - §6 の付け替えの対象から外す。159 件はすべて seed の名前と一致し、本人の自作は 0 件【事実・棚卸し】（M4）
  - `exercise.sort_order` はマスタの並び（seed が部位ごとに振った 100 番台）として残す。`is_archived`・`note` は人ごとの表 `exercise_preference (user_id, exercise_id, is_archived, note, sort_order)` に移し、`exercise` から消す。本番は全部 false／NULL なので、移すデータは無い（M16）
  - view `exercise_for_user`（`security_invoker = true`）で今の列の形を保つ: `SELECT e.id, e.name, e.muscle_group, e.equipment, e.metric_kind, p.note, COALESCE(p.is_archived, false) AS is_archived, COALESCE(p.sort_order, e.sort_order) AS sort_order FROM public.exercise e LEFT JOIN public.exercise_preference p ON p.exercise_id = e.id`。`exercise_preference` の RLS で、本人の設定だけが結合される（M16）
  - アプリは `from("exercise")` を `from("exercise_for_user")` に変えるだけ。`Exercise` の形・画像（`ExerciseImageNames.byName`）・強さの基準（名前で引く）はそのまま（M16）
  - `exercise_muscle_group_idx`（今は `WHERE is_archived = false`）は条件なしで作り直す（M16）
  - アーカイブ・メモの書き込みは当面 MCP（`exercise_preference` に `user_id` を明示・M25）。アプリの画面で変える日が来たら `exercise_preference` に upsert（`onConflict: "user_id,exercise_id"`）（M16）
  - 名前の一意は「共有の中で」と「人ごとの中で」の 2 つの部分 UNIQUE。本人が共有と同じ名前の自作を作ると、一覧に 2 つ並び、名前で引く画像と基準は両方に当たる。防ぐには trigger が要るので、今は「作らない」運用にする（M17）
  - これから書く種目の seed（画像の追加など）は `ON CONFLICT (name) WHERE user_id IS NULL DO NOTHING` と書く。0004 の `ON CONFLICT (name)` は部分 UNIQUE に合わなくなるが、本番では適用済み。docker で 0001 から流すときは 0004 が先に走るので通る（M5）
  - 案 2（新しい人ごとに 159 件を写す）は採らない: 画像と基準は名前で引くので、共有のままで困らない。写すと、種目を増やすたびに全員へ配り直す
- **休日パターン・ジムと睡眠の種類**（F1・F2）【AI 既定】: サインインの直後にアプリが関数 `ensure_user_defaults()` を呼び、無ければ作る（何度呼んでも同じ結果）。中身は休日パターン 1・種類「ジム」（`sub_input_kind = gym`）・「睡眠」（`sleep`）。今の本人の行は付け替えで残るので、作られない
  - 起動が重なって同時に 2 回呼ばれても 2 件にならないよう、DB に「1 件ずつ」の砦を置く（M9）: `CREATE UNIQUE INDEX category_user_kind_unique ON category (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL`（本番は gym 1・sleep 1 なので今から付けられる）と、D8 の索引。関数の INSERT は `ON CONFLICT (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL DO NOTHING` のように WHERE まで書く
  - `auth.users` の AFTER INSERT トリガーで作る案は採らない。トリガーが失敗するとサインアップ自体が止まる（Supabase の文書の注意）。アプリから呼ぶ RPC のまま（M9）
- **週の目標**: 新しい人は未設定から始める（今の画面のまま）【AI 既定】

### 4. 関数（棚卸し §1-4）【AI 既定】

- SECURITY INVOKER のまま。INSERT は §1 の既定値で user_id が入る。読む所は RLS で本人の行だけになる（`schedule_holiday_pattern_id()` も本人の休日パターンを返す）
- `ON CONFLICT` の対象は親の UUID を含むキーなので変えない（棚卸し §1-4）。対象の制約が変わる D2・D4 は、関数ではなくアプリの upsert。ぶつかった既存の行が RLS に合わないとエラーになる（黙って飛ばさない）が、RLS が効けば本人の行としかぶつからない【事実・レビュー §1】
- 全部の関数に `SET search_path = ''` を付け、中の表は `public.` で書く（advisor の WARN 28）。あわせて次を直す（M3）
  - `workout_set_delete`・`workout_entry_reorder` の `SET CONSTRAINTS` の制約名にもスキーマを付ける: `SET CONSTRAINTS public.workout_set_entry_id_set_index_key, public.workout_entry_session_id_sort_order_key DEFERRED`。付けないと、検索パスが空で名前を解けず、✓ の取り消し・セットの削除・並べ替えが実行時に失敗する【事実】
  - 関数の中から呼ぶ関数（`jst_today()`・`schedule_assert_editable()`・`schedule_holiday_pattern_id()`・`schedule_single_delete()` など）にも `public.` を付ける（`private.` は付いている）
  - `ALTER FUNCTION ... SET search_path = ''` だけを付けて本文を直さないと、全関数が「relation does not exist」で壊れる。必ず本文の書き直しと同時に行う
- 実行の権限（M1）: 本番の public の関数には、作ったときに自動で付く PUBLIC（全ロール）の EXECUTE がある【事実】。anon から外すだけでは PUBLIC 経由で呼べたままなので、`REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon` とし、authenticated にだけ与える。`private` は anon の EXECUTE を外し、`REVOKE USAGE ON SCHEMA private FROM anon` も書く。0012 の注記どおり、中から呼ばれる関数にも authenticated の EXECUTE を残す。既定の権限は §5
- v1 の残り 6 つ（`fn_resolve_month_patterns`・`sync_did_*`・`update_updated_at`）は消す（SECURITY DEFINER で anon から呼べ、もう無い表を参照している）

### 5. 権限と RLS【本人 12:1x・形は AI 既定】

- 21 表と新しい表すべてで RLS を有効にする。policy は 1 表に 1 つ: `FOR ALL TO authenticated USING (user_id = (select auth.uid())) WITH CHECK (user_id = (select auth.uid()))`
- `exercise` だけは読みと書きで分ける。`FOR ALL` 1 つだと共有の行が読めない（M4）。どれも `TO authenticated`:
  - `FOR SELECT USING (user_id IS NULL OR user_id = (select auth.uid()))`
  - `FOR INSERT WITH CHECK (user_id = (select auth.uid()))`
  - `FOR UPDATE USING (user_id = (select auth.uid())) WITH CHECK (user_id = (select auth.uid()))`
  - `FOR DELETE USING (user_id = (select auth.uid()))`
  - 共有の行は API からはだれも書けない（MCP だけ）
- anon から全表・view・関数の権限を外す（TRUNCATE を含む。関数は PUBLIC からも外す・M1）。authenticated には表に SELECT・INSERT・UPDATE・DELETE だけ（TRUNCATE・REFERENCES・TRIGGER・MAINTAIN は与えない。MAINTAIN は PG17 の新しい権限・P12）、view には SELECT だけ。`service_role` の権限は触らない
- これから作る物が anon に開かないよう、既定の権限も外す（M1・M2）
  - 関数はグローバルの `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`（`IN SCHEMA` を付けない。public にも private にも効く）。【事実・計画レビュー P1】スキーマ単位の既定の権限は、作るときに組み込みの既定（関数は PUBLIC に EXECUTE）に足し算で重なるので、`IN SCHEMA public ... FROM PUBLIC` では PUBLIC の EXECUTE が消えない
  - `FOR ROLE postgres IN SCHEMA public` で: 表とシーケンスは anon から全部外す。authenticated から `TRUNCATE`・`REFERENCES`・`TRIGGER`・`MAINTAIN` を外す。関数は anon から `EXECUTE` を外す（計画 §1-3 の b2）
  - これからの表は自動で「authenticated に読み書きだけ」、関数は「authenticated・service_role だけ」になる
  - 既定の権限は作った人（grantor）ごとに 2 系統ある。MCP とダッシュボードの SQL は postgres で動くので、効くのは `FOR ROLE postgres` の行。`supabase_admin` の行は postgres からは変えられず、Supabase 側が作る物にだけ効く【事実】。`FOR ROLE postgres` は省いても同じ結果だが、明示する
- 新しい migration には GRANT と REVOKE を書く（0011・0012 までの「GRANT を書かない・Supabase の既定に任せる」をやめた・棚卸し §3-2。0014 から）。新しい表には RLS と policy も付ける。付け忘れは `checks.sql` が止める（repo の `CLAUDE.md` の本番の migration の節）
- 本番適用の確かめの期待値を逆にする（棚卸し §3-2）: anon は権限エラー（42501）、テスト用の 2 人目は 0 行、本人は全部。0 行になるのは表の権限を持つ authenticated で、anon は権限が無いので 42501 になる【事実】（M7。アプリの 42501 の文言 §7 とも合う）。確かめの一覧は §9（M28）。本番の結果（10-23 00:43）【事実】: anon キーだけでは表・view・RPC・INSERT がすべて 401（42501）・2 人目は全表・view が 0 行（共有の種目だけ見える）・本人は 0014 の前と同じ件数

### 6. 今あるデータの付け替え【本人 14:4x で決定済み: 2026-04-14 作成の Gmail のアカウント】

- 本人の行（365 − 種目の seed 159 = 206 行）を本人のアカウント（2026-04-14 作成の Gmail・本人 14:4x）に付ける。`exercise` は付け替えない（M4）
- 使わない v1 のユーザーは消さず、テスト用の 2 人目にする（ダッシュボードでパスワードを設定）【AI 既定・本人に一言で提示】（M27）。消さない理由: 外部キーが `ON DELETE CASCADE` なので、付け替えた側を取り違えて消すと 206 行が消える。消すなら複数人化が落ち着いた後、全表で `SELECT count(*) ... WHERE user_id = <消す側>` が 0 を確かめてから
- 本人の UID は公開の repo に書かない（M11）
  - migration ファイルには置き換えの印 `'__OWNER_UID__'` を書き、流すときに置き換えた SQL を MCP に渡す。メールアドレスで引く形（`WHERE email = ...`）も使わない
  - 先頭に `DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '__OWNER_UID__') THEN RAISE EXCEPTION 'owner uid not found'; END IF; END $$;` を置き、置き換え忘れ・取り違えを UPDATE の前に止める
  - 付け替えは `UPDATE <表> SET user_id = '__OWNER_UID__' WHERE user_id IS NULL` を `exercise` 以外の全表に（M4）
  - UID 本体は vault の memory（`project_life_tracker_auth_multiuser`）に書く
- バックアップ（M13）: Supabase の日次バックアップは Pro 以上で、Free には無い（プランは実装の前に確かめる）。`pg_dump` はサーバーと同じ 17 以上のクライアント（Homebrew の `libpq` か `postgresql@17`）で、ダッシュボードの接続文字列（セッションプーラー）から取る。接続のパスワードは本人が入れ、repo にも会話にも置かない。写しは repo の外に置く。取った写しを docker（M12 の `auth` のスタブ入り）に戻し、その上で migration を流す＝本物のデータでのリハーサルにし、写しが戻せることも同時に確かめる。戻すときはリハーサルで通った手順で戻す【AI 既定・取得は本人の操作】
- migration の順: 本番のバックアップ（上）→ `btree_gist` → UID の確かめ（上の `DO`）→ user_id を NULL 可で足す → 本人の UID で UPDATE（`exercise` を除く）→ NOT NULL（`exercise` を除く）・既定値 → 制約の付け替え（§1・§2）→ 種目の分け方（§3）→ 関数（§4）→ 権限と RLS（§5）→ v1 の残りを消す。0013 はバックアップの後、これより前に別に流す（§11・M14）
- 順の理由（M6）: `ADD COLUMN ... DEFAULT` は、ALTER の時点で評価した値を既存の行に入れる。`auth.uid()` は postgres から呼ぶと NULL なので、`ADD COLUMN user_id uuid NOT NULL DEFAULT auth.uid()` と 1 行で書くと、既存の行が NOT NULL で失敗する【事実】。実装で近道をしない
- 1 本の migration にし、途中で失敗したら全部戻る形にする（M10）
  - 【事実】MCP の `apply_migration` は SQL をそのまま Management API に送る（BEGIN／COMMIT を足さない）。本番の記録（`schema_migrations.statements`）は v2 の 12 本とも 1 要素で、SQL を文ごとに分けていない。PostgreSQL は、1 回の問い合わせに複数の文があり明示の BEGIN／COMMIT が無ければ、全体を 1 つのトランザクションにし、最初のエラーで前の文も戻す
  - 【推測】サーバーが SQL を 1 回で送っていれば、途中で失敗すると全部戻る。送り方は閉じた実装で見えない
  - 確かめ方: 実装の最初に、害の無い migration `probe_txn`（`CREATE TABLE public._txn_probe (x int); SELECT 1/0;`）を流す。流す前に本人へ一言伝える。失敗の後に `SELECT to_regclass('public._txn_probe')` が NULL なら 1 つのトランザクション。NULL でなければ `DROP TABLE` が要る。`list_migrations` に失敗した版が残るかも見て、残るなら運用の注意に書く。結果は 0007 の注記の代わりに docs に 1 行書く
  - 【事実・2026-10-19 18:2x 本番で確かめた】`probe_txn` は `22012: division by zero` で失敗し、`to_regclass('public._txn_probe')` は NULL（作った表も戻った）。`schema_migrations` に失敗した版の行は残らない（23 行のまま・`list_migrations` にも出ない）。→ `apply_migration` は 1 回の SQL を 1 つのトランザクションで流す。0014 に `BEGIN;`／`COMMIT;` は書かない。失敗した migration は記録に残らないので、直してそのまま流し直せる
  - 本文に `BEGIN;`／`COMMIT;` を書くのは、どちらの結果でも害が無い（サーバーが包んでいれば WARNING だけ）。確かめた後なら要らない
  - 運用の注意【事実・memory `reference_supabase_accounts`】: この migration は DROP（旧い外部キー・索引・制約・`user_profile.id`・v1 の関数）を多く含む。MCP は DROP を含む文で確認を求め、すぐ承認しないと `cancelled` で何も実行されない。流す前に本人へ「確認の画面が出たらすぐ承認して」と伝える。`cancelled` の後は、読むだけの操作で「何も変わっていない」を確かめる
- 戻し方（M15）: 逆の migration（RLS を外し、権限を戻し、制約を元に戻し、user_id を消す）を同時に書いておく
  - 安全なのは本人 1 人しかデータが無いうちだけ（2 人目が記録した後に user_id を消すと混ざる）。ファイルの先頭にそう書く
  - 置き場は `supabase/migrations/` の外（例 `supabase/rollback/0014_down.sql`）。番号付きの前進用と見間違えない名前にする
  - `schema_migrations` の `rollback` 列は使わない（MCP の `apply_migration` にその引数が無い）
  - バックアップから戻すのは最後の手段

### 7. サインイン（アプリ）【本人 12:3x・10-22 パスワードレスに変更】

**今の形**（2026-10-22 15:0x 本人「B（コード＋Google だけ）」→ 15:3x に作り替えた。本番で使っている。経過は計画の作業時間 10-22 15:3x〜）

- **画面と状態**: 起動 → `AuthStore` が `authStateChanges` の `.initialSession` を受けるまで起動画面 → セッションがあれば今の TabView（`.id(uid)`）。無ければサインインの画面。状態は「起動中」「未サインイン」「コードの入力（メールアドレス）」「サインイン済み（UID）」の 4 つ。データの読み込みは、サインイン済みでだけ始める（M20）
- **サインインの画面**: 上に「LifeTracker」の文字・見出し「サインイン・サインアップ」・枠線のメールアドレスの欄・アプリの青で塗った全幅の「コードを送る」・「または」の線・Google のボタン。中身は縦の真ん中（キーボードが出たら残りの高さの真ん中・足りなければスクロール）。画面の言葉は「サインイン」「サインアップ」「サインアウト」に揃える（「ログイン」「ログアウト」「新規登録」は使わない）。説明の一文は置かない（本人 10-22 15:1x「絶対にやめて。上部にログイン・サインアップ と書けばいいだけでしょ。」）
- **メールのコード**: `signInWithOTP(email:redirectTo:shouldCreateUser: true)` で 6 桁のコードを送る → コードの画面（見出し「入力したメールアドレスに届いた認証コードを入力してください」・送り先と「変更」・6 つの枠・主のボタン「認証」・60 秒の送り直し）→ `verifyOTP(email:token:type: .email)` でセッション
  - 登録とサインインは同じ流れ。はじめての人は、コードを確かめたときに登録が終わる。新規登録・確認・再設定・新しいパスワードの画面は無い。コードの期限は 600 秒（本人 10-22 15:0x・U9）
  - 【事実・GoTrue と supabase-swift 2.44.1 のソース】type `.email` は確認のトークンと Recovery のトークンの両方と比べるので、新しい人と登録済みの人の両方で通る。新しい人・確認がまだの人には「Confirm signup」、確認済みの人には「Magic Link」のテンプレートが使われる（本番の GoTrue の版が同じかは未確認）
  - 本番で確かめたのは登録済みの人の道（10-22 19:2x 本人のアカウント）。新しい人の道（Confirm signup のコードが届くか）はまだ（10-23 本人「後ででいい」「1は後回し。」）
  - 確かめている間に supabase-swift が流す `.signedIn` は使わず、処理の側がサインイン済みにする（片付けと初期データを 1 か所から 1 回ずつ呼ぶ）
  - メールに URL は入らない（テンプレートは `{{ .Token }}`。U7・U9）。`lifetracker://auth-callback` の受け口・PKCE・`redirectToURL` の設定は、テンプレートを替える前に届いた古いリンクのために残している。implicit 形式の戻りはセッションを作らない（ログインの CSRF を避ける）
  - サーバーのパスワードのサインイン（API）は Email の provider に含まれるので止められない。アプリには入口が無い
- **失敗の文言**（`AuthFailure`）: サインアップを閉じている「今はサインアップを受け付けていません」／Email の provider が無効「今はメールのコードでサインインできません」／`email_address_not_authorized`「このメールアドレスには、今はコードを送れません」／`email_address_invalid`（形式・決まった無効なアドレス・ドメインに MX か A が無いなど。送る前にサーバーが断る）「メールアドレスが正しくありません。確かめて、もう一度入力してください」（本人 10-22 19:4x）／コードの誤り・期限切れ「コードが違うか、期限が切れています。新しいコードを送ってください」／送りすぎ（429）「しばらく待ってから、もう一度お試しください」／通信「通信できませんでした。電波のよい所で、もう一度お試しください」
- **Google**: GoogleSignIn-iOS 10.0.0 で ID トークンを受け、`signInWithIdToken` で Supabase のセッションにする
  - nonce を渡す: 乱数（`SecRandomCopyBytes`）の SHA-256 の小文字の 16 進を Google の `nonce:` に、元の値を `OpenIDConnectCredentials(nonce:)` に。Supabase の「Skip nonce check」は OFF のまま（ID トークンの使い回しを防ぐ検査を残す）。設計の M19（Skip を ON）から変えた（計画 §2-3。9.0.0 で nonce を渡せるようになった）
  - Google Cloud に iOS 用と Web 用の 2 つのクライアント ID（本人 U2）。`Info.plist` の `GIDClientID` と逆順のクライアント ID の URL スキームは xcconfig から（値は公開の repo に書かない）。`CFBundleURLTypes` は `lifetracker` と合わせて 2 つ
  - 同じ確認済みのメールアドレスなら、メールのコードと同じ 1 人にまとまる（10-21 23:41 本人のアカウントで確かめた。本人は email と google の 2 つの identity）。手動の連携は無効のまま
  - Google の同意の画面はテストの状態なので、今 Google で入れるのはテストユーザーだけ（ほかの人に開くには公開が要る・§10）
  - ボタンは自前（ほかのボタンと同じ高さ 52・角丸 12 の枠線・GoogleSignIn-iOS に入っている公式の G・「Google で続ける」・Google のブランドの決まりの色）。決まりのフォント Google Sans は入れられないのでシステムのフォント（決まりから外れる 1 点）【AI 既定】
- **セッション**: supabase-swift が Keychain に持つ。【アプリのレビュー A15・10-21】Keychain の項目はアプリを削除しても残る見込み【推測】。削除はサインアウトではない。端末を人に渡すときはサインアウトする
  - クライアントの設定に `emitLocalSessionAsInitialSession: true`（端末のセッションを期限切れでもすぐ初期セッションとして流す。オフラインの起動で待たされない。計画 §2-1）
  - `AuthStore` は `authStateChanges` を 1 本だけ購読する。期限切れのセッションでもサインイン済みとして画面を出し、`.signedOut`（サインアウト・サーバーがセッション無効と返した）が来たときだけサインインの画面へ。更新がネットワークで失敗してもサインアウトにはしない（M20）
  - data source は今の共有のクライアントを使う（サインインすると同じクライアントにトークンが付く）。セッションが無いと anon キーで送るので、データの呼び出しは 42501 になる【事実・M20】
- **サインアウト**: 下のタブの最後の「プロフィール」タブの節「アカウント」（サインイン中のメールアドレスの下・確認つき）。本人 10-22 14:3x「プロフィールタブ」。分析の「プロフィールを設定」は近道として残す
  - `signOut()` は先に端末のセッションを消して `.signedOut` を流し、その後 `/logout` を呼ぶ。失敗しても端末側はサインアウト済みとして扱う【事実・M21】
  - 既定の `scope: .global` で、その人のすべての端末のセッションが消える【事実・10-22 19:5x 本番のログと supabase-swift のソース】。この端末だけにするなら `.local`。どちらにするかは決めていない
  - 片付け（`SignInSideEffects`）: App Group の `continuity.v1` を消す・別のキー `auth.signedIn.v1` を false・`WidgetCenter.shared.reloadAllTimelines()`・休憩の Live Activity を終える・`GIDSignIn.signOut()`。起動して端末にセッションが無いとき・サインアウトを経ずに人が変わったときも先に片付ける（A5・10-21 22:4x）
  - store の作り直しは TabView の `.id(session.user.id)`（人が変わったら SwiftUI が作り直す・M21）
- **データの誤りの文言**（`DataAccessError`・計画 §2-5）: 42501 は、端末にセッションがあれば `refreshSession()` を 1 回試して「確認できませんでした。もう一度お試しください」、セッションが無いときだけ「サインインし直してください」（P9。期限切れのセッションの更新がネットワークで落ちた直後も 42501 になるため）。`fetchTaps` は 42501 と PGRST3xx（JWT 系）を空にせず上に投げる（M8）
- **初回**: サインイン済みになったら UID ごとに 1 回 `ensure_user_defaults()`（§3）。失敗しても画面は出し、次の起動でまた呼ぶ。そのあとは今の画面のまま（新しい人の案内は §10）
- 【アプリのレビュー A13】「新しいパスワード」の途中で落とすとサインイン済みになる → パスワードレスで画面が無くなったので当たらない

**当時の案（10-22 より前。パスワード・確認と再設定のリンク。今は使っていない）**

- **画面**: 起動 → `AuthStore` が `authStateChanges` の `.initialSession` を受けるまでは起動画面 → セッションがあれば今の TabView。無ければサインインの画面（メールとパスワード／新規登録／パスワードを忘れた／Google で続ける）。データの読み込みは、セッションがある状態でだけ始める（M20）
- **メール＋パスワード**: 新規登録で確認メールを送り、本人がリンクを踏むと確認済みになる（本人の指示）。リンクはアプリの URL スキーム（例 `lifetracker://auth-callback`）に戻る（Universal Links は有料の Program が要るので使わない）。パスワードの再設定も同じ戻り方
  - 【2026-10-22 本人の決定で変更】確認も再設定も、リンクをやめて 6 桁のコード（テンプレートの `{{ .Token }}`・アプリで `verifyOTP`）。メールに URL が入らず、端末に依らず、カスタムスキームの横取り（アプリのレビュー A1）も無くなる。元の本人の指示「リンクを踏む」から変えた（本人「6桁のコードに変えたい」・確認も「確認もコードに（推奨）」）。下の PKCE・リンク・印の記述は、古いリンクの受け取りのために残す処理の説明として読む
  - PKCE で進める（M18・M23）: `SupabaseClientOptions.auth` に `redirectToURL: URL("lifetracker://auth-callback")` と `flowType: .pkce` を明示する。`Info.plist` に `CFBundleURLTypes` を足し、`onOpenURL { url in supabase.auth.handle(url) }` で受ける。カスタムスキームは他のアプリも同じ名前を名乗れるが、PKCE なら横取りされた `code` は端末にある verifier が無いと使えない
  - リンクは「サインアップした iPhone で開く」必要がある【事実・M18】。verifier はフローを始めた端末にあり、Mac のメールで踏むと失敗する（リンクは使い切り）。サインアップの後の画面に「このメールをこの iPhone で開いてください」と出す。メールのスキャナがリンクを先読みして使い切る問題も文書にある
  - 代案（M18）: メールの型を `{{ .Token }}`（6 桁）にし、アプリで `verifyOTP(email:token:type:)` を呼ぶ。確認も再設定も URL スキームに依らなくなる（型の変更と入力欄だけで、後から切り替えられる）。本人の言葉が「リンクを踏む」なので、まずリンクで作り、困ったらコードに替える
  - 再設定（M23）: `resetPasswordForEmail(email, redirectTo:)` → リンク → アプリ → `.passwordRecovery` で新しいパスワードの画面 → `auth.update(user: UserAttributes(password:))`【計画レビュー P2 で訂正: PKCE では `.passwordRecovery` が来ず `.signedIn` だけになる。アプリ側の「再設定を頼んだ」印で出し分ける。計画 §2-1】
  - 確認待ちの画面（M23）: サインアップしたメールアドレスを保ち、再送（`auth.resend(email:type:)`）のボタンに 60 秒の待ちを出す。登録済みのメールアドレスを入れても応答は存在を隠す形なので、画面は常に「確認メールを送りました」と出す
  - 確かめ方【推測・M18】: iOS のメールでリンクを踏むと、Safari が Supabase の `/auth/v1/verify` を開き、`lifetracker://auth-callback?code=...` に転送し、「LifeTracker で開く」の確認が出てアプリに戻る見込み。実機で 1 回確かめる。シミュレータでは `curl -I` で転送先の URL を取り、`xcrun simctl openurl booted '<転送先>'` で代わりにする
- **Google**: Google の公式の部品（GoogleSignIn-iOS）で ID トークンを受け、`signInWithIdToken` で Supabase のセッションにする。Google Cloud で iOS 用の OAuth クライアントを作る作業は本人（手順は AI が書く）。
  - 要るもの（M19）: Google Cloud で **iOS 用と Web 用の 2 つ**のクライアント ID を作る。ダッシュボードの Google provider の「Client IDs」に 2 つをコンマ区切りで入れ、「Skip nonce check」を有効にする（GoogleSignIn-iOS には nonce を渡す口が無く、Supabase の手順もこの形）。`Info.plist` に `GIDClientID` と、逆順のクライアント ID（`com.googleusercontent.apps.…`）の URL スキームを足す（`lifetracker://` と合わせて `CFBundleURLTypes` は 2 つ）。OAuth の同意画面は「テスト」のままにし、本人の Gmail をテストユーザーに入れる【推測】。手順は AI が書き、操作は本人【計画 §2-3 で変更: GoogleSignIn-iOS 9.0.0 以上は nonce を渡せるので、nonce を渡し「Skip nonce check」は OFF のまま】
- **サインインの画面の作り直し（2026-10-22 本人「サインイン画面のUI・UXもひどい」）**: どこが悪いか（本人が選んだ・AI が挙げた 4 つ全部）= 設定の画面に見える（一覧の行が並ぶだけ・アプリの顔が無い・見出しが重なる）／主のボタンが分からない（入力欄と同じ灰色の行で押せないように見える）／Google の扱い（一番下の行で目立たず、Google の見た目でもない）／要らないものが出ている（閉じている新規登録の入口・設定の行の形の「パスワードを忘れた」）
  - 本人の参考（00:29 に 3 枚。本人の iPhone のスクショ `~/Downloads/IMG_2263〜2265.PNG`・repo には入れない）【事実・画像で見た】:
    - 共通: 最初の画面はメールアドレスの欄 1 つだけ（識別子が先。パスワードは次の画面＝Amazon・Google、コード＝Slack）／入力欄は枠線の 1 本／主のボタンは塗りつぶしの 1 つ（Slack 緑・Amazon 黄の全幅、Google 青の丸いボタンを右寄せ）／補助の操作は文の中の青い文字のリンク／上に大きな見出しと短い説明（Amazon・Google はロゴも）
    - Slack（アプリ）: 中央の見出し「メールアドレスを入力する」＋説明、枠の欄、全幅の緑「メールでサインインする」、「または」の線、Google と Apple の枠線のボタンを横に 2 つ（記号だけ）、下に「何かお困りですか？ ワークスペースの URL を…」などの文字のリンク
    - Amazon（Web）: 中央上にロゴ、左寄せの大見出し「サインインまたはアカウントを作成」、欄、全幅の黄「次に進む」、規約の文、「ヘルプが必要ですか？」
    - Google（Web）: 左上に G、左寄せの大見出し「ログイン」＋「お客様の Google アカウントを使用」、欄、「メールアドレスを忘れた場合」、左下に「アカウントを作成」・右下に丸い「次へ」
  - 【2026-10-22 15:0x 本人の決定で変更】サインインはメールの 6 桁のコード＋Google だけ（パスワードレス。資料 `auth-method-research-2026-10-22.md`）。下の「2 段（メール → パスワード）」と新規登録・再設定の画面はなくなる。1 段目はメールアドレス →「コードを送る」→ コードの画面 → サインイン済み（はじめての人はここで登録）
  - **採った形（2026-10-22 本人の決定。計画の「本人の決定」00:3x・01:2x）**: Slack 型の 2 段（メール →「次へ」→ パスワード）。上に「LifeTracker」の文字・中央の見出し（その下の説明は本人「または〜 の部分は不要。」で消した）・枠線の欄・アプリの青で塗った全幅の主のボタン・「または」の線・ほかのボタンと揃えた自前の Google のボタン（高さ 52・角丸 12・GoogleSignIn-iOS に入っている公式の G・Google のブランドの決まりの色）・補助は文字のリンク。閉じている間は新規登録の入口を出さない。確認と再設定はコードの画面（6 つの枠）
    - 【AI 既定】文言は「Google で続ける」／フォントはシステムのもの（決まりの Google Sans は入れられない。決まりから外れる 1 点）／暗い画面では G をそのまま暗い塗りに置く／コードの画面から戻ったとき 1 段目のメールアドレスを残す（メモリだけ）

### 8. Supabase の設定【一部は本人の操作】

**今の設定**（2026-10-23。本人の操作は計画 §0-4 の U3・U7・U8・U9。画面の名前は `auth-multiuser-user-steps.md`）

- メール（Email の provider）: 有効・メールの確認 ON。テンプレート（Confirm signup・Magic Link ほか）は 6 桁のコード `{{ .Token }}`（U7・U9。本人の文言「有効期限は 10 分です。」）。Email OTP の期限 600 秒
- サインアップ: ON（本人 10-22 12:0x「今すぐ開ける」・12:1x「当たり前だが、誰でもサインアップできるようにしたい。」）
- 送り手: 送るためだけの Gmail の SMTP（U8・10-23 01:0x 本人「U8済み」。0014 の後に入れた）。これで誰のアドレスにも送れる。外部の SMTP の初めの上限は 1 時間 30 通（変えられる）。ドメインを買って Resend などに替えるのは、ダッシュボードの SMTP の設定だけでアプリは変わらない（本人 10-22 14:2x）
- Google の provider: 有効・iOS と Web の 2 つのクライアント ID・「Skip nonce check」OFF（§7）
- 戻り先の URL: 「Additional Redirect URLs」に `lifetracker://auth-callback`（古いリンクのため。Site URL は既定のまま）
- 手動の連携 OFF・匿名のサインイン OFF（M24）
- パスワードの最低の長さ・文字種（12 文字・英字と数字）はサーバーに残るが、アプリでは使わない
- 漏えいしたパスワードの検査は Pro 以上の機能なので使わない（advisor の WARN が 1 件残る）

**当時の案と経緯（10-22 より前。下の事実の表と「メールの送り方」は今も当てはまる）**

- メールの確認を有効にする（本人の指示）。手動の連携は無効のまま（既定の状態は文書に無いので、本人のダッシュボードで確かめる）。匿名のサインインは無効（M24）
- 【2026-10-22 変更】サインインはパスワードレス（メールのコード＋Google）になったので、下のパスワードの長さ・文字種は使わない（サーバーの設定は残る）
- パスワードの最低の長さ 12 文字・英字と数字を含む（設定でき、プランの制限は文書に無い）。今ある v1 のユーザーの古いパスワードには効かない（次に変えるときから）。漏えいしたパスワードの検査は Pro 以上の機能なので使わない（advisor の WARN は残る）（M24）
- 確認メール: 標準のメール送信は、チームのメンバーのアドレスにしか送らず、1 時間 2 通。本人のサインインのアドレスがメンバーでなければ、外部の SMTP が今から要る（本人に聞く 1 問 → 14:4x 本人「同じ」で、今は要らない）。テスト用のユーザーは、2 通／時に当たらないよう、ダッシュボードの「Add user（自動確認）」で作る（M24）
- 戻り先の URL: 「Additional Redirect URLs」に `lifetracker://auth-callback` を入れる。Site URL（既定 localhost:3000）は変えないので、アプリは `redirectTo` を必ず渡す（M23・M24）。Google の provider を有効にし、クライアント ID を入れる（本人の操作。細部は M19 で未反映）
- 新規登録【AI 既定・本人に一言で提示】（元の問い D）: 複数人化が終わっても、配る準備（Program・外部の SMTP）ができるまで閉じる
  - 【2026-10-22 12:0x 本人「サインインの口がないのはなぜ？開けておいて。」】アプリの入口は開けた（`AuthFeatures.isSignUpOpen = true`）。ダッシュボードのトグルは OFF のままで、送るとサーバーが断る。トグルをいつ開けるかは本人に聞いた（計画の「本人の決定」）→ 本人「今すぐ開ける」（0014 の前に開けると新しいアカウントからも本人のデータに届く、を承知の上）。ダッシュボードのトグルも本人が ON にする。上の「閉じる」は取りやめ
  - 【2026-10-22 12:1x 本人「当たり前だが、誰でもサインアップできるようにしたい。」】目標は誰でも登録できること。標準のメール送信の間は、メールで登録を終えられるのは Supabase の組織のメンバーだけ（文書: custom SMTP が無いと「チームに属さないアドレスには送らない」・`email_address_not_authorized`）、Google は同意の画面がテストの状態なのでテストユーザーだけ。外部の SMTP を入れると、全部のアドレスに送り、はじめは 1 時間 30 通に制限される（変えられる）【事実・https://supabase.com/docs/guides/auth/auth-smtp 】。順: 0014 → 外部の SMTP → Google の公開（計画の「本人の決定」）
  - 理由（本人の「逆に閉じる意味は？」への答え。食事の設計の本人回答にも残っている）: 登録の窓口は URL と anon キーで誰でも呼べる／今は配る手段が無いので、開けても使う人がいない／AI の入口の費用
  - 戻し方: ダッシュボードのトグル 1 つで開ける
  - 端の場合【推測・M24】: 閉じると、新しい Google アカウントの初回のサインインも止まる見込み。本人の Google のアドレスがメールの方と違うと、新規登録が開いていれば Google は空の別のユーザーになり、閉じていれば初回で止まる見込み。どちらも本人に聞く 1 問で分かる【14:4x 本人の Gmail は Google と同じ。計画レビューで事実: 新規登録 OFF は新しく作る分岐だけを止め、同じ確認済みのメールの連携は通る】

**事実（レビュー M24 の表。公式の文書で確かめたもの）**【事実】

| 設定 | 事実（公式の文書） | 設計への影響 | 出典 |
|---|---|---|---|
| パスワードの最低の長さ・文字種 | 設定できる。「8 文字未満は推奨しない」「数字・大小の英字・記号を要求する最も強い選択肢を推奨」。**プランの制限は書かれていない** | 12 文字・英字と数字は設定できる見込み。既存の v1 ユーザーの古いパスワードには効かない（次に変えるとき） | https://supabase.com/docs/guides/auth/password-security |
| 漏えいしたパスワードの検査（HIBP） | 「**Pro Plan and above**」 | 設計どおり使わない（advisor の WARN は残る） | 同上 |
| 標準のメール送信 | 「プロジェクトのチームに属さないアドレスには配信を拒否」「**1 時間 2 通**（予告なく変わる）」「SLA 無し。探索・テンプレートの試験・デモ用。他のすべての用途で custom SMTP を強く勧める」 | 本人のサインインのアドレスがチームのメンバーでなければ、確認メールが届かない（本人に聞く 1 問）。テスト中は 2 通/時に当たるので、テスト用ユーザーはダッシュボードの「Add user（自動確認）」で作る | https://supabase.com/docs/guides/auth/auth-smtp |
| Auth のレート制限 | メール 2 通/時（標準）。`/verify` 30 回/5 分、サインアップ・再送・回復 30 回/5 分（IP ごと）、トークン更新 150 回/5 分、同じ人への OTP・マジックリンクは 60 秒に 1 回 | 実機の確かめの回数を見積もる | https://supabase.com/docs/guides/auth/rate-limits |
| 戻り先 URL の許可 | 「Additional Redirect URLs」に `[スキーム]://[ホスト]` を入れる。ワイルドカード可。`redirectTo` 無しのときは Site URL（既定 localhost:3000）へ | `lifetracker://auth-callback` を入れる。Site URL は変えなくてよいが、`redirectTo` を必ず渡す | https://supabase.com/docs/guides/auth/redirect-urls ／ https://supabase.com/docs/guides/auth/native-mobile-deep-linking |
| Google provider | Client IDs に **iOS と Web の 2 つ**。Skip nonce check を有効 | M19（本人の操作を含むので未反映） | https://supabase.com/docs/guides/auth/social-login/auth-google?queryGroups=platform&platform=ios |
| 同じメールアドレスの自動連携 | 「同じメールアドレスの identity を 1 人のユーザーに自動で連携」。未確認のメールアドレスには連携しない（乗っ取り防止） | 本人のメールアドレスと Google のアドレスが同じなら 1 人にまとまる。違えば別のユーザー（空のデータ）になる → 本人に聞く 1 問 | https://supabase.com/docs/guides/auth/auth-identity-linking |
| 手動の連携 | 設定で有効にできる。**既定の状態は文書に書かれていない**【設計の「既定で無効」は本人のダッシュボードで確かめる】 | 無効のまま | 同上 |
| 新規登録 | 「無効にすると既存のユーザーだけがサインインできる」。OAuth への影響は書かれていない【推測: 新しい Google アカウントの初回サインインも止まる】 | AI 既定で閉じる（上） | https://supabase.com/docs/guides/auth/general-configuration |
| メールの確認 | 「有効にすると初回のサインインの前にメールアドレスの確認が要る」。provider の設定の中にある | 本人の指示どおり有効 | 同上 |
| 6 桁コード | テンプレートで `{{ .Token }}` を使える。リンクの先読みで消費される問題の回避策として文書にある | M18 の代案（§7） | https://supabase.com/docs/guides/auth/auth-email-templates |
| バックアップ | 日次バックアップは Pro 以上。Free は定期的な書き出しを推奨 | M13（本人の操作を含むので未反映） | https://supabase.com/docs/guides/platform/backups |

**メールの送り方とリンクの中身（2026-10-22 00:04 本人の問い「supabaseでのSSO設定であればメールはSupabase Authから送信されるしかないの？また、パスワードのリセットリンクは私のプロジェクトリンクが必ず入ってしまうの？」への答え・Supabase の文書で確かめた）**【事実】

- 送り手: 標準は Supabase の組み込みの送信（実際の送り手は `noreply@mail.app.supabase.io`・認証のログで確かめた）。チームのメンバーのアドレスにしか送らず、1 時間 2 通、SLA 無し、本番向けではない。代わりに (1) 外部の SMTP（Resend・SendGrid・Mailgun・AWS SES など。入れると全員に送れる・最初は 1 時間 30 通で、上限は設定で変える）か、(2) Send Email Hook（組み込みの送信を丸ごと置き換え、自分の関数・サービスから送る）にできる。文書にプランの制限は書かれていない（https://supabase.com/docs/guides/auth/auth-smtp ・ https://supabase.com/docs/guides/auth/auth-hooks/send-email-hook ）
- なお、Supabase の「SSO」は SAML の企業向けサインイン（別の機能）。今回入れたのはメール＋パスワードと Google（ソーシャルログイン）で、Google のサインインはメールを送らない
- リンクの中身: 標準のテンプレートの `{{ .ConfirmationURL }}` は `https://<プロジェクトの ref>.supabase.co/auth/v1/verify?token=...&type=...&redirect_to=...` の形（文書の例）。必ずではない:
  - テンプレートを `{{ .Token }}`（6 桁のコード）にすれば、メールに URL が入らない。アプリで `verifyOTP(email:token:type:)`（設計 §7 の代案・アプリのレビュー A1 の案と同じ）
  - `{{ .TokenHash }}` で自分のリンクを組める（自分のドメインのページで `verifyOtp(token_hash)` を呼ぶ形）。自分のドメインとページが要る
  - Custom Domains（`api.example.com` の形）・Vanity subdomain（`my-brand.supabase.co` の形・試験的）は「有料プランのプロジェクトの有料の追加」（https://supabase.com/docs/guides/platform/custom-domains ）。Free では使えない
- プロジェクトの URL は秘密ではない: アプリの中（Info.plist の `SUPABASE_URL`）に入り、anon キーと同じく公開される前提。守りは RLS（0014）で、URL を隠すことではない。URL を隠すのは見た目・信用（なりすましのメールに見えない）の問題【推測】。なお ref は公開 repo の `docs/untimed-tasks-implementation-plan.md`（commit 済み）にも 1 か所ある【事実】

前提の節のうち、レビューで確かめていないもの: Sign in with Apple・パスキーが有料の Program を要すること（Apple の対応表はテキストで取れず未確認）、手動の連携の乗っ取りの報告（未確認。無効のままなら影響なし）。

### 9. テストと確かめ方【AI 既定】

- **テストは本番に一切つながない**（M22）
  - 今【事実】: 単体テストの TEST_HOST はアプリ本体。UI テストは引数なしで起動する。共有の scheme は repo に無いので、起動の引数は Xcode の個人設定かコードで渡すしかない
  - 【推測】サインインの後はセッションが Keychain に残る。シミュレータで本人がサインインしたまま単体テストを走らせると、TEST_HOST のアプリが本物のセッションで本番を読みに行く
  - `LifeTrackerApp.makeDataSource()` で、テストの環境変数（`XCTestConfigurationFilePath` か `XCTestBundlePath`）があれば、`#if DEBUG` でメモリ上の data source と「サインイン済み扱い」にし、Supabase のクライアントを作らない
  - UI テストはコードで `app.launchArguments = ["-mock-day", "-mock-workout", "-mock-auth"]` を渡す。`-mock-auth` はサインインの画面を飛ばす起動引数（DEBUG だけ）
- メモリ上の data source は 1 人のまま（UI の確かめ用）。人を分ける規則は DB 側で確かめる
- **DB の確かめ（docker の Postgres で migration を流して）**
  - `auth` のスタブを作る（M12）。素の `postgres:17` には `auth.users`・`auth.uid()`・ロール `anon`／`authenticated`／`service_role` が無く、新しい migration は最初の `REFERENCES auth.users(id)` で止まる【事実】。`supabase/test/auth_stub.sql`（migration ではない置き場）に `CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS; CREATE SCHEMA auth; CREATE TABLE auth.users (id uuid PRIMARY KEY); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;`（本番の定義を写した形）と、`extensions` スキーマ（0001 が使う）を書く
  - `supabase start`（CLI・本物の auth 付き）の方が忠実だが、repo は CLI を使わない方針（0001 の注記）なので、スタブで足りる【推測】
  - 人の切り替え: `SET ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"<uuid A>"}', true);` で A になる。テスト用のユーザーは `INSERT INTO auth.users VALUES (gen_random_uuid())` で 2 件
  - 見ること: 2 人のテスト用ユーザーで片方の行がもう片方から 0 行、`SET ROLE anon` で 42501、全関数が本人の行だけを書く、§2 の一意が人ごとに効く、睡眠の重なりが人ごとに効く、セットの削除と並べ替えが通る（M3 の `SET CONSTRAINTS`）
  - 【今の形】`supabase/test/run.sh`: `postgres:17` に `auth_stub.sql` → 0001 から全部 → `plpgsql_check` → `multiuser_test.sql`（計画 §1-5 の 1〜10）→ `checks.sql`（RLS・権限・既定の権限・関数・外部キー・0015 の日。本番でも同じものを読むだけで流す）。`--rollback <番号>` は戻しの差分、`--dump <写し> --from <番号> --owner <UID> --grow <表>=<N>` は本番の写しでのリハーサル（行数の照合つき）
  - RLS の付け忘れは機械的に見る: `SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND NOT relrowsecurity`（0 行）と `SELECT tablename FROM pg_tables WHERE schemaname = 'public' EXCEPT SELECT tablename FROM pg_policies`（0 行）
- **本番適用の確かめ**（MCP で読むだけ。1 セットにして実装計画に書く・M28）
  1. RLS: 上の 2 つの SQL が 0 行
  2. 権限: 全表・view で `has_table_privilege('anon', ..., 'SELECT')` = false。`authenticated` は SELECT／INSERT／UPDATE／DELETE = true・TRUNCATE = false。全関数で `has_function_privilege('anon', ..., 'EXECUTE')` = false（PUBLIC 経由も含めて判定される。例 `public.todo_fetch(date,date,date)`・M1）。`SELECT defaclrole::regrole, defaclobjtype, defaclacl FROM pg_default_acl WHERE defaclnamespace = 'public'::regnamespace` に anon が無い（M2）【計画レビュー P1: これだけでは PUBLIC の EXECUTE を見落とす。計画 §1-5 の 10】
  3. 形: `user_id IS NULL` の件数が `exercise` 以外で 0。`workout_training_day` の `reloptions` に `security_invoker=true`。`pg_extension` に `btree_gist`。関数の `proconfig` が全部 `search_path=`。同じ名前の関数の重なりが 0（0012 の確かめと同じ）
  4. advisor（security）: RLS の ERROR 0・view の ERROR 0・search_path の WARN 0・SECURITY DEFINER の WARN 0（v1 の 6 関数を消した後）
  5. アプリ: 本人でサインインして全タブ・ウィジェット。テスト用の 2 人目（使わない v1 のユーザー・M27）で全タブが空。anon の `curl`（`apikey` だけ）で 401／403（42501）
  - 注意【事実】: RLS は MCP（postgres）には効かないので、確かめの SELECT は今までどおり全行が見える。「MCP で見えるから RLS が効いていない」と取り違えない
  - 本番の結果（10-23 00:43・計画の作業時間）: checks 31 項目すべて t・関数の定義の md5 がリハーサルと同じ・本人の行は 0014 の前の件数と一致・2 人目は 0 行・anon は 401・advisor は漏えいしたパスワードの検査の WARN 1 件だけ
- **MCP と service キーで書くときの注意**（SQL レビュー S6・S10）【事実】
  - MCP（postgres）で行を入れるときは `user_id` を明示する（UID は vault の memory。repo には書かない）。書き忘れると、`exercise` 以外は NOT NULL で止まる。`exercise` は NULL 可なので、`user_id` を書かないと共有の種目になる（全員の一覧に出る）。本人だけの種目は `user_id` = 本人を書く。共有の種目を足すのは migration で（0016 と同じ）
  - `service_role`（service キー）は RLS を越えるが、`private` の関数の EXECUTE を持たず、`auth.uid()` も NULL になる。Edge Function などで service キーから RPC を呼ぶ日は、`private` の EXECUTE を足し、`user_id` を引数で明示する形が要る（食事の AI の段階 1c で効く）
- シミュレータで全タブ（予定・トレーニング・睡眠・プロフィール・ウィジェット）を、サインインした状態とサインアウトした状態で確かめる
- docs の更新【10-23 段階 4 で済み。直した所の一覧は計画 §4-1】: 「RLS 無効」の記述・INV-2 などの 1 人前提・spec.md の「個人ツール」・本番適用の手順の期待値（§5）・`meal-weight-design.md` の user_id の記述（棚卸し §3-4）。加えて次の 3 つ
  - `gymwork-alignment-design.md` の R-3 の周り: 「MCP の INSERT は `user_id` を明示する（UID は memory）。子の表は複合の外部キーが持ち主の食い違いを止める」。種目の自作は `exercise`（`user_id` = 本人）、アーカイブ・メモは `exercise_preference`。アプリから自作できるようにするかは今回の範囲外（M25）
  - `apply_migration` のトランザクションの確かめの結果（0007 の注記の代わり・M10）
  - `meal-weight-design.md`（食事の実装の前に直す・M26）: §2 の冒頭に次の一覧を注記し、:242 を「10-19 の決定で上書き」と直す
    - 1 人前提の形が残っている表: `nutrition_settings`（`id = 1` の CHECK。D1 と同じ）、`meal_day_status`（`day` が主キー。D3 と同じ）、`body_fat_estimate`（`recorded_on` が主キー。D2 と同じ）、`nutrition_goal`（`effective_from` が UNIQUE。D4 と同じ）、`ai_usage`（`(day, kind)` が主キー）
    - `food_item`: 店の行は共有・自分の行は人ごと（種目の案 1 と同じ形）。`UNIQUE (source, brand, name, variant)` と `jan_code` の部分 UNIQUE は、自分の行に `user_id` を含める
    - AI の Edge Function は JWT（`Authorization: Bearer`）で人を特定し、`ai_usage` を人ごとに数える。「合言葉のヘッダー」は JWT で代わりにできる

### 10. 将来ほかの人に使ってもらうときに残る点（この作業ではしない）

【10-23 更新】サインインと人ごとのデータは済み（0014・パスワードレス）。メールの送り手も U8 で誰にでも送れる。下は配る前に残る点（いつ配るかは決まっていない）。

- 配る手段: Apple Developer Program（TestFlight・App Store）。入ると Sign in with Apple・パスキー・Universal Links も使える
- 審査用の入り方（審査ガイドライン 2.1(a)）: メールのコードと Google だけでは、審査の人が入る口が無い。審査用のアカウントの入り方を決める（`auth-method-research-2026-10-22.md`）
- アプリの中でのアカウントの削除（5.1.1(v)）: アカウントを作れるアプリは、アプリの中から削除できる必要がある。今は無い。`auth.users` から消すと、全表の行は `ON DELETE CASCADE` で消える（§1）
- Google の同意の画面を「テスト」から公開に（今はテストユーザーだけが Google で入れる）
- ボットのサインアップへの守り（CAPTCHA）。サインアップは開いていて、URL と anon キーで誰でも呼べる
- App Store で配るときは Sign in with Apple も要る（本人 10-22 15:0x「Program に入るときに足す（推奨）」）。審査ガイドライン 4.8 は、Google のような第三者のログインで主なアカウントを作るアプリに、同等のログイン（名前とメールだけ・メールを隠せる・広告目的で集めない）も出すよう求めている【事実】。配る段階で足す（M29。https://developer.apple.com/app-store/review/guidelines/#login-services）
- ~~確認メール: 外部の SMTP~~ → 済み（U8・送るためだけの Gmail の SMTP。§8）
- 強さの基準の数字（strengthlevel.com から写したもの）は「個人用アプリの中だけで使う・再配布しない」前提（棚卸し §3-3）。配る前に外すか置き換える【要確認・そのとき】
- 店の栄養表示（食事の段階 3）は私的使用の前提。人ごとに持つか、配る前に扱いを決める
- 日は JST 固定・週は月曜始まり（A7）、INV-10 の本人の決めた値（刻み・休憩 3:00）、オンボーディングが無いこと（棚卸し §3-3）
- 人ごとの AI の上限（食事の §4。`ai_usage` に user_id）

### 11. 実装の分け方（案）【AI 既定】

1. **DB**
   - 最初に `apply_migration` のトランザクションを確かめる（§6・M10。流す前に本人へ一言）
   - 0013（旧列と `pattern_template_membership` の削除）を先に流す。消す表に `user_id`・RLS を付けるのは無駄で、戻しの migration も増えるため。0006 以降の新ビルドで読み書きが確かめられていることが前提【推測】。DROP を含むので、§6 の確認の画面の注意が要る（M14）
   - 複数人化は 0014（§1〜§6）。食事は 0015 以降へずらす（M14）。戻しのファイル（§6・M15）と、docker での確かめ（§9・M12）
2. **アプリ**: サインインの画面・`AuthStore`（`.initialSession` を待つ・M20）・URL スキームと PKCE の設定（M23）・Google・サインアウト（`.id`・ウィジェットの印・M21）・エラーの文言と `fetchTaps`（M8）・`ensure_user_defaults()` の呼び出し・upsert の衝突先・種目の view `exercise_for_user` への切り替え（M16）・テストの環境変数と起動引数（M22）
3. **本番**: バックアップ → migration（UID の印を置き換えて渡す・M11。確認の画面はすぐ承認してもらう・M10）→ 本人のアカウントでサインイン → §9 の本番適用の確かめ（M28）

## 本人に聞くこと（1 問。レビュー §7）【10-19 14:4x に回答済み。答えは冒頭の「本人の決定」】

レビューの見直しで、元の問い B と C を 1 問にまとめた。A と D は AI 既定にし、下の「AI 既定として本人に知らせる」に移した。

- **問い（元の B＋C）**: サインインに使うメールアドレスは次のどれですか。(1) v1 の 2 件のうち、作った日が 2026-04-14 の方 (2) 04-20 の方（JST。UTC では 04-19） (3) 新しいアドレス。あわせて、そのアドレスは Google のアカウントと同じか、Supabase のチームのメンバー（ダッシュボードに入っているアドレス）か
  - これで決まること: 206 行の付け替え先（§6）／Google と 1 人のユーザーにまとまるか（同じ確認済みのアドレスなら自動でまとまる。違えば Google は空の別のユーザー）／標準のメール送信で足りるか（チームのメンバーでなければ外部の SMTP が今から要る）
  - (3) なら、ダッシュボードの「Add user」で先に作ってから migration に入る。選ばなかった v1 のユーザーはテスト用の 2 人目として残す（M27）

あわせて頼む本人の操作（実装のときに頼む。M13 は §6、M19 は §7 に 14:4x に反映）: 本番のバックアップの取得（M13）、Google Cloud とダッシュボードの設定（M19）、本番 migration の確認の画面の即時承認（M10）。

## AI 既定として本人に知らせる（違えば言ってもらう）

- **種目（元の問い A）**: 159 件は全員で共有のマスタにし、自作の種目・アーカイブ・メモは人ごとにする。アプリは読む先を view に変えるだけで、画像と強さの基準は今のまま（§3・案 1＋M16）。表の形なので、後から変えるには migration が要る
- **新規登録（元の問い D）**: 複数人化が終わっても、配る準備（Program・外部の SMTP）ができるまで閉じる。ダッシュボードのトグル 1 つで開ける（§8）【10-22 12:0x 本人「今すぐ開ける」で取りやめ。今は開いている】
- **使わない v1 のユーザー（M27）**: 消さずに、テスト用の 2 人目にする。付け替えた側を取り違えて消すと、記録ごと消えるため（§6）
- 聞かなくてよいと判断したもの（レビュー §7）: 確認メールをリンクにするか 6 桁コードにするか（本人の言葉がリンク。後から替えられる・M18）、`ensure_user_defaults` を RPC にするかトリガーにするか（RPC・M9）、v1 の残りの 6 関数を消すか（消す）、0013 を先に流すか（先に流す・M14）

## 作業時間

- 2026-10-19 13:4x このファイルを作成。棚卸しをサブエージェントに依頼（13:38〜13:51）
- 2026-10-19 14:0x 設計の下書き
- 2026-10-19 14:32〜14:37 レビュー（M1〜M30）の「AI が直してよい点」と M24・M29 を反映。見出しを「設計（レビュー反映・本人未確認）」に、本人に聞くことを 1 問（B＋C）に、A・D・M27 を AI 既定に（サブエージェント）
- 2026-10-19 14:4x 本人回答（今のデータは 2026-04-14 作成の Gmail のアカウント）を記録。M13・M19 を §6・§7 に反映
- 2026-10-19 14:4x 本人「実装計画へ」→ 14:55 `auth-multiuser-implementation-plan.md` の下書き（設計から変えた 3 点は計画の「本人に聞くこと・知らせること」）→ 15:0x〜15:4x deep-task のレビュー（P1〜P24・高 2）→ 15:4x 計画に反映し、設計の各節に注記
- 2026-10-23 05:2x 段階 4（計画 §4-1）: 見出しを本番適用済みに・§1 の外部キー（19 本の中身・0015 の形）・§2 D5 と A3・§3 の 160 件・§5 の権限と既定の権限・§7 と §8 を今の形（パスワードレス）にして前の案を畳んだ・§9 に今の確かめと S6・S10・§10 に配る前に残る点
