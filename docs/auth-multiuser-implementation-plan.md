# サインインと複数人化 実装計画（2026-10-19・レビュー反映・本人 OK 17:0x・18:23 着手）

土台: `auth-multiuser-design.md`（以下「設計」。§ は設計の節）と棚卸し `auth-multiuser-inventory-2026-10-19.md`。食い違う所は設計の本人決定が正、細部はこのファイルが正。2026-10-19 14:5x 本人「実装計画へ」で着手。レビュー `auth-multiuser-plan-review-2026-10-19.md`（P1〜P24・高 2・中 10・低 12・本人に聞く点なし）を 15:4x に反映した。括弧の P 番号はそのレビューの番号。

凡例: 【本人】【AI 既定】【要確認】【事実】【推測】

## 前提

- 本番 DB（personal プロジェクト）は、読むだけの SQL のほかは触れない。本番に流すもの（段階 0 の確かめの migration・0013・0014）は、本人 OK の後に、流す前に一言伝えてから流す
- commit・push は本人の依頼の後。段階 0 の commit は計画の OK に含める（本人 14:0x の決定）。push はしない
- 公開 repo（Ryu0705/life-tracker）に、本人の UID・メールアドレス・キー・Bundle ID・Google のクライアント ID を書かない。UID は vault の memory、クライアント ID は gitignore 済みの `LifeTracker.xcconfig`
- 今の挙動は変えない。変わるのは、サインインの入口と、データが人ごとになることだけ。既存の単体テストは、42501 の文言（§2-5）を除いて全件そのまま通す
- 本番の順序（P4）: 新しいビルドを作る → バックアップとリハーサル → **新しいビルドを実機に入れ、サインインの画面まで見る** → 0013 → 0014 → アプリを起動し直す
  - 先に入れる理由: 署名・インストールの失敗が DB を変える前に分かる。0014 の後に「何も動かない時間」が起動し直す数秒で済む
  - 0014 の前の DB でも、新しいビルドの予定・睡眠タブは動く（authenticated は全表に権限があり、RLS も無い）【事実・レビュー】。動かないのはトレーニングタブ（種目の view が無い）と、プロフィール・体重・週の目標の保存（`user_id` 列が無い）だけ。だから入れるのは流す直前にし、トレーニングの記録中には流さない
  - その間に自動で書かれた行（前日のセッションを閉じる等）は `user_id` が空になるが、0014 の e（`WHERE user_id IS NULL` を本人に）が拾う
  - 0014 の後、今のビルドは何も読めない（anon の権限を外すため。読み書きがすべて 42501）
  - 戻すときは、戻しの SQL（§1-4）と今のビルド（commit から作る）を一緒に戻す
- 作業は repo の `CLAUDE.md` の S 級の決まりに従う: 親が設計を確定してからサブエージェントに渡す・**1 件ずつ直列**（DB を先に終え、アプリはその後。アプリは 0014 の最後の名前に依る）・BUILD SUCCEEDED だけで満足せず親が差分を読む（P21）

## 完了条件

1. docker で、0001〜0014 を空の DB に流して全部の確かめが通る。本番の写しにも 0013・0014 を流して通る（リハーサル）
2. 戻しの SQL を流すと、0014 の前と同じ形に戻る（`pg_dump --schema-only` の差分が 0）
3. 単体テストが全件通る。UI テストが本番につながずに通る
4. シミュレータで、サインインした状態とサインアウトした状態の全タブ（予定・トレーニング・睡眠・プロフィール）とウィジェットを確かめる
5. 本番で、§3-2 の確かめが全部通る
6. docs の更新（§4 の一覧）が終わっている

---

## 段階 0. 下準備（本人 OK の後すぐ）

### 0-1. 未 commit の別作業を commit に分ける【本人 14:0x】

- 連続週数（`Continuity*`・`ContinuityStore`・`StreakWidget`・`StreakViews`・`ContinuityTests`・`continuity-design.md` ほか）と、種目の画像（`Assets.xcassets/Exercises/`・`ExerciseImage*`・`docs/exercise-images*` ほか）の 2 つ
- 見た目の変更（`BodyDiagramView` など 6 ファイル）・`spec.md`・`gymwork-alignment-design.md` は、差分を読んでどちらに属するかを決める。どちらでもないもの（`AGENTS.md` の memory の場所の書き換え）は 3 つ目の commit にする
- 同じファイルに両方が混ざっていたら、差分を分けて `git apply --cached` で載せる（`git add -p` は対話なので使えない）
- 各 commit の前にビルドと単体テストを通す
- 食事・サインインの docs（未追跡）は commit しない（本人 OK まで）

### 0-2. 本人の UID を memory に書く

- MCP の読むだけの SQL で、作成日が 2026-04-14（UTC）のユーザーの id を取る。vault の memory `project_life_tracker_auth_multiuser` に書く。repo・daily には書かない
- テスト用の 2 人目（作成日 2026-04-20 JST・UTC では 04-19。設計の「04-20」と同じユーザー）の id も同じ所に書く
- 置き換えた後の 0014 の SQL は、MCP の呼び出しと本番の `schema_migrations.statements` に残る（repo には残らない）。memory にもそう 1 行書く（P24）

### 0-3. `apply_migration` が 1 つのトランザクションかを確かめる（設計 §6・M10）

- 本人に一言伝えてから、本番に `probe_txn`（`CREATE TABLE public._txn_probe (x int); SELECT 1/0;`）を流す
- `SELECT to_regclass('public._txn_probe')` が NULL なら 1 つのトランザクション。NULL でなければ、すぐ `DROP TABLE public._txn_probe` を流し（残る間は anon に開いた空の表になる・P5）、0014 の本文に `BEGIN;`／`COMMIT;` を書く
- `list_migrations` に失敗した版が残るかも見る。結果は設計 §6 に 1 行書く（0007 の注記の代わり）
- **結果（2026-10-19 18:2x）**【事実】: `22012: division by zero` で失敗、`_txn_probe` は NULL（戻った）、`schema_migrations` は 23 行のまま（失敗した版は残らない）→ 1 つのトランザクション。0014 の a・p（`BEGIN;`／`COMMIT;`）は書かない。設計 §6 に記録

### 0-4. 本人に頼む操作（手順は AI が書く）

手順: `auth-multiuser-user-steps.md`（2026-10-21 下書き。画面の名前は【要確認】が残る）

| # | 操作 | いつまでに | 備考 |
|---|---|---|---|
| U1 | Supabase のプランを確かめる（Free か） | 段階 1 の前 | Free ならバックアップは本人の `pg_dump` だけ。**10-21 本人「U1：Free」** |
| U2 | Google Cloud: プロジェクト・OAuth の同意画面（テスト・本人の Gmail をテストユーザーに）・iOS 用と Web 用のクライアント | 段階 2 の Google の前 | iOS のクライアント ID は本人が `LifeTracker.xcconfig` に入れる（AI が行を用意） |
| U3 | Supabase のダッシュボード: メールの確認 ON・パスワード 12 文字以上で英字と数字・戻り先 `lifetracker://auth-callback`・Google の provider（2 つのクライアント ID）・新規登録 OFF・手動の連携 OFF・匿名 OFF | 段階 2 のサインインの確かめの前 | 「Skip nonce check」は ON にしない（§2-3）。**10-22 変更**: 新規登録は ON にした（本人）。パスワードの長さと文字種は、パスワードを使わなくなったので効かない |
| U4 | 本番のバックアップ（本人のターミナルで `pg_dump`） | 段階 3 の最初 | 手順は §3-1。パスワードは聞かれたときに入れる。`!` は使わない（会話に残るため） |
| U5 | 本番 migration の確認の画面をすぐ承認する | 段階 3 | 0013・0014 とも DROP を含むので 2 回出る。遅れると `cancelled` で何も流れない |
| U6 | 実機に新しいビルドを入れ、サインインの画面まで見る（Xcode・iPhone をつないでおく） | 段階 3 の 0013 の直前（P4） | 入れてから 0014 まではトレーニングタブが使えない |
| U7 | メールのテンプレート 2 つをリンクから 6 桁のコードに替える（10-22 追加） | コードの流れを本物の認証で確かめる前 | 手順は `auth-multiuser-user-steps.md` の U7  **10-22 00:23 本人「U7済み」** |
| U8 | メールを送るための Gmail を新しく作り、Supabase の SMTP の設定に入れる（10-22 追加・誰でも登録できるようにするため） | 1〜3（Gmail・2 段階認証・アプリ パスワード）はいつでも。4（Supabase に入れる）は段階 3 の 0014 の後 | 手順は `auth-multiuser-user-steps.md` の U8。アプリ パスワードは本人がダッシュボードに直接入れる（会話・repo に書かない） |
| U9 | Magic Link のテンプレートを 6 桁のコードに・Email OTP の期限を 600 秒に（10-22 追加・パスワードレスにするため） | パスワードレスのアプリをシミュレータで本物の認証で確かめる前 | 手順は `auth-multiuser-user-steps.md` の U9  **10-22 15:0x 本人「U9済み」**（文言は本人が「有効期限は 10 分です。」に直した） |

---

## 段階 1. DB（docker で確かめる。本番は触れない）

### 1-1. docker の確かめの環境（`supabase/test/`。migration ではない置き場）

- `supabase/test/auth_stub.sql`: 設計 §9 の形（ロール `anon`・`authenticated`・`service_role`、`auth.users (id uuid PRIMARY KEY)`、本番の定義を写した `auth.uid()`（`request.jwt.claim.sub` と `request.jwt.claims` の両方を読む）、`extensions` スキーマ）に、次を足す
  - Supabase の既定の権限の写し（本番の今の姿: 表 `arwdDxtm`・関数 `X`・シーケンス `rwU` を `postgres`・`anon`・`authenticated`・`service_role` に。0014 が外せることを確かめるため）
  - ロール `supabase_admin`・`dashboard_user`（本番の写しに、これらへの既定の権限と GRANT が入りうる。無いと `pg_restore` がエラーを数える・P3）
- `supabase/test/run.sh`: `postgres:17` を起動 → `apt-get install postgresql-17-plpgsql-check` → stub → 0001〜0014 → 確かめの SQL。止まったら非 0 で終わる（`psql -v ON_ERROR_STOP=1`）
  - `plpgsql_check` は入る【事実・レビュー §0-2: 2.10.13】。関数の `SET search_path = ''` を尊重し、解けない表・関数の名前を実行せずに見つける。ただし `SET CONSTRAINTS` の制約名は見ない（P7）ので、その経路は §1-5 の 9 で実際に流して確かめる
- `supabase/test/multiuser_test.sql`（確かめの本体。§1-5）
- 本番の写しでのリハーサル（§3-1）も同じ `run.sh` に「写しから始める」入口を付けて行う
- 終わったら container と network を消す

### 1-2. 0013 `0013_drop_legacy_template.sql`（apply 名 `v2_drop_legacy_template`）

- 先頭に砦を 2 つ（P14）: 世代の無い `task_template` が 1 行でもあれば止める／`pattern_template_membership` の行が `pattern_version_membership` に写っていなければ止める（本番は今どちらも 0 件【事実・レビュー §0-1】）
- `DROP TABLE pattern_template_membership`（本番 1 行。読む所は無い【事実】: Swift の `PatternTemplateMembership` は世代から組み立てる型で、表は読んでいない）
- `task_template` の中身の列 5 つ（`name`・`category_id`・`start_minutes_from_midnight`・`duration_minutes`・`rrule`）を消す【AI 既定・レビューで妥当】。0006 の注記「`task_template` は系列の id を保つためだけの表になる」に合わせる。これで `task_template → category` の外部キーも無くなり、0014 で組にする外部キーは 18 本になる（設計 §1 の 19 本から 1 本減る）
- `schedule_template_create` を作り直す（旧列への写しをやめ、`INSERT INTO task_template DEFAULT VALUES RETURNING id`。引数は変えないので、0013 と 0014 の間も今のビルドは動く）。旧列を参照する関数がほかに無いことを、docker の `plpgsql_check` と grep で確かめる
- 前提「新しいビルドで読み書きを確かめてから」【AI 既定・本人に一言】: 満たしている見込み。0006 以降のビルドを 9-30 から使っている。旧列は Swift のどこからも読まれていない（grep 0 件）。Personal Team のビルドは 7 日で切れるので、0006 より前のビルドはもう端末に無い見込み【推測・無料の署名の仕様として知られている】
- 戻せない（列と 1 行を消す）。消す中身は世代と `pattern_version_membership` から導けるので、戻す必要が出る見込みは無い。戻すのはバックアップからだけ

### 1-3. 0014 `0014_multiuser_rls.sql`（apply 名 `v2_multiuser_rls`）

設計 §6 の順を基に、既定の権限を前に出した（P6）。本人の UID は印 `'__OWNER_UID__'`（設計 §6・M11。置き換え忘れは `::uuid` の時点で 22P02 になり、`DO` の確かめと二重に止まる）。

| 順 | 中身 | 設計・レビュー |
|---|---|---|
| a | （書かない。0-3 で 1 つのトランザクションと確かめた） | §6・M10 |
| b | `CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions` | §2 D6 |
| b2 | 既定の権限（下の「権限」の 1）。この後に作る物（i の表と view、l の関数）が最初から閉じた形で作られるように | P1・P6 |
| c | UID の確かめの `DO` ブロック | §6 |
| d | 20 表（21 − 0013 で消す 1）に `user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE` を NULL 可で足す | §1・M6 |
| e | `exercise` を除く 19 表を `UPDATE ... SET user_id = '__OWNER_UID__' WHERE user_id IS NULL` | §6・M4 |
| f | 19 表を NOT NULL、20 表に既定値 `auth.uid()` | §1 |
| g | 親 8 表に `UNIQUE (id, user_id)`、子の外部キー 18 本を組に作り直す（削除のときの動きは今と同じ。SET NULL は列を指定する形） | §1・M30 |
| h | D1〜D8 と `category (user_id, sub_input_kind)` の一意（`day_meta → pattern` も組にする）。消し方は下の「消すものの種類」 | §2・§3・M9・P13 |
| i | 種目: 名前の一意を 2 つの部分 UNIQUE に、`exercise_preference` を作る、`exercise` から `is_archived`・`note` を消す、view `exercise_for_user`、`exercise_muscle_group_idx` を条件なしで作り直す | §3・M16 |
| j | 索引: 全表に、`user_id` が先頭の**部分でない**索引（主キー・一意・作り直した索引のどれか）を 1 つ以上置く。範囲で読む表（`actual_task`・`scheduled_task`・`sleep_record`・`workout_session`・`workout_set` の `completed_at`）は `(user_id, 今の列)` に作り直す。`category`・`pattern` は一意が部分索引だけなので素の `(user_id)` を足す | §1・P15 |
| k | `workout_training_day` を `security_invoker = true` に | §2 D9 |
| l | 関数 28 個を `SET search_path = ''` と `public.`／`private.` 付きで作り直す。`SET CONSTRAINTS` の名前にもスキーマを付ける。`ensure_user_defaults()` を足す | §4・M3 |
| m | 権限（下の「権限」の 2・3） | §5・M1・P6・P12 |
| n | RLS を有効にし、policy を作る（21 表。`exercise` は 4 つ、ほかは 1 つ。計 24。どれも `TO authenticated`） | §5・M4 |
| o | v1 の残りの関数 6 つを `DROP FUNCTION IF EXISTS`（本番で確かめたシグネチャ: `fn_resolve_month_patterns(integer,integer)`・`sync_did_gym_on_insert()`・`sync_did_gym_on_delete()`・`sync_did_study_on_insert()`・`sync_did_study_on_delete()`・`update_updated_at()`） | §4 |
| p | （書かない。a と同じ） | |

**権限**（P1・P6・P12。設計 §5 を具体にし、一部を直した）

1. 既定の権限（b2）
   - `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;`（`IN SCHEMA` を付けない。public にも private にも効く）【事実・レビューで実測】スキーマ単位の既定の権限は、作るときに組み込みの既定（関数は PUBLIC に EXECUTE）に足し算で重なる。だから `IN SCHEMA public ... FROM PUBLIC` は何も消さず、これから作る関数が PUBLIC 経由で anon から呼べたままになる。本番の `pg_default_acl` に PUBLIC の行が無いのに、今の関数に PUBLIC の EXECUTE が付いているのはこのため
   - `FOR ROLE postgres IN SCHEMA public` で: 表とシーケンスは anon から全部外す。authenticated から `TRUNCATE`・`REFERENCES`・`TRIGGER`・`MAINTAIN`（PG17 の新しい権限。既定の ACL の `m`）を外す。関数は anon から `EXECUTE` を外す
   - これからの表は自動で「authenticated に読み書きだけ」、関数は「authenticated・service_role だけ」になる。それでも新しい migration には GRANT と REVOKE を書く（設計 §5 の決まり）。RLS の付け忘れは §1-5 の 10 で止める
2. 今ある物（m）: `REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon`（view を含む）・`REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon`・`REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon`・`REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM authenticated`・2 つの view から authenticated の `INSERT`・`UPDATE`・`DELETE` を外す。一つずつ並べず `ALL ... IN SCHEMA` の形にする（漏れを防ぐ）。`CREATE OR REPLACE` は今の権限を保つので、b2 を前に出しても m は要る（P23）
3. private: `REVOKE USAGE ON SCHEMA private FROM anon`・`REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon`。authenticated の USAGE と EXECUTE は残す（0012 の注記どおり、中から呼ばれる関数にも要る）
4. `service_role` の権限は触らない（§1-5 の 10 で残っていることを見る）
- 本番の public に拡張の関数とシーケンスは 0【事実・14:5x とレビュー】。`ALL ... IN SCHEMA public` の REVOKE が拡張を壊すことは無い

**消すものの種類**（P13。間違えると migration が止まる）【事実・本番のカタログ】

- 索引なので `DROP INDEX`: `exercise_name_unique`・`pattern_apply_day_unique`・`workout_session_single_in_progress`
- 制約: `training_goal_effective_from_key`（作り直す）・`workout_session_actual_task_id_key`（残す）
- EXCLUDE 制約: `ALTER TABLE sleep_record DROP CONSTRAINT sleep_record_no_overlap` → `ADD CONSTRAINT ... EXCLUDE USING gist (user_id WITH =, tstzrange(start_at, end_at) WITH &&)`
- `user_profile`: `DROP COLUMN id` で主キーと `user_profile_single_chk` も落ちるので、`ADD PRIMARY KEY (user_id)` だけ
- `body_weight_record`・`day_meta`: `DROP CONSTRAINT <表>_pkey` → `ADD PRIMARY KEY (user_id, ...)`

**関数の書き直し（l）**

- 元: docker で 0001〜0013 を流した後の `pg_get_functiondef`（migration の最新の定義と同じ物）
- 規則: 表・関数・型は `public.`／`private.` を付ける。明示のキャストも `::public.apply_day_enum` の形（`'Holiday'` のような文字だけなら要らない・P16）。`gen_random_uuid()`・`now()`・`tstzrange` など組み込みの物は付けない。SQL 関数は修飾が漏れると CREATE で止まり、plpgsql は実行時まで止まらない（だから `plpgsql_check`）【事実・レビュー】
- 担当: opus のサブエージェント。`plpgsql_check` が 0 件になるまで直させる。0014 の表と制約（順 4）を書くサブエージェントは、l の場所に `-- l: 関数（順 5）` の印だけを置き、順 5 がそこに入れる（P23）

**そのほかの細部**

- **`ensure_user_defaults()`**【AI 既定】: `RETURNS void`・SECURITY INVOKER・`search_path = ''`。先頭で `auth.uid()` が NULL なら例外。休日パターン（名前「休日」・`apply_day = 'Holiday'`）、種類「ジム」（`gym`）と「睡眠」（`sleep`）を、`ON CONFLICT (user_id, ...) WHERE ... IS NOT NULL DO NOTHING` で作る（部分 UNIQUE に合う形・同時に呼ばれても 1 件【事実・レビューで実測】）。名前は本番の今の行と同じ【事実・14:5x】
- **`exercise_for_user` の結合の条件**【AI 既定・レビューで妥当】: `LEFT JOIN public.exercise_preference p ON p.exercise_id = e.id AND p.user_id = (select auth.uid())`。RLS を越える MCP（postgres）で view を読んだときに、人の数だけ種目の行が増えるのを防ぐ。`security_invoker = true` は外さない（外すと他人の自作の種目が見える）
- **大きさ**: 0014 は 70KB 前後の見込み【推測】（0012 の 43.5KB は通った）。通らなければダッシュボードの SQL エディタで 1 回で流す（`AGENTS.md` の代わりの手段。1 回の問い合わせなので 1 つのトランザクションは保てる）。分けて流さない（途中で止まったときに全部戻らなくなる）（P17）

### 1-4. 戻しの SQL `supabase/rollback/0014_down.sql`（設計 §6・M15）

- 先頭に書くこと: 「本人 1 人しかデータが無いうちだけ安全」／戻しても `supabase_migrations.schema_migrations` に 0014 の記録は残り、`list_migrations` では適用済みに見える（P5）／v1 の残りの関数 6 つは戻さない（使っていない）
- 逆の順: RLS と policy を消す → 権限を Supabase の既定に戻す（`ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC` を含む・P1）→ 関数を 0013 の後の定義に戻す（本文ごと。`RESET search_path` だけでは本文の `public.` が残り、形が戻らない）→ `ensure_user_defaults` を消す → 種目を元の形に（`is_archived`・`note` を戻し、`exercise_preference` の値を書き戻してから消す）→ 制約・索引を元に → `user_id` を消す → `btree_gist` は残す（害が無い）
- 途中までしか流れていない状態からも通るように書く（`IF EXISTS`・`to_regclass` の確かめ。0-3 で 1 つのトランザクションでないと分かったときの備え・P5）→ 0-3 で 1 つのトランザクションと分かった（10-19 18:2x）。`IF EXISTS` の書き方は安いので残すが、「途中で止めた状態」からの確かめはしない
- 確かめ: docker で「0013 まで」→ `pg_dump --schema-only` → 0014 → 戻し → `pg_dump --schema-only` → 差分が 0（「0014 を途中で止めた状態」からの確かめは 0-3 の結果で不要に）

### 1-5. 確かめの SQL（`multiuser_test.sql`。docker で毎回全部流す）

2 人（A・B）を `auth.users` に入れ、`SET ROLE authenticated` と `request.jwt.claims` で人を切り替える（設計 §9）。

1. **人の分離**: A で全表に 1 行ずつ書く（19 の RPC を全部 1 回ずつ呼ぶ。`todo_fetch` も）。B から全表・2 つの view が 0 行。B の更新・削除が 0 行
2. **anon**: `SET ROLE anon` で全表・view の SELECT と全 RPC が 42501
3. **既定値**: A の書き込みの `user_id` が全部 A（アプリと同じく `user_id` を送らない書き方で）。postgres で `user_id` を書かずに `INSERT INTO public.category (name) VALUES ('x')` → 23502（MCP の入れ忘れを NOT NULL が止める・P18）
4. **一意が人ごと**: A と B が同じ日の体重・day_meta・週の目標・休日パターン・ジムの種類を持てる。A の中では今までどおりぶつかる（23505）。A と B の睡眠が同じ時間帯で両方入る。A の中では重なりで 23P01。A と B が同時に進行中のセッションを持てる
5. **持ち主の食い違い**: postgres で、B の `user_id` で A の親を指す子の行を入れると外部キーで失敗する（18 本すべて）
6. **upsert**: アプリと同じ形（`user_id` を送らず `ON CONFLICT (user_id)`／`(user_id, recorded_on)`／`(user_id, effective_from)`）で、2 回目が更新になる（PostgREST でも通ることはレビューで実測済み）
7. **種目**: A・B とも共有の 159 件が見える。A の `exercise_preference` のアーカイブが B の view に効かない。A の自作の種目が A の view に出て B には出ない（P18）。authenticated から共有の行を INSERT・UPDATE・DELETE できない
8. **`ensure_user_defaults()`**: 新しい人 C で 1 回目に 3 行、2 回目で増えない。本人（付け替え済み）では増えない。C を `auth.users` から消すと C の行が全表で 0（P18）
9. **`SET CONSTRAINTS` の経路**（`plpgsql_check` では見つからない・P7）: セットの削除・並べ替え・✓ の取り消しが `search_path = ''` で通る
10. **機械の確かめ**（本番でも流す。本番版は `plpgsql_check` の代わりに 11 の md5）:
    - RLS の付け忘れ 2 つが 0 行。`pg_policies` が 24 で、`roles` が `{authenticated}` だけ（P18）
    - `has_table_privilege`: anon は全表・view で全部 false。authenticated は SELECT／INSERT／UPDATE／DELETE が true、TRUNCATE／REFERENCES／TRIGGER／MAINTAIN が false（P12）。view は SELECT だけ true。service_role の権限が残っている（P18）
    - `has_function_privilege`: anon は全関数で false（PUBLIC 経由も含めて判定される）
    - 既定の権限: `pg_default_acl` を `defaclnamespace IN (0, 'public'::regnamespace)` で読み、postgres のグローバルの関数の行（`{postgres=X/postgres}`）があり、public の行に anon が無い。さらに捨ての関数を 1 つ作り、PUBLIC の EXECUTE が付いていない・anon の `has_function_privilege` が false を見て、消す（P1）
    - `proconfig` が全部 `search_path=`。`plpgsql_check` が 0 件（docker だけ）
    - 全表に `user_id` が先頭の部分でない索引がある（`pg_index.indpred IS NULL`・P15）
    - `user_id IS NULL` が `exercise` の共有の行だけ
11. **関数が docker と同じか**（P7）: `SELECT md5(string_agg(pg_get_functiondef(p.oid), E'\n' ORDER BY p.oid::regprocedure::text)) FROM pg_proc p WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)` を、リハーサルの DB と本番で比べる。同じなら、docker の `plpgsql_check` の結果が本番にも当てはまる

### 1-6. SQL のレビュー

0013・0014・戻しの SQL・確かめの SQL がそろったら、deep-task（fable / max）でレビューする。本番に流す、戻しにくい変更のため。指摘を直してから段階 2 に進む。アプリの認証の層（§2-1〜2-4）も、段階 2 の後に同じくレビューする（本番に効く守りのため・P22）。

---

## 段階 2. アプリ

### 2-1. 認証の層（新しいファイル。`Sources/Auth/`）

【10-22 15:3x 変更・本人の決定】サインインはパスワードレス（メールの 6 桁のコード＋Google）に作り替えた。この節のパスワード・新規登録・確認・再設定・新しいパスワード・`AuthFeatures` の記述は古い（段階 4 で書き直す）。今の形は作業時間の 10-22 15:3x の行

- `AuthService`（protocol）: サインイン・新規登録・確認メールの再送・再設定のメール・新しいパスワード・Google の ID トークンでのサインイン・サインアウト・URL からのセッション・状態の流れ（`AsyncStream`）
  - `SupabaseAuthService`: 今の共有の `SupabaseClient` の `auth` を包む
  - `MockAuthService`（DEBUG とテスト）: メモリ上。決まったメールアドレスとパスワードで通る
- `AuthStore`（`@MainActor`・`ObservableObject`）: 状態は「起動中」「未サインイン」「確認待ち（メールアドレス）」「新しいパスワードの入力」「サインイン済み（UID）」
  - `authStateChanges` を 1 本だけ購読する。`.initialSession` を受けるまでは「起動中」（設計 §7・M20）
  - クライアントの設定に `emitLocalSessionAsInitialSession: true` を付ける【AI 既定・レビューで妥当】。supabase-swift 2.44 の既定は `false` で、そのままだと端末のセッションを更新してから初期セッションを流し（オフラインの起動で待たされる）、実行のたびに警告も出す【事実】。`true` では期限切れのセッションもそのまま流れ、裏で更新される。更新がネットワークで失敗してもサインアウトにはならず、`.signedOut` が来るのはサインアウトと、サーバーが「セッションが無い・期限切れ・更新のトークンが無効」と返したときだけ【事実・レビュー §0-3】。だから期限切れでも「サインイン済み」として画面を出し、`.signedOut` が来たときだけサインインの画面に戻る
  - サインイン済みになったら `ensure_user_defaults()` を呼ぶ。失敗しても画面は出し、次の起動でまた呼ぶ【AI 既定】（本人の行はもうあるので、本人では何も起きない）
- **パスワードの再設定**（P2。設計 §7・M23 を直す）【事実】PKCE では、再設定のリンクを踏んでも supabase-swift は `.passwordRecovery` を出さず `.signedIn` だけを出す（GoTrue の転送先にも種類が付かない）。そこで:
  - 【10-22 変更・本人の決定】再設定はリンクをやめて 6 桁のコードにした（`verifyOTP(email:token:type: .recovery)`）。下の「再設定を頼んだ」印は消した（コードの画面で再設定の流れの中にいると分かるため）。メールのテンプレートは本人が U7 でコードにした。古いリンクが届いたときは `handle(url:)` がサインイン済みにするだけ（新しいパスワードの画面は出さない）
  - `resetPasswordForEmail` が成功したら「再設定を頼んだ」印（時刻つき）を UserDefaults に置く（アプリが落ちた後にリンクを踏んでも効くように）
  - URL からのセッション（`session(from:)`）で `.signedIn` になったとき、印が 1 時間以内なら「新しいパスワード」の画面 → `auth.update(user: UserAttributes(password:))` → 印を消す
  - メールとパスワードの通常のサインインでも印を消す
  - 本人の言葉は「リンク」なので、リンクのまま印で出し分ける。代案は再設定だけ 6 桁のコード（`verifyOTP(email:token:type: .recovery)`）
- **URL の受け取り**（P19）: `lifetracker://` の URL は `try await supabase.auth.session(from: url)` で受け、失敗を画面に出す（`handle(_:)` は失敗をログに流すだけで、画面に何も出ないため【事実】）。文言: verifier が無い（別の端末で踏んだ）→「このメールは、登録したこの iPhone で開いてください」／使い切り・無効 →「リンクが無効です。もう一度送ってください」
  - 【10-22 変更】確認も再設定もコードになったので、`lifetracker://auth-callback` に戻るリンクは、新しいメールでは届かない。受け取りの処理は古いリンクのために残す
- クライアントの設定: `redirectToURL: lifetracker://auth-callback`・`flowType: .pkce`（2.44 の既定も PKCE【事実】だが明示する。設計 §7）

### 2-2. 画面（新しいファイル。`Views/Auth/`）

【10-22 15:3x 変更・本人の決定】サインインはパスワードレス（メールの 6 桁のコード＋Google）に作り替えた。この節のパスワード・新規登録・確認・再設定・新しいパスワード・`AuthFeatures` の記述は古い（段階 4 で書き直す）。今の形は作業時間の 10-22 15:3x の行

- 起動中（今の起動画面と同じ見た目）・サインイン（メールとパスワード／新規登録へ／パスワードを忘れた／Google で続ける）・新規登録・確認待ち（「このメールをこの iPhone で開いてください」・60 秒待ちの再送）・再設定のメールを送る・新しいパスワード
- 【10-22 変更・本人の決定】画面は本人の参考（Slack・Amazon・Google のスクショ）の Slack 型に作り直した: 2 段（メール →「次へ」→ パスワード）・上に「LifeTracker」の文字・中央の見出し（説明文なし）・枠線の欄・青で塗った全幅の主のボタン・「または」の線・ほかのボタンと揃えた Google のボタン・補助は文字のリンク。閉じている間は新規登録の入口を出さない（`AuthFeatures.isSignUpOpen`）。確認・再設定はコードの画面（6 つの枠・送り直しの 60 秒）。経緯は作業時間の 10-22 の行と設計 §7
- 文言はすべて日本語。存在を隠す応答なので、新規登録と再設定は常に「メールを送りました」と出す（設計 §7・M23）
- 新規登録を閉じている間は、サーバーの「新規登録は受け付けていない」のエラーを「今は新規登録を受け付けていません」と出す【AI 既定】（新規登録の画面は残す。開くのはダッシュボードのトグル 1 つ）
- パスワードの最低の長さ（12 文字・英字と数字）は画面でも先に検査する（サーバーの設定 U3 と同じ値）

### 2-3. Google（GoogleSignIn-iOS）

- パッケージ: GoogleSignIn-iOS の 9.0.0 以上（実装のときの最新の安定版。リリースノートの最新は 10.0.0 で iOS 15 以上。このアプリの最低の版で使える【事実】）。`project.pbxproj` に足し、`xcodebuild -resolvePackageDependencies` で取る
- **nonce を渡す**【AI 既定・設計 §7・M19 から変える・レビューで成立を確認】: 設計は「GoogleSignIn-iOS には nonce を渡す口が無い」ので Supabase の「Skip nonce check」を ON にする形だった。9.0.0 で `signIn(withPresenting:hint:additionalScopes:nonce:)` が足され、渡した値をそのまま Google に送る【事実】。Supabase は、渡された値の SHA-256 の 16 進（小文字）とトークンの `nonce` を比べる【事実・GoTrue のソース】。そこで:
  - 32 バイト程度の乱数を作る（`SecRandomCopyBytes`）
  - その SHA-256 の小文字の 16 進を Google の `nonce:` に、元の値を `OpenIDConnectCredentials(nonce:)` に渡す。`accessToken` も今の手順どおり渡す
  - 「Skip nonce check」は OFF のまま（ID トークンの使い回しを防ぐ検査を残す）
  - 実機で通らなければ本人に聞く（「Skip nonce check」を ON にする／Google をブラウザの画面で入る形 `signInWithOAuth` にする）
- `Info.plist`: `GIDClientID` と、逆順のクライアント ID の URL スキームを `$(GOOGLE_IOS_CLIENT_ID)`・`$(GOOGLE_REVERSED_CLIENT_ID)` で受ける（値は xcconfig。`.example` には印だけ）。`CFBundleURLTypes` は `lifetracker` と合わせて 2 つ
- `onOpenURL` で、Google の URL は `GIDSignIn.sharedInstance.handle(url)`、`lifetracker://` は §2-1 の `session(from:)` に渡す

### 2-4. 起動の組み立て（`LifeTrackerApp.swift`）

- `initResult` に `AuthStore` を足す。画面の出し分け: 起動中 → 起動画面／未サインイン・確認待ち・新しいパスワード → 認証の画面／サインイン済み → 今の `TabView`（`.id(uid)` を付け、人が変わったら store を作り直させる。設計 §7・M21。作り直しを免れる共有の持ち物は無い【事実・レビュー】）
- テストの切り替え（設計 §9・M22）: `XCTestConfigurationFilePath` があれば、DEBUG ではメモリ上の data source と `MockAuthService`（サインイン済み）にし、`SupabaseClient` を作らない
- 起動引数（DEBUG だけ）: `-mock-auth`（`MockAuthService` でサインイン済み）、`-mock-auth-signed-out`（同じく未サインインから）。`-mock-day`・`-mock-workout` を付けて `-mock-auth` を付けなければ、本物の認証＋メモリ上のデータになる（0014 の前に、本番の認証だけを使ってサインインの流れを確かめるため。データは本番に触れない）
- `ensure_user_defaults()` は data source を通して呼ぶ（`DayDataSource` か `ScheduleDataSource` に 1 つ足す。メモリ上の実装は何もしない）

### 2-5. data source の変更

| 場所 | 変更 | 設計 |
|---|---|---|
| `SupabaseWorkoutDataSource` の種目 | `from("exercise")` → `from("exercise_for_user")` | §3・M16 |
| 同 プロフィール | `ProfileRow` から `id` を消し、`onConflict: "user_id"` | §2 D1・A2 |
| 同 週の目標 | `onConflict: "user_id,effective_from"`（`training_goal` の `id` 列は残す） | §2 D4 |
| 同 体重 | `onConflict: "user_id,recorded_on"` | §2 D2 |
| `WorkoutDataSource` の注記 | 「1 行・id = 1」を「人ごとに 1 行」に | §2 D1 |
| `SupabaseDayDataSource.fetchTaps` | 42501 と PGRST3xx（JWT 系）は空にせず上に投げる | §7・M8 |
| エラーの文言（`SleepRules` の変換・`RuleErrorMapping`） | 42501 は、端末にセッションがあれば「確認できませんでした。もう一度お試しください」とし、`refreshSession()` を 1 回試す。セッションが無いときだけ「サインインし直してください」（P9） | §7・A5・A6 |

- P9 の理由【事実・レビュー §0-3】: 期限切れのセッションの更新がネットワークで落ちた直後は、クライアントが anon キーで送るので 42501 になる。このときセッションは端末に残り、`.signedOut` も来ない。サインインの画面に戻すのは `.signedOut` のときだけにする
- 書き込みで送る中身に `user_id` は足さない（既定値の `auth.uid()` で入る。設計 §1）

### 2-6. サインアウトとウィジェット

- サインアウトの置き場: トレーニングの分析画面のプロフィール（設定画面は食事で作るので、それまで）（設計 §7・M21）
  - 【10-22 変更・本人の決定】下のタブの最後の「プロフィール」タブの節「アカウント」（サインイン中のメールアドレスの下）に移した。分析から開く `ProfileSheet` からは外した（本人の決定 14:3x）
- `signOut()` が失敗しても、端末側はサインアウト済みとして扱い、結果に依らずサインインの画面へ
- サインアウトで: App Group の `continuity.v1` を消す → 別のキー（例 `auth.signedIn.v1` の Bool）を false にする → `WidgetCenter.shared.reloadAllTimelines()` → 休憩の Live Activity を終える。サインインで Bool を true にする
- ウィジェット（P8。設計 §2 A3 の「`Snapshot` に `isSignedIn`」を別のキーに変える）: Bool が false なら「アプリでサインインしてください」、true でスナップショットが無ければ今の文言。`Snapshot` の形は変えない（変えると今の保存が読めなくなり、「目標を設定」の表示になる）
  - キーが無い（今のビルドからの移り）ときは「サインイン済み」とみなす【AI 既定】。新しいビルドを入れた直後に、本人のウィジェットが「サインインしてください」に変わらないように
    - 【アプリのレビュー A11・10-21】10-21 22:4x の決定（起動して端末にセッションが無いときも片付ける）で、効くのは「入れてからアプリを起動するまでの短い間」だけになった。新しいビルドの最初の起動は端末にセッションが無い（今のビルドには認証が無い）ので、サインインの画面が出た時点でウィジェットは「アプリでサインインしてください」になり、連続週数のスナップショットも消える。サインインすれば書き直される。正常な動き（U6 の手順に書いた）

### 2-7. テスト

【10-22 15:3x 変更・本人の決定】サインインはパスワードレス（メールの 6 桁のコード＋Google）に作り替えた。この節のパスワード・新規登録・確認・再設定・新しいパスワード・`AuthFeatures` の記述は古い（段階 4 で書き直す）。今の形は作業時間の 10-22 15:3x の行

- 単体テスト（Swift Testing）:
  - `AuthStore` の状態の移り変わり（初期セッションあり／なし／期限切れ・`.signedOut`・確認待ち）
  - 再設定: 印があるときの `session(from:)` → 新しいパスワードの画面／印が 1 時間を過ぎている・無いとき → サインイン済み／通常のサインインで印が消える（P2）
    - 【10-22 変更】印を消したので、このテストも消した。代わりに、コードの流れ（送る → コード → 新しいパスワード → サインイン済み／誤り／送り直し）と、確かめている間の `.signedIn` を無視する守りのテスト
  - URL の失敗が画面の文言になる（P19）
  - サインアウトでウィジェットのキーが消え、Bool が false になる（UserDefaults を差し込む）
  - 42501 の 2 つの文言（P9）、`fetchTaps` の投げ分け、upsert の衝突先の文字列、テストの環境で `SupabaseClient` を作らないこと
  - nonce: 渡す値が乱数の SHA-256 の小文字の 16 進になっている
- 既存の `SleepRulesTests` の 42501（今は「そのままの文言」を期待）は新しい文言に直す
- UI テスト（P10）: 起動する 3 か所すべてに `["-mock-day", "-mock-workout", "-mock-auth"]` を渡す（`LifeTrackerUITests.swift:29` の `testExample`、`:38` の `measure` の中の `XCUIApplication()`、`LifeTrackerUITestsLaunchTests.swift:22`）。新しく 1 つ: `-mock-auth-signed-out` で起動 → サインインの画面 → 決まったメールとパスワード → タブが出る → サインアウト → サインインの画面

### 2-8. シミュレータでの確かめ（AI。idb の `screen`・`describe`・`tap`）

1. `-mock-day -mock-workout -mock-auth`: 全タブが今と同じ（スクリーンショットを今のビルドと見比べる）
2. `-mock-auth-signed-out`: サインインの画面・新規登録・再設定の画面の文言と並び
3. 本物の認証＋メモリ上のデータ（0014 の前・U3 の後）:
   - 本人のアカウントでメール＋パスワード（パスワードは本人がシミュレータに入れる。会話に残さない）
   - 再設定: アプリで再設定のメールを頼む → 届いたリンクの転送先を `curl -I` で取り、`xcrun simctl openurl booted` で開く → 新しいパスワードの画面（P2 の印で出る）→ 新しいパスワードで入り直せる
   - Google（本人の Gmail）→ 同じ UID になる（同じ確認済みのアドレスなので 1 人にまとまる。新規登録を閉じていても通る【事実・レビュー】）
   - 機内モードで起動しても、サインインの画面に戻らない
4. 【アプリのレビュー A1・10-21・事実】再送した確認メールのリンクは implicit 形式で戻り、fragment に本人の有効なセッションが入る（GoTrue は token の接頭辞で戻りの形を決め、supabase-swift の `resend` は `code_challenge` を送らない）。アプリはセッションを作らないが、カスタムスキームは横取りされうる。**配る準備のとき（新規登録を開く前）に、確認メールを 6 桁のコード（`verifyOTP(email:token:type: .signup)`・設計 §7 の代案）に替える。それまで新規登録は閉じたまま**
5. 新規登録の確認メール【AI 既定・本人に一言】: 標準のメール送信はチームのメンバーのアドレスにしか届かず、本人のアドレスは登録済み。さらに新規登録は閉じる。だから新規登録の確認メールを端から端まで確かめるのは、外部の SMTP を入れて新規登録を開くとき（配る準備のとき）にする。同じ「リンク → アプリ → セッション」の戻り方は、3 の再設定で確かめる
6. 実機でのリンクの戻り方（メールのアプリ → Safari → 「LifeTracker で開く」）は、段階 3 の後に本人の iPhone で 1 回確かめる（シミュレータでは確かめられない【事実・レビュー §6】）

---

## 段階 3. 本番（本人 OK・commit の後）

### 3-1. バックアップとリハーサル（U4）

- 本人のターミナルで（AI がコマンドを書く。接続文字列はダッシュボードの「Session pooler」）:
  `pg_dump "<接続文字列>" --schema=public --schema=private -Fc -f ~/Backups/life-tracker/2026-10-XX-before-0013.dump`
  - `private` も取る（P3）。`private` の無い写しでは、0014 の `todo_fetch`（SQL 関数で `private` を参照）が CREATE で止まり、リハーサルにならない
  - 手元の `pg_dump` 18.0 の写しは、docker の `pg_restore` 17 で読める【事実・レビューで実測】
  - `auth` は 0013・0014 で変えないので取らない（ユーザーのパスワードのハッシュなどを手元に置かない）
  - 置き場は repo の外（`~/Backups/life-tracker/`）
- AI: 写しを docker に戻す（stub の上に `pg_restore --no-owner`、`auth.users` には UID 2 件を入れる）
  1. 各表の `count(*)` を取る（P11。数はその時点の値で、決め打ちしない）
  2. 0013 → 0014（UID を置き換えて）→ §1-5 の 10 と 11
  3. 0014 の後に、本人の `user_id` の行数が、1 の数（`exercise` と、0013 で消えた表を除く）と一致する
  4. 戻しの SQL → 差分 0
- 写しが戻せることも、これで同時に確かめる（設計 §6・M13）

### 3-2. 流す

1. 本人に新しいビルドを実機に入れてもらい、サインインの画面まで見る（U6・P4）
2. 本人に「今から流します。確認の画面はすぐ承認してください」と伝える（U5）
3. 0013 → 読むだけの SQL で、`pattern_template_membership` が無い・`task_template` の列が `id` だけ
4. 0014 の直前にもう一度、各表の `count(*)` を取る
5. 0014（`'__OWNER_UID__'` を本人の UID に置き換えた SQL を渡す）→ 本番で §1-5 の 10（`plpgsql_check` を除く）と 11（md5 がリハーサルと同じ）→ 本人の `user_id` の行数が 4 の数と一致する
6. 2 人目: MCP で `SET LOCAL ROLE authenticated` と 2 人目の `request.jwt.claims` を置いて、全表が 0 行（MCP で使えることはレビューで確かめた【事実】）。**2 人目でアプリに入る前に見る**（入ると `ensure_user_defaults` が 3 行作る。設計 §9 の「全タブが空」は、記録が無いという意味）（P18）
7. 本人がアプリを起動し直してサインイン → 全タブ・ウィジェット
8. anon: `LifeTracker.xcconfig` の URL とキーを読むスクリプトで `curl`（キーは表示しない）→ 表・RPC が 401（anon キーだけなら 401。RLS の書き込みの違反なら 403）
9. advisor（security）: RLS の ERROR 0・view の ERROR 0・search_path の WARN 0・SECURITY DEFINER の WARN 0。残るのは漏えいしたパスワードの検査の WARN（Pro 以上の機能）だけ

### 3-3. 失敗したとき

- 0014 の途中の失敗: 1 つのトランザクションなら全部戻る（0-3 で確かめる）。読むだけの SQL で「何も変わっていない」を確かめ、直して流し直す。1 つのトランザクションでなかったら、戻しの SQL（途中の状態からも通る形・§1-4）で戻してから流し直す
- `cancelled`: 何も流れていない。読むだけの SQL で確かめてから流し直す
- 流れた後にアプリが動かない: まずアプリを直す。直せなければ、戻しの SQL ＋今のビルドの再インストール。最後の手段がバックアップからの戻し（リハーサルで通った手順）

---

## 段階 4. docs と記録

- 設計 §9 の末尾の一覧（「RLS 無効」の記述・INV-2・`spec.md` の「個人ツール」・本番適用の手順の期待値・`gymwork-alignment-design.md` の R-3・`apply_migration` の確かめの結果・`meal-weight-design.md` §2 の user_id）
- 設計そのものの直し（このレビューで分かったもの。10-19 15:4x に設計の各節へ注記を入れ、本文は段階 4 で書き直す）: §1 の外部キー 19 本 → 18 本（0013）／§5・§9 の既定の権限（グローバルの行・MAINTAIN・確かめの照会。P1・P12）／§7 の再設定（印で出し分ける。P2）と Google の nonce（M19 を変える）と 42501 の文言（P9）／§2 A3 のウィジェット（別のキー。P8）
- `domain-model.md` に 0013・0014 の形（`task_template` は id と `user_id` だけ・`exercise_preference`・RLS）
- `day-cycle-walkthrough.md`:196 の 0013 のチェックを済みに
- SQL レビュー（`auth-multiuser-sql-review-2026-10-19.md`）の docs の分: S6（`service_role` は `private` の関数を呼べない・`auth.uid()` も NULL。Edge Function などで service キーから RPC を呼ぶ日は、`private` の EXECUTE と user_id の明示が要る）・S10（MCP で `exercise` に user_id を書かないと共有の種目になる。自作は user_id を明示）を `gymwork-alignment-design.md` R-3 の周りか設計 §9 に
- アプリのレビュー（`auth-multiuser-app-review-2026-10-21.md`）の docs の分: A13（「新しいパスワード」の途中で落とすとサインイン済みになる。設定画面ができたら「パスワードを変える」を置く）・A15（Keychain のセッションはアプリを削除しても残る見込み。端末を人に渡すときはサインアウト）を設計 §7 に。A6 は下の作業時間（10-21 23:08）
- memory・daily の索引・作業時間

## 作業の順と分担（すべて直列・P21）

| 順 | 作業 | 担当 |
|---|---|---|
| 1 | 段階 0（commit・UID・probe） | 親 |
| 2 | 1-1 docker の環境 | opus |
| 3 | 1-2 0013 | 親 |
| 4 | 1-3 0014 の表・制約・権限・RLS（l 以外。l の場所に印） | opus（親が設計を確定してから渡す） |
| 5 | 1-3 0014 の関数（l） | opus（`plpgsql_check` が 0 になるまで） |
| 6 | 1-4 戻し・1-5 確かめ | opus |
| 7 | 1-6 SQL のレビュー → 直す | deep-task → 親 |
| 8 | 2-1〜2-4 認証の層・画面・起動 | opus |
| 9 | 2-5〜2-7 data source・サインアウト・テスト | opus |
| 10 | 認証の層のレビュー → 直す（P22） | deep-task → 親 |
| 11 | 2-8 シミュレータ | 親 |
| 12 | 本人確認 → commit・push（本人の依頼） | 親 |
| 13 | 段階 3 | 親＋本人 |
| 14 | 段階 4 | 親 |

順 4 からも `run.sh` を流し、途中まで通ることを見る（P23）。

## 本人の決定

- 2026-10-19 15:4x に聞いた「この計画で実装に入ってよいですか？」（選択肢: この計画で実装に入る（推奨）／確かめの migration を省いて入る／先に計画を読む）→ 17:0x 本人（原文）「1だが、まだ待って。」→ この計画（確かめの migration `probe_txn` を含む）で進める。ただし着手は本人の合図を待つ。段階 0 の commit も probe もまだしない
- 2026-10-19 18:23 本人（原文）「実装に入って。」→ 段階 0 から着手（0013・0014 の本番は、段階 3 で別に本人 OK）
- 2026-10-22 00:0x 本人（原文）「6桁のコードに変えたい。また、サインイン画面のUI・UXもひどい。」（00:04 に答えた「再設定のリンクにプロジェクトの URL が必ず入るか」への返事。設計 §8 の 10-22 の節）→ パスワードの再設定はリンクをやめて 6 桁のコード（`{{ .Token }}`・`verifyOTP(email:token:type: .recovery)`）にする。サインインの画面の見た目と使い勝手を作り直す。どこが悪いか・何に合わせるかは本人に聞く。commit・push の問いは、これを直してから聞き直す
- 2026-10-22 00:10 に聞いた 3 問の答え: (1)「新規登録の確認メールも 6 桁のコードにするか」→「確認もコードに（推奨）」（元の指示「リンクを踏む」から変える。アプリのレビュー A1 も消える）／(2)「サインインの画面のどこがひどいか」（複数選択）→「Google の扱い・要らないものが出ている・主のボタンが分からない・設定の画面に見える」（AI が挙げた 4 つ全部）／(3)「何に合わせるか」→「参考のアプリを渡す（推奨）」→ 本人から参考のアプリのスクショか録画をもらい、同じ形にする
- 2026-10-22 00:2x 本人が参考のスクショ 3 枚（Slack・Amazon・Google のサインイン）を渡した → 共通点と違いを設計 §7 に記録 → 00:3x に聞いた「最初の画面はどの参考の形に合わせるか」（Slack 型（推奨）／Google 型／Amazon 型。AI 既定として 2 段（メール → パスワード）・主のボタンはアプリの青・Google の公式の部品・閉じている間は新規登録の入口を出さない、を添えた）→ 本人「Slack 型（推奨）」、メモ（原文）「または〜 の部分は不要。」→ AI の読み: 見出しの下の説明「または Google で続けてください」を消す（「または」の区切りの線は Slack どおり残す）。読みが違えば本人が言う、と伝えた
- 2026-10-22 01:2x 作り直し（Slack 型・2 段）の後に聞いた 2 問（アプリのアイコンの画像は今は無いことを添えた）: 「1 段目の見出しの上にアプリの顔を置くか」→「アプリ名の文字（推奨）」（上の小さな題「サインイン」をやめ、大きめの「LifeTracker」）／「Google のボタン」（公式の部品は青い四角・高さ 40 で、ほかのボタンは高さ 52・角丸）→「自前で揃える（推奨）」（同じ高さ・角丸の枠線・Google の 4 色の G・「Google で続ける」。ロゴの使い方の決まりは AI が公式の文書で確かめる）。あわせて AI 既定: コードの画面から戻ったとき 1 段目のメールアドレスを残す
- 2026-10-22 12:0x 本人（原文）「サインインの口がないのはなぜ？開けておいて。」（シミュレータで 1 段目を見て。「サインインの口」は新規登録の入口と読んだ）→ アプリの新規登録の入口を開けた（`AuthFeatures.isSignUpOpen = true`・「はじめての方は アカウントを作成」）。閉じていた理由は設計 §8 の AI 既定（配る準備ができるまで閉じる・00:3x の問いでも AI 既定として添えた）。ダッシュボードの新規登録のトグルは OFF のままなので、今は送るとサーバーが断り「今は新規登録を受け付けていません」と出る。トグルをいつ開けるかは本人に聞いた
- 2026-10-22 12:0x に聞いた「ダッシュボードの新規登録のスイッチをいつ開けるか」（0014 の後に開ける（推奨）／今すぐ開ける／閉じたまま。0014 の前は新しいアカウントからも本人のデータに届く・標準のメール送信はチームのメンバーにしか届かない・Google はテストの状態、を添えた）→ 本人「今すぐ開ける」→ 本人がダッシュボードで「Allow new users to sign up」を ON にする（U3 の表の「OFF」を変える）。設計 §8 の「配る準備ができるまで閉じる」は取りやめ
- 2026-10-22 12:1x 本人（原文）「allow new users to sign upをONにした」。あわせて本人の問い（原文）「これは実質的に新ユーザはサインアップできないことを意味している？」→ 答え【事実・https://supabase.com/docs/guides/auth/auth-smtp ・エラー `email_address_not_authorized`】: 標準のメール送信の間は、メールで登録を終えられるのは Supabase の組織のメンバーのアドレスだけ。Google は確認のコードを使わないが、同意の画面がテストの状態なのでテストユーザーだけ。ほかの人に開くには外部の SMTP と、Google の同意の画面の公開が要る
- 2026-10-22 12:1x に聞いた「チームのメンバー以外のアドレスで新規登録したとき、アプリはどう答えるか」（分かる文言を出す（推奨）／今のまま隠す。今のアプリは存在を隠す作りなので、サーバーが `email_address_not_authorized` で断ってもコードの画面に進み、コードは届かない）→ 本人（原文）「当たり前だが、誰でもサインアップできるようにしたい。」→ 目標は誰でも登録できること。要るもの（AI の整理・順に）: ①本番を人ごとに分ける（段階 3 の 0014。これより先にメールを誰にでも届くようにすると、知らない人が登録して本人のデータに届く）②外部のメール送信（送り手のドメインが要る見込み）③Google の同意の画面を本番に公開 ④ボットの登録への守り（CAPTCHA）⑤配る手段（Apple Developer Program）。アプリの文言の件は②で起きなくなるので、今は直さない
- 2026-10-22 12:1x に聞いた 2 問: 「メールの送り手に使える自分のドメインはあるか」→ 14:2x 本人（原文）「持っていない。どうしても独自ドメインのメールアドレスが必要なの？」→ AI の答え: 要らない。案は (A) 送るためだけの Gmail を新しく作り、その Gmail の SMTP（smtp.gmail.com・アプリ パスワード）で送る（本人の Gmail は使わない: 送り手として全員に見える・アプリ パスワードを Supabase に預けることになる）(B) ドメインを買って Resend など。どちらにするかは本人が決める（段階 3 の後でよい）／「段階 3 をいつ始めるか」→「画面の確認と commit の後（推奨）」
- 2026-10-22 14:2x 本人（原文）「A→Bに変えることはいつでもできるし、アプリ側の変更を伴わないはず。それなら一旦はAで進めたいんだけど。」→ (A) 送るためだけの Gmail の SMTP で進める（本人の読みのとおり、B への切り替えはダッシュボードの SMTP の設定だけで、アプリもメールのテンプレートも変わらない）。Supabase に入れるのは 0014 の後（入れた時点で誰でも登録を終えられる）。手順は U8
- 2026-10-22 14:3x 本人（原文・画面の確認）「そもそもプロフィールの入力やログアウトの場所がわかりづらすぎるでしょ。プロフィールタブを作るか右上か左上にプロフィール画面へ遷移するアイコンを置いておくのが一般的だと思うけど。」（今はトレーニング → 分析 → プロフィールのボタンの奥）→ 聞いた「入口をどこに置くか」（右上にアイコン（推奨・タブの枠を食事のために空けておける）／プロフィールタブ／左上にアイコン。どのタブも右上は使っていて、トレーニングは左上も使っている、を添えた）→ 本人「プロフィールタブ」→ 下のタブの最後に「プロフィール」を足す（食事のタブが入ると 5 つ）。AI 既定: 中身はプロフィール（性別・生年月日・体重）とアカウント（サインイン中のメールアドレス・サインアウト）／分析の「プロフィールを設定」は近道として残す／ProfileStore はアプリで 1 つにしてタブの間で同じものを見る（食事の設計 v1 §5 の方針と同じ）
- 2026-10-22 14:4x 本人（原文）「サインアップ画面は？また、サインイン画面においてメールアドレスの入力とパスワードの入力タイミングを分ける意図は？」→ 新規登録の画面のスクショを撮って見せた（題「新規登録」と見出し「アカウントを作成」が重なる・サインインは 2 段なのに新規登録は 1 画面）。2 段に分けたのは AI 既定（00:3x の問いに添えた）で、メールアドレスで次の画面を変える、という本来の理由はこのアプリに当てはまらない（存在を隠すため変えていない）と答え、「1 画面にまとめる（推奨）／2 段のまま」を聞いた → 本人のメモ（原文）「そもそもSlackのようにパスワードレスの方が良いのかな？」→ パスワードレス（メールのコード＋Google）の比べを示して「パスワードレス（推奨）／1 画面のメールとパスワード／併用」を聞いた → 本人が問いを止めて（原文）「最新のトレンドやセキュリティレベルをベースにどうすべきか検討したい。」→ サインインの方法の調べを deep-task に頼んだ → 14:4x 本人（原文）「deep taskをfableからopusにして。また、そこまで重く考えなくて良い。」→ fable の調べを止め（ファイルはまだ無かった）、opus で軽めに調べ直し（出力 `docs/auth-method-research-2026-10-22.md`）→ 14:5x 資料ができた（推奨: 主はメールのコード＋Google・パスワードは小さな入口だけ残す・期限 600 秒・配る前に Sign in with Apple。配る前に要るものとして、アプリの中でのアカウントの削除（審査の規則 5.1.1(v)）も分かった）。
- 2026-10-22 14:5x に聞いた 3 問（資料 `auth-method-research-2026-10-22.md` の問い）→ 15:0x 本人の答え: (1) サインインの主 →「B（コード＋Google だけ）」（推奨は C の軽い形＝パスワードの小さな入口を残す、だった）(2) コードの期限 →「600 秒（推奨）」(3) 配る前の Sign in with Apple →「Program に入るときに足す（推奨）」。これで、サインインはメールの 6 桁のコード（`signInWithOTP`→`verifyOTP`）と Google だけになる。パスワード・新規登録の画面・再設定・新しいパスワード・確認がまだ、の画面と状態はなくなり、登録とサインインは同じ流れ（はじめての人はコードを入れたときに登録される）。サーバーのパスワードのサインイン（API）は止められない（Email の provider に含まれる）ので残る。配る前に決めること: 審査用の入り方（B には審査の人の入口が無い・2.1(a)）・Sign in with Apple（4.8）・アプリの中でのアカウントの削除（5.1.1(v)）。本人の操作は U9（Magic Link のテンプレートをコードに・期限 600 秒）決まるまで、サインインの画面は作り直さない
- 2026-10-22 15:1x 本人（原文）「ログイン画面、サインイン画面で思っていたけど、全体的に上寄りすぎない？中央寄せして欲しいんだけど。」→ 認証の画面（サインイン・コード）の中身を縦の真ん中に置く。キーボードが出ても入力欄と主のボタンが隠れず、足りなければスクロールする（AI 既定）。作り替え中の opus に足して伝えた
- 2026-10-22 15:1x 本人「サインアップ画面も」→ B では新規登録の画面は別に無く、同じ画面で登録すると答え、「はじめての方も、同じ手順で登録できます」という意味の一文を入れると伝えた → 本人（原文）「絶対にやめて。上部にログイン・サインアップ と書けばいいだけでしょ。」→ 説明の一文は入れない。サインインの画面の見出しを「ログイン・サインアップ」（本人の言葉のまま）にする。opus に伝えた → AI「サインアウトもログアウトに揃えるか」→ 本人（原文）「サインイン、サインアップ、サインアウト に揃える」→ 見出しは「サインイン・サインアップ」。画面の言葉は「サインイン」「サインアップ」「サインアウト」に揃える（「ログイン」「ログアウト」「新規登録」を使わない。誤りの文言も「今はサインアップを受け付けていません」など）
- 2026-10-22 19:2x 本人: コードの画面の案内の 1 行「メールに届いた 6 桁のコードを入れてください」は「残す」（AI の推奨は消すだった。17 Pro に出して見せた後）。本物の認証でのコードのサインインは「今試す」（本人のアカウントは email と google の 2 つの identity。同じアカウントに入るだけ・確かめるのは登録済みの人の道。作業時間 17:2x）
- 2026-10-22 19:2x 本人（原文）「確かめる という文言嫌だから認証 とかにして」→ コードの画面の主のボタンを「確かめる」から「認証」に（本人の言葉のまま。identifier `auth.verifyCode` は変えない）
- 2026-10-22 19:3x 本人（原文）「さっき残すと言ったけど、やはり撤回する。コードを入れる 届いたコードを入力してください ↑は2重に記述しているから片方だけで良い。太字の方を残して、文言は「入力したメールアドレスに届いた認証コードを入力してください」にして」→ 19:2x の「残す」を取り消し。コードの画面は見出し（太字）だけにし、文言は「入力したメールアドレスに届いた認証コードを入力してください」（本人の言葉のまま）。灰色の案内の 1 行は消す
- 2026-10-22 19:4x `email_address_invalid`（Supabase が送る前の確かめでアドレスを断った）の文言を聞いた → 本人「正しくありません（推奨）」→「メールアドレスが正しくありません。確かめて、もう一度入力してください」
- 2026-10-20 02:2x に聞いた「SQL のレビューが Fable の利用上限で止まった。どう続けるか」（選択肢: opus で今見て、段階 3 の前に Fable でもう一度（推奨）／Fable が使えるまで待つ・待つ間は段階 2 を先に進める／ここで止める）→ 10-21 17:1x 本人の選択「Wait for Fable」→ SQL のレビューは Fable で行う（利用上限が戻るのを待つ。/usage-credits を使うかは本人）。待つ間に段階 2（アプリ）を先に進める（計画の「すべて直列」から外れる。レビューで SQL の名前が変われば、アプリも直す）。なお、この質問は AI が英語で出した（memory `feedback_japanese_in_questions_and_images`）

## 本人に聞くこと・知らせること

【10-22 19:5x 注記】下の「聞く」は 10-19 18:23 に本人「実装に入って。」で済み。今の答え待ちと次の順は memory `project_life_tracker_auth_multiuser` の「次」と、作業時間の最後の行

- **聞く（1 問）**: この計画で実装に入ってよいか。OK には次を含む: 段階 0 の commit（push しない）、本番への確かめの migration `probe_txn` を 1 回流すこと（表を 1 つ作って失敗させるだけ。残ったらすぐ消す）
- **AI 既定として知らせる**（違えば言ってもらう）:
  - 0013 で `task_template` の中身の列を 5 つとも消す（§1-2。レビューで妥当）
  - 0013 の前提（新しいビルドでの確認）は満たしているとみなす（§1-2）
  - Google は nonce を渡し、「Skip nonce check」は OFF のまま（設計から変える。§2-3。レビューで成立を確認）
  - パスワードの再設定は、リンクのまま、アプリ側の印で「新しいパスワード」の画面を出す（§2-1・P2）
  - 新しいビルドは 0013 の直前に入れてもらう（§前提・U6・P4。あなたの操作の順が変わる）
  - 新規登録の確認メールを端から端まで確かめるのは、配る準備のとき（§2-8 の 4）
- **頼む操作**: §0-4 の U1〜U7（いつまでに、の欄のとおり）

## 作業時間

- 2026-10-19 14:48 着手（本人「実装計画へ」）。14:55 下書きを書き始めた
- 2026-10-19 15:0x〜15:4x deep-task のレビュー（途中、利用制限で止まり 15:2x に再開）
- 2026-10-19 15:4x レビュー（P1〜P24）をすべて反映（AI が直してよい点のみ。本人に聞く点は無し）。反映前の写しは scratchpad
- 2026-10-19 17:0x 本人「1だが、まだ待って。」（計画は OK・着手は合図待ち）
- 2026-10-19 18:23 本人「実装に入って。」→ 段階 0 に着手
- 2026-10-19 18:23〜18:30 段階 0: commit 3 つ（`f3300cc` 連続週数・`89b68e7` 種目の画像・`40d51c3` AGENTS.md。push はしない）。各 commit の状態で単体テストが全件成功（1 つ目だけの状態 326 件は worktree で、2 つ目の状態 328 件）。UID 2 件を memory に。probe_txn → 1 つのトランザクション（§0-3）
- 2026-10-19 18:2x〜 段階 1: `supabase/test/`（Dockerfile・`auth_stub.sql`・`run.sh`）を親が書いた（計画では opus。小さいので親が書いた）。0001〜0012 が通り plpgsql_check の error 0、わざと壊した関数 2 つ（消した列・`search_path = ''` で修飾なし）は検出された。0013 を書き、0001〜0013 が通る（`schedule_template_create` を呼んで系列と休日の登録ができる）
- 2026-10-19 18:31〜18:36 0014 の表・制約・権限・RLS（l 以外）を親が書いた（計画では opus。設計の細部を持つ親が書く方が早いため）。docker で 0001〜0014 が通り、policy 24・RLS の付け忘れ 0・anon の表と関数の権限 0・authenticated の TRUNCATE と MAINTAIN 0。新しい人で `ensure_user_defaults()` を 2 回呼んで 3 行のまま、`schedule_template_create` が通る。事前に docker で、`auth.users` からの CASCADE と子の RESTRICT の組が、どちらの順で消えても止まらないことを確かめた（外部キーの削除の動きは今のまま）
- 2026-10-19 18:36〜18:45 l（関数 28 個）を opus に依頼 → plpgsql_check の error 0、0013 の後の定義と比べて修飾のほかの差分 0、19 の RPC を authenticated で一通り呼んで通る。親が差分を読んだ（SET CONSTRAINTS の名前・コメントは残る）
- 2026-10-19 18:4x〜18:52 戻しの SQL・確かめ（`write_all.sql`・`multiuser_test.sql`・`checks.sql`・`normalize_schema.py`）を親が書いた（計画では opus）。結果:
  - `run.sh`: 0001〜0014 → plpgsql_check の error 0 → multiuser_test（§1-5 の 1〜10）全部通る → checks.sql（31 項目）全部 t
  - `run.sh --rollback`: 0013 の後と「0014 → 戻し」の後で、形（順序をそろえた pg_dump）と既定の権限の差分 0。列の並びだけは戻らない（足し直した列は末尾。normalize_schema.py が並びを無視する）
  - わざと壊して確かめが落ちるか（5 通り）: sleep_record の RLS を外す・anon に SELECT を与える・SET CONSTRAINTS の名前の修飾を外す・外部キー 1 本を 1 列に戻す・policy を全員向けにする → どれも multiuser_test が FAIL（SET CONSTRAINTS のほかは checks.sql も f）
  - `--owner <uuid>` で本人の UID を差し替えても通る（本番の写しのリハーサル用）
  - 決めたこと【AI 既定】: 子の外部キーの削除の動き（RESTRICT）は今のまま。`auth.users` からの CASCADE と RESTRICT の組が、どちらの順で消えても止まらないことを docker で確かめた（§1-5 の 8 で人 C を消して全表 0 も確認）
- 2026-10-19 18:52 deep-task に SQL のレビュー（§1-6）を依頼 → 途中で利用制限（20:20 まで）で止まり、20:28 に再開 → また利用制限（10-20 01:20 まで）で止まり、10-20 02:23 に再開。止まっても残るよう、指摘はその都度ファイルに書き足すよう頼んだ → 10-20 02:2x に Fable の利用上限で 3 回目の停止（出力のファイルは無し）→ 本人に聞き、10-21 17:1x「Fable を待つ・その間に段階 2」
- 2026-10-21 17:1x Fable のレビューを同じエージェントで再開（指摘はその都度ファイルに書き足す）。17:14 段階 2 の順 8（§2-1〜2-4）を opus に依頼。細部の決定【AI 既定】: GoogleSignIn-iOS は 10.0.0（最新の安定版）、xcconfig の Google の 2 行は `unset` の印で足し、印のままなら Google のボタンを出さない（→ 10-21 23:0x に変更: ボタンは出し、押すと「Google の設定がまだです」。実装の形に合わせた。アプリのレビュー A6）。`ensure_user_defaults` は `ScheduleDataSource.ensureUserDefaults()` を通す。テストの決まったメールは `test@example.com`
- 2026-10-21 17:14〜17:5x 順 8 の結果（opus）: `Sources/Auth/`（AuthService・SupabaseAuthService・MockAuthService・AuthStore・AuthFailure・PasswordPolicy・GoogleSignInHelper）・`Sources/Views/Auth/`（7 画面）・`LaunchPlan.swift`・`LifeTrackerApp.swift`（AppRootView・MainTabView に `.id(uid)`）・`ScheduleDataSource.ensureUserDefaults()`・Info.plist・xcconfig の例・GoogleSignIn-iOS 10.0.0。ビルド成功、単体テスト 364 件（328＋36）すべて成功、シミュレータで `-mock-auth`／`-mock-auth-signed-out` の流れを確認。親が AuthStore・起動の組み立て・失敗の分け方・画面 2 枚を読んだ
  - 事実（親がソースで確かめた）: supabase-swift 2.44.1 の `resend` は `code_challenge` を送らない（`ResendEmailParams` に欄が無い）。再送した確認メールのリンクは implicit 形式で戻り、PKCE の `session(from:)` は受け付けない見込み【推測】。`resetPasswordForEmail` は PKCE（`prepareForPKCE`）
  - 決定【AI 既定】: implicit 形式の戻り（fragment に access_token）はセッションを作らず（`setSession` は使わない・ログインの CSRF を避ける）、「メールアドレスを確認しました。サインインしてください」でサインインの画面へ。新規登録は閉じているので今は起きない。配る準備のときに 6 桁のコード（設計 §7 の代案）も含めて見直す
  - 細部（opus が決め、親が妥当とした）: サインインで `email_not_confirmed` なら確認待ちの画面へ／新しいパスワードの画面に「やめてサインインの画面に戻る」／存在を隠す応答は、新規登録を閉じている・パスワードが足りない・通信できない、のときだけ文言を出す／通信の失敗はリンクを「無効」と言わない
- 2026-10-21 17:54 順 9（§2-5〜2-7・UI テスト・上の implicit の扱い）を opus に依頼。42501 の文言は data source の境界で `LocalizedError` に変える形に決めた（画面の各所の `localizedDescription` を直さずに済む）
- 2026-10-21 18:09 Fable の SQL レビューがサーバーのタイムアウトで止まった（4 回目・ファイルはまだ無し）→ 途中の指摘を先にファイルへ書くよう頼んで再開
- 2026-10-21 18:2x Fable の SQL レビューが完了（`auth-multiuser-sql-review-2026-10-19.md`・高 0・中 3・低 7・本人に聞く点なし）。非 superuser の postgres（本番の権限の形）でも全部通ることをレビューが docker で確かめた
- 2026-10-21 18:3x〜18:38 親が直した: S1 `run.sh --dump` の `CREATE SCHEMA public` を TOC から外す／S2 `workout_set_entry_fk` を `(entry_id, exercise_id, user_id)` の組に（`workout_entry` に `UNIQUE (id, exercise_id, user_id)`・旧い一意は消す・戻しに逆。組の外部キーは計 19 本）／S3 A が自分の行を B に渡せない（全表の UPDATE と INSERT で 42501）／S4 anon の前提（public の USAGE）／S5 `supabase/test/counts.sql` と run.sh の行数の照合（0013 の前の全部の行 = 0014 の後の本人の行）／S8 0014 の先頭に 67KB の代替の注記／S9 B にも昨日のセットを入れて view の分離を見る。S6（service_role は private を呼べない）・S10（MCP で exercise に user_id を忘れると共有になる）は段階 4 の docs へ。S7 は影響なし
  - 確かめ: `run.sh` 全部通る（checks 31 項目）／`run.sh --rollback` 差分 0／0012 の写し（データ入り）で `run.sh --dump --owner <仮の UID>` → 行数が全部一致 → 全部通る／同じ写しで `--rollback` も差分 0／わざと壊した 7 通り（前の 5 通り＋WITH CHECK を外す・セットの外部キーを 2 列に戻す）はどれも multiuser_test が FAIL
- 2026-10-21 17:5x〜18:3x 順 9 の結果（opus）: `DataAccessError`／`DataAccessGuard`（42501・PGRST3xx を境界で変える・更新は 1 本だけ）・`SignInSideEffects`（片付け）・`SignOutSection`（プロフィールの一番下・確認つき）・種目は `exercise_for_user`・衝突先 3 つ・`fetchTaps` の投げ分け・ウィジェットの「アプリでサインインしてください」・implicit 形式の知らせ・UI テスト（3 か所の起動引数＋サインインからサインアウトまでの 1 本）。単体テスト 384 件・UI テスト 7 件すべて成功。変更前と後をシミュレータの画素で比べ、今の画面が変わっていないことを確かめた（プロフィールはサインアウトの節が増えただけ）
- 2026-10-21 22:4x 親が差分を読んで直した【AI 既定】: 起動して端末にセッションが無いときも片付ける（片付けを経ずにセッションが無くなった端末で、ウィジェットに前の人の記録を残さない。opus の問い 1）／`DataAccessGuard` の「更新中か」をロックで守る（data source は main actor の外から並んで呼ばれる）。確認のダイアログの文言（「記録はサーバーに残ります…」）はそのまま。UI テストの注意を repo の `CLAUDE.md` に。単体テスト 384 件すべて成功
- 2026-10-21 22:4x〜23:0x 認証の層の deep-task レビュー（順 10・P22。`auth-multiuser-app-review-2026-10-21.md`・高 0・中 5・低 13・本人に聞く点なし）。守り（PKCE・implicit・ログ・Keychain・Release への漏れ・nonce）に穴なし、42501 の包みは 55 か所すべて、0014 との整合と P4 の主張も一致
- 2026-10-21 23:08 直し: コード（A2・A3＋A14・A4・A5・A7・A8・A12・A16・A17）を opus に依頼。docs（A1 は §2-8 の 4 に「配る前に 6 桁のコード・それまで新規登録は閉じたまま」、A6 はボタンを出す実装の形に計画を合わせた、A9・A10 は U3 に、A11 は §2-6 と U6 に、A13・A15 は段階 4 の一覧と設計 §7、SQL レビューの S6・S10 も段階 4 の一覧）は親が直した
- 2026-10-21 23:07:42 `Info.plist` から `CFBundleIdentifier` の 2 行が消えた（同時刻に project.pbxproj も保存。23:06 から Xcode が起動中。Xcode の画面の操作か Xcode の書き換えの見込み【推測】）。単体テストが「Missing bundle ID」で起動しなくなった → 23:1x 親が HEAD と同じ 2 行に戻した。本人に知らせた
- 2026-10-21 23:28 本人（原文）「U1：Free／U2：済み／U3：済み」→ バックアップは U4 の `pg_dump` だけ（日次のバックアップは無い）。Google のクライアント ID は本人が xcconfig に入れた（親は中身を見ず、印 `unset` が残っていないことだけを数えて確かめた）。ダッシュボードの設定（確認メール・パスワード・Google・新規登録 OFF・戻り先）も済み → シミュレータで本物の認証＋メモリ上のデータの確かめ（§2-8 の 3）ができる
- 2026-10-21 23:0x〜23:4x アプリのレビューのコードの直し（opus）: A2（`appliedChanges` で順序を決め、守りを消すと落ちるテストに）・A3＋A14（`makeSetup(plan:makeClient:sideEffects:)`、メモリ上の認証では片付けを何もしない）・A4（サインアウトで `GIDSignIn.signOut()`）・A5（サインアウトを経ずに人が変わるとき先に片付け）・A7・A8・A12・A16・A17（`classify` を切り出しテスト 2 件）。単体テスト 387 件・UI テスト 4 関数すべて成功。件数の食い違い（384／383）は、xcodebuild のログの行を数えたため（ログは行を落とすことがある）で、xcresult の 384 が正しかった。件数は `xcresulttool get test-results summary` で数える
- 2026-10-21 23:32 親が A5 の残りを直した: 別の人の再設定のリンクで「新しいパスワード」へ直接入る道でも、先に前の人を片付ける（`cleanUpIfUserChanges` を 2 か所から）。テストを `switchUser` に足し、単体テスト 387 件すべて成功。A14 の残り（`-mock-workout` を実機で付けると `ContinuityStore` がメモリ上のデータでウィジェットを上書きする）は認証の前からの動きなので触らない
- 2026-10-21 23:3x〜23:52 §2-8 の 3（シミュレータ・本物の認証＋メモリ上のデータ・本番の DB には触れない）:
  - メール＋パスワード: 本人がシミュレータで入れて通った（23:37。`auth.users` の last_sign_in で本人と確かめた）。プロフィールからサインアウト → サインインの画面
  - Google: 通った（23:41）。`auth.identities` に google が本人の UID で足され、ユーザーは 2 人のまま（同じ確認済みのアドレスで 1 人にまとまる・新規登録 OFF でも通る・nonce を渡し「Skip nonce check」OFF で通る）。本人「life-tracker がなぜか改行されてた」→ 画像は届かず未確認。Google の同意の画面のアプリ名（`-` で折り返す）の見込み【推測】と伝えた
  - 再設定: 1 回目は失敗。認証のログ: 23:47:03 メール → 23:47:22 /verify 成功（code を発行）→ その後 9 回の /verify が「One-time token not found」。最初の「LifeTracker で開きますか?」が Safari の案内の吹き出しに隠れて押されず、後の開き直しで使い切りのリンクが無効になった見込み【推測】。最後の開き直しの戻りでアプリは「リンクが無効です…」を出した（P19 の文言の確かめにもなった）。本人がリンクの URL を会話に貼った（使い切り済みで再利用はできない）。2 回目のメールでやり直す
  - 再設定の 2 回目: 通った。23:55 メール → 23:57 /token（grant_type pkce・recovery）→ 新しいパスワードの画面 → 23:58 PUT /user → タブの画面。サインアウト → 新しいパスワードで 23:59 にサインインできた（本人の UID）。本番のアカウントのパスワードは本人が決めた新しいものに変わった
  - 機内モードでの起動はシミュレータで切り替えられないので、段階 3 の後に実機で見る（§2-8 の 6 と一緒に）
  - 気づいた運用の注意: シミュレータの Safari は初回に案内の吹き出しを出し、「LifeTracker で開きますか?」を隠す。再設定のリンクは 1 回だけ開き、確認が出なければ開き直さずに画面を見る（開き直すと使い切りのリンクが無効になる）
- 2026-10-22 00:23 本人（原文）「U7済み」→ 確認メールと再設定のメールのテンプレートは 6 桁のコードになった（メールにリンクが入らない）。今のアプリ（リンクの形）では、ここから先の再設定・確認はコードの画面ができるまで使えない（新規登録は閉じている・再設定は今は使わない）
- 2026-10-22 00:1x〜00:5x メールのリンクを 6 桁のコードに替えた（opus）: `verifyEmailCode`（`verifyOTP(email:token:type:)`・`.signup`／`.recovery`）・新しい状態「再設定のコードの入力」・`EmailCodeInput`（空白とハイフンを取り除き 6 桁の数字）・`codeInvalid`（GoTrue の `otp_expired`＝誤り・期限切れ・人が見つからない、の全部【事実・verify.go】）・再設定の印（P2）を消した・`handle(url:)` は古いリンクのために残した。単体テスト 395 件・UI テスト 5 件すべて成功。シミュレータで再設定と確認の流れを確認
  - 事実（opus がソースで確かめた）: supabase-swift の `verifyOTP` は成功すると `.signedIn` を流してから返る（`.passwordRecovery` は流さない）→ 確かめている間の `.signedIn` は無視する守り（`sessionHandoffsInFlight`）を置いた／GoTrue はコードを `pkce_` 付きの形とも比べるので、PKCE で頼んだ再設定もコードで通る／`/verify` の送りすぎは 429
  - 残し: 確認がまだのとき「送りました」と出る誤り・古い印のキーの掃除・新規登録の「強力なパスワード」の案内 → 作り直しで扱う。計画 §2-1（P2）・§2-2・§2-7・設計 §7 のリンク・印の記述は、作り直しの後に親が直す
- 2026-10-22 00:48 同じ opus に Slack 型への作り直しを依頼（2 段・共通の見た目の部品・Google の公式の部品（`GoogleSignInSwift` を pbxproj に足す）・閉じている間は新規登録の入口を出さない・6 つの枠のコードの画面・規則が見える新しいパスワード・明暗のスクショ）
- 2026-10-22 00:5x〜01:2x Slack 型への作り直し（opus）: 共通の見た目の部品（`AuthFormParts`）で全部の認証の画面を組み直し、List・Form をやめた。2 段のサインイン・再設定のコードを送る・6 つの枠のコード・新しいパスワード（規則の ✓）・確認がまだ（新しい状態 `.confirmationNeeded`・何も送っていないのに「送りました」と出る誤りを直した）・新規登録（入口は `AuthFeatures.isSignUpOpen = false` で出さない）・古い印のキーを起動時に消す。分かったこと: SecureField を TextField に差し替えると iOS が送ったとみなして保存の案内を出すので、2 つの欄を重ねて見える方だけを替えた
- 2026-10-22 01:2x〜01:3x 本人の 2 つの決定を入れた（opus）: 1 段目・2 段目の上に「LifeTracker」の文字／Google のボタンは自前（高さ 52・角丸 12 の枠線・GoogleSignIn-iOS に入っている公式の G の画像 18pt・「Google で続ける」）。Google のブランドの決まり（https://developers.google.com/identity/branding-guidelines ）の色（明: 塗り #FFFFFF・枠 #747775・文字 #1F1F1F／暗: #131314・#8E918F・#E3E3E3）と iOS の余白に合わせた。決まりのフォント Google Sans は入れられないのでシステムのフォント（決まりから外れる 1 点）【AI 既定】。文言は「Continue with Google」の訳の「Google で続ける」のまま【AI 既定】。GoogleSignInSwift の product は外し、pbxproj は作り直しの前と同じ。コードの画面から戻ったとき 1 段目のメールアドレスを残す（`lastEmail`・メモリだけ）
- 2026-10-22 01:40 親が確かめた: 画面（1 段目の明暗）を見た・単体テスト 403 件すべて成功（UI テスト 5 件は opus の実行で成功）。pbxproj と Info.plist の HEAD からの差分は、順 8 の GoogleSignIn と URL Types の分だけ
- 2026-10-22 01:40 本人に、作り直した画面のスクショの確認と、本物の認証でコードの流れを試すかを聞いた → 11:5x 本人「sumilatorで出して。」→ 本物の認証・メモリ上のデータ（`-mock-day -mock-workout`）で起動中のシミュレータ（iPhone 17 Pro）に入れた
- 2026-10-22 12:0x 新規登録の入口を開けた（上の「本人の決定」）。それを確かめるテストも開いている向きに直した。単体テスト 403 件すべて成功・UI テスト 5 件すべて成功
- 2026-10-22 14:3x〜14:5x プロフィールのタブ（opus）: `MainTabView` に 4 つ目のタブ「プロフィール」（`Sources/Views/Profile/ProfileView.swift`）。節「プロフィール」（性別・生年月日・体重の表示と、`ProfileSheet`・`BodyWeightSheet` で直す）と節「アカウント」（`AuthStore.signedInEmail` のメールアドレス・サインアウト）。`ProfileStore` は `MainTabView` で 1 つ作り、トレーニングとプロフィールのタブで同じものを見る（プロフィールのタブで体重を入れると分析にすぐ出ることを画面で確認）。`ProfileSheet` からサインアウトを外した。`AuthService.currentEmail`（Supabase は端末のセッションの user の email・通信しない）。単体テスト 407 件・UI テスト 5 件すべて成功（opus の実行）。Info.plist と pbxproj は前後で同じ
- 2026-10-22 14:5x 親が確かめた: 明るい画面・暗い画面のスクショを見た・新しいビューを読んだ・単体テスト 407 件すべて成功（親の実行）・計画 §2-6 と設計 §7 のサインアウトの置き場を直した・本人の iPhone 17 Pro のシミュレータ（本物の認証・メモリ上のデータ）に入れ直した
- 2026-10-22 15:0x〜15:3x パスワードレスへの作り替え（opus）: `AuthService` は `sendEmailCode`（`signInWithOTP(email:redirectTo:shouldCreateUser: true)`）・`verifyEmailCode`（`verifyOTP(type: .email)`）・Google・`session(from:)`・サインアウト・`currentEmail` だけ。状態は 起動中・未サインイン・コードの入力・サインイン済み の 4 つ。新規登録・確認・再設定・新しいパスワードの画面と `PasswordPolicy`・`AuthFeatures` を消した（`AuthInput.swift`・`ObsoleteAuthKeys.swift` に名前を変えて残りだけ）。画面は「LifeTracker」・見出し「サインイン・サインアップ」・メールの欄・「コードを送る」・「または」・Google、コードの画面は「コードを入れる」・送り先と「変更」・6 つの枠・「確かめる」・60 秒の送り直し。認証の画面は共通の外枠 `AuthScreen` で縦の真ん中（キーボードが出たら残りの高さの真ん中・足りなければスクロール）。言葉は「サインイン」「サインアップ」「サインアウト」に揃えた（「今はサインアップを受け付けていません」ほか）。失敗の文言に `email_address_not_authorized`（「このメールアドレスには、今はコードを送れません」）と `email_provider_disabled`（「今はメールのコードでサインインできません」）を足した。分かったこと【事実・GoTrue の master と supabase-swift 2.44.1 のソース】: `verifyOTP` の type `.email` は確認のトークンと RecoveryToken の両方と比べるので、新しい人と登録済みの人の両方で通る／新しい人・確認がまだの人には「Confirm signup」、確認済みの人には「Magic Link」のテンプレートが使われる（本番の GoTrue の版が master と同じかは未確認）。単体テスト 396 件・UI テスト 5 件すべて成功（opus の実行）
- 2026-10-22 15:4x〜16:2x 親が確かめた: スクショ 5 枚（明暗・コードの画面・iPhone 16e でキーボードが出た状態）を見た・単体テスト 396 件すべて成功（親の実行）・画面の文字に「ログイン」「ログアウト」「新規登録」が無いことを grep で確かめた・Info.plist と pbxproj の HEAD からの差分は前と同じ（順 8 の分だけ）・本人の iPhone 17 Pro のシミュレータに入れ直した。repo の CLAUDE.md の UI テストの行を直した
- 2026-10-22 15:3x より前（作り替えの途中・時刻は未確認）に起きたこと（opus の報告）: iPhone 16e のシミュレータでメールの欄に貼り付けたところ、Mac のクリップボードの中身（資格情報のように見える文字列）が欄に入り、スクショに写った。opus はその画像をすぐ消し、値はどこにも書いていない。シミュレータの貼り付けは Mac のクリップボードとつながる。以後、サブエージェントに文字を入れさせるときは貼り付けを使わせない
- 2026-10-22 17:2x 本人「その画面をsimulatorでみせて」（コードの画面の案内の 1 行を消すかの問いに）→ 本人の iPhone 17 Pro のシミュレータを `-mock-auth-signed-out -mock-day -mock-workout` で起動し直し、ダミーのメール（example.com）でコードの画面を出した（メールは送っていない・本物のセッションには触れない）。日本語の入力が有効で、`idb ui text` の英字がローマ字の変換になった → 打つ前に Caps Lock（`idb ui key 57`）で英字の入力に切り替えると、そのまま入った
- 2026-10-22 17:2x 本人「私のアカウントはすでに紐づいちゃったのでは？」→ 本番の `auth.users`・`auth.identities` を読むだけの SQL で確かめた（メール・UID は出さない）【事実】: ユーザーは 2 人のまま（10-22 12:1x に新規登録を開いてから増えていない）。本人（04-14 作成）は email と google の 2 つの identity・パスワードあり・最後のサインインは 10-22 11:58 JST。テスト用の 2 人目は email だけ

- 2026-10-22 19:2x 本人がシミュレータ（iPhone 17 Pro・本物の認証・メモリ上のデータ）で、サインアウト → 本人の Gmail → メールのコードでサインインした（本人「できた。」）。本番を読むだけの SQL で確かめた【事実】: 本人のアカウント（04-14 作成）の最後のサインインが 19:28 JST に更新・identity は email と google の 2 つのまま（google の最後のサインインは 10-21 23:41 のままなので、Google ではなくコードで入った）・セッションは 1 つ（サインアウトで前のは消えた）・ユーザーは 2 人のまま。登録済みの人の道（Magic Link のテンプレート・`verifyOTP(type: .email)`）は本番で通った。新しい人の道（Confirm signup）は U8 の 4 の後に確かめる
- 2026-10-22 19:2x「確かめる」→「認証」に直した（`EmailCodeView.swift` と UI テストのコメント）。ビルド成功・17 Pro に入れ直し、試し用の認証でコードの画面を出してボタンが「認証」になったのを見た → 17 Pro は本物の認証に戻した
- 2026-10-22 19:3x コードの画面の見出しを「入力したメールアドレスに届いた認証コードを入力してください」（`EmailCodeView.headline`）にし、灰色の案内の 1 行と `AuthCaption` を消した。`EmailCodeInput.guidance`（「メールに届いた 6 桁のコードを入れてください」）は 6 桁に足りないときの文言として残る。単体テストの言葉の確かめに見出しを足した。ビルド成功・17 Pro で見た（見出しは「…届いた／認証コードを入力してください」の 2 行）→ 17 Pro は本物の認証に戻した。19:2x の UI テストはターミナルが止まって結果が出なかったので、単体テスト全部と UI テスト 2 本を Pro Max で流し直した → 398 件すべて成功（単体 396・UI 2（`testSignInWithCode`・`testSignInThenSignOutFromProfile`）。xcresult の summary で数えた。途中に UI テストの runner の起動の失敗が 1 回出たが、結果は成功）- 2026-10-22 19:4x 本人「存在しないメールアドレス（aaa@jj.ma のようなもの）を入力したら「うまくいきませんでした。時間をおいて、もう一度お試しください」と表示されたんだけど、何が原因？」→ 調べた【事実】: 本番の認証のログ（19:43 JST）で `POST /otp` が 400 `email_address_invalid`（「Email address "…" is invalid」）。GoTrue（master の `internal/mailer/validateclient/validateclient.go`）はメールを送る前にアドレスを確かめる: 形式・決まった無効なアドレスと名前（`test@gmail.com`・`.test`・`.example`・`.invalid`・`.local`・`localhost` ほか）・gmail.com で @ の前が 6 文字未満・ドメインに MX か A の記録が無い → どれも `email_address_invalid`。今回はドメインが DNS に無かった。アプリの `AuthFailure.from` にこのコードの分け方が無く（supabase-swift 2.44.1 にも定数が無い）、`unknown` に落ちて「うまくいきませんでした…」が出た（待っても直らないので文言が合っていない）。新規登録の途中で止まったので、`auth.users` は 2 人のまま（行は残っていない）。ドメインはあるが受信箱が無いアドレス（例: 存在しない gmail）はこの確かめを通る（今は標準の送信なので `email_address_not_authorized`、U8 の後は送られて届かないだけ）

- 2026-10-22 19:4x〜19:5x `AuthFailure.emailAddressInvalid` を足した（`email_address_invalid` → 上の文言。supabase-swift 2.44.1 に定数が無いので `AuthFailure.emailAddressInvalidCode` で比べる）。単体テストを 1 件足し、分け方と言葉の確かめにも足した → 単体テスト 397 件すべて成功（Pro Max・xcresult の summary）。本物のサーバーで確かめようと、Pro Max（未サインイン・本物の認証）で aaa@aaaa.jj を送ったら、19:52 に 429 `over_email_send_rate_limit`（標準の送り手の 1 時間の送信数の上限。19:27 の本人のコードと 19:43 の試しの後）→ アプリは「しばらく待ってから、もう一度お試しください」を出した（分け方どおり）。新しい文言を本物で見るのは上限が戻ってから。17 Pro にも新しいビルドを入れた（17 Pro は 19:43 に本人がサインアウトしていて、サインインの画面のまま）
- 2026-10-22 19:5x 分かったこと【事実・本番のログと supabase-swift 2.44.1 のソース】: アプリのサインアウト（`SupabaseAuthService.signOut` → `client.auth.signOut()`）は既定の `scope: .global` で、`POST /logout?scope=global` を送る。その人のすべての端末のセッションが消える（ほかのシミュレータで同じアカウントからサインアウトすると、17 Pro も外れる）。この端末だけにするなら `.local`。設計・計画には書いていなかった（決めてはいない）
- 2026-10-22 23:2x 本人「commit & pushしていいよ」→ `feat/round3-training` に 3 つ（e0e5574 feat(db)・81da7a7 feat(ios)・7648207 docs）と段階 0 の 3 つを push。前に公開してはいけないもの（メールアドレス・UID・キー・クライアント ID・実名）を走査し、単体 397 件成功
- 2026-10-23 00:1x 本人「段階3に入って」→ 段階 3 に着手。本番の migration は 0012（`v2_untimed_tasks`）まで【事実・list_migrations】。`auth-multiuser-user-steps.md` の U5・U6 の 3・4（パスワード・メールのリンク）をコードの形に直した。U4（本人の `pg_dump`）を依頼
- 2026-10-23 00:2x U4 済み（本人のターミナル・`~/Backups/life-tracker/2026-10-23-before-0013.dump`・00:21 作成・145KB・public と private・表 21・データ 21・private の関数 6）。本番の表ごとの件数（読むだけの SQL）とバックアップの件数が全部一致（例: workout_set 118・exercise 159）
- 2026-10-23 00:2x リハーサル（§3-1）【事実・docker】: `run.sh --dump … --owner <UID>` は全部通った（0013 → 0014 → 行数の照合で 0013 の前の全部 = 0014 の後の本人・exercise は共有 159・plpgsql_check の error 0・multiuser_test 全部・checks 31 項目すべて t・関数の定義の md5 `6070b8acfbce6843e1a656b4a307456d`）。`--rollback` は差分が 2 種類で止まった: (1) v1 の残りの関数 6 つ（`fn_resolve_month_patterns`・`sync_did_*` 4 つ・`update_updated_at`）と権限。0014 の o で消し、戻しは戻さない決まり（§1-4「v1 の残りの関数 6 つは戻さない」）。空の DB の確かめには無いので、本番の写しで初めて差分に出た (2) `workout_entry_reorder` の本文のコメント 1 行（「関数の終わりで検査を戻す…」）。本番の今の定義には無く、repo の 0010 と戻しの SQL にはある。動きは同じ。どちらも戻しの目的（0014 の前の形に戻す）には害が無いので、このまま段階 3 を進める
- 2026-10-23 00:2x 本人「U6済み」→ 00:27 0013 を本番に（`v2_drop_legacy_template`・version 20261022152744）。`pattern_template_membership` が無い・`task_template` の列は `id` だけ・行はそのまま（4・世代 7）。本番に記録された SQL の md5 が repo のファイルと一致【事実】
- 2026-10-23 00:3x 0014 の 1 回目は MCP が「Invalid or expired requestState」で返った（本人「確認の期限が切れたかも」）。読むだけの SQL で何も流れていないことを確かめた（記録 0・`user_id` の列 0・policy 0）。0014 の直前の件数は 0013 の後と同じ
- 2026-10-23 00:43 0014 を本番に（2 回目・`v2_multiuser_rls`・version 20261022154341）。確かめ【事実】: 本番に記録された SQL の md5 が UID を置き換えたファイルと一致／checks 31 項目すべて t・関数の定義の md5 `6070b8acfbce6843e1a656b4a307456d` がリハーサルと同じ／本人の行は 19 表すべて 0014 の前の件数と一致（セット 118・セッション 11 ほか）・exercise は共有 159／2 人目（`SET LOCAL ROLE authenticated`＋claims）からは全表・view が 0 行で、共有の種目 159 だけ見える／anon キーだけでは表・view・RPC・INSERT がすべて 401（42501）／advisor（security）は漏えいしたパスワードの検査の WARN 1 件だけ。0013・0014 の先頭の「本番適用」を済に直した
- 2026-10-23 00:4x 本人が実機でアプリを起動し直してサインイン（最後のサインイン 00:49 JST【事実・auth.users】）→ 本人「全タブ OK」。`ensure_user_defaults` で行は増えていない（pattern 1・category 4・種類 2）【事実】。段階 3 の §3-2 は全部済み。次は U8（Gmail の SMTP）→ 新しい人の道（Confirm signup）の確かめ
- 2026-10-23 01:0x 本人「U8済み」（送るためだけの Gmail・2 段階認証・アプリ パスワード・Supabase の SMTP の設定。アドレスとパスワードは会話・repo に書いていない）→ 新しい人の道の確かめに、iPhone 17 Pro のシミュレータを本物の認証・本物のデータで起動し直した（サインインの画面）
- 2026-10-23 01:0x 本人「後ででいい？先にさっき決めたトレーニング側の修正を入れたい」→ 新しい人の道（U8 の Gmail で新規登録してコードが届くか）の確かめは後に回す。17 Pro のシミュレータは本物の認証・本物のデータでサインインの画面のまま
