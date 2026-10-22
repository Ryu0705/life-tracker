# サインインと複数人化 設計レビュー（2026-10-19）

対象: `auth-multiuser-design.md`（14:0x の下書き）。番号 D1〜D9・F1〜F3・A1〜A8 は `auth-multiuser-inventory-2026-10-19.md`（棚卸し）のもの。

- 読んだもの: 設計・棚卸し・`CLAUDE.md`・`AGENTS.md`・`structural-conventions.md`・`domain-model.md`・`meal-weight-design.md`（本人回答と §2・§4・§6）・migration 0001〜0012・Swift（`LifeTrackerApp`・`SupabaseWorkoutDataSource`・`SupabaseDayDataSource`・`Continuity`・`ContinuityStore`・`StreakWidget`・`Workout.swift`・`SleepRules`・`Info.plist`・entitlements・`Package.resolved`）
- 本番は MCP の読むだけの操作（`list_extensions`・`get_advisors`・`list_migrations`・SELECT）で確かめた。DB・設計・コード・他の docs は変えていない。書いたのはこのファイルだけ
- 凡例: 【事実】ファイル・SQL・公式の文書で確かめたこと ／【推測】見立て。重さ: 高 = 直さないと設計の目的が達せない・本番で壊れる ／ 中 = 実装前に直す ／ 低 = 細部・注記
- 区分: **AI** = AI が直してよい ／ **本人** = 本人の判断が要る
- 秘密の値（キー・URL・メールアドレス・UID）は書いていない

---

## 要約

- **高 2・中 15・低 12**（M1〜M30。M24 は設定の事実の表）
- 骨格は成立する【事実】: 本番は PostgreSQL 17.6。`user_id DEFAULT auth.uid()`・SECURITY INVOKER の関数・`(select auth.uid())` の policy・`UNIQUE (id, user_id)`＋複合 FK の `ON DELETE SET NULL (列)`（PG 15 以上の機能）・`EXCLUDE ... gist`（`btree_gist` 1.7 を入れられる）・view の `security_invoker`（PG 15 以上）は、すべてこの版で動く
- **高の 2 つ**: (M1) 関数の EXECUTE は anon だけでなく **PUBLIC** にも付いているので、anon から外しても呼べたまま。(M3) 全関数に `SET search_path = ''` を付けると、`workout_set_delete`・`workout_entry_reorder` の `SET CONSTRAINTS <制約名>` が検索パスで名前を解けず **実行時に失敗**する（スキーマ名を付ける）
- 手順の要点: `apply_migration` は本番の記録から「1 本の SQL を分割せず 1 文として保存」している（M10）。1 つのトランザクションで流れる見込みは強いが、実装の最初に 1 分の確かめをする。docker で確かめるには `auth` のスタブが要る（M12）。本人の UID を公開 repo の migration に書かない（M11）
- **本人に聞く点は 1 問に減らせる**: 問い B と C を「サインインに使うメールアドレスはどれか（v1 の 2 件のどちらか・Google のアカウントと同じか・Supabase のチームのメンバーか）」の 1 問にまとめる。問い A（種目）と D（新規登録）は AI 既定で進めてよい（§7）
- 不可逆・外へ伝わるもの: v1 のユーザーの削除（M27。付け替え後は CASCADE で記録が消える）、本番 migration（バックアップが前提。M13）、Google Cloud・Supabase ダッシュボードの設定（本人の操作）

---

## 0. 確かめた事実（本番・読み取りのみ）

| 項目 | 事実 |
|---|---|
| Postgres | 17.6（`server_version_num` 170006） |
| 拡張 | `btree_gist` 1.7 は未インストールだが入れられる。`pgcrypto`・`uuid-ossp` は `extensions` スキーマに入っている |
| ロール | `postgres` は superuser ではないが **BYPASSRLS**。`service_role` も BYPASSRLS。`anon`・`authenticated` は無し。21 表と view の所有者は全部 `postgres` → MCP（postgres）は RLS を越えて読み書きできる |
| 表の権限 | 21 表と view: `anon`・`authenticated`・`service_role` に SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER。PUBLIC への付与は無い |
| 関数の権限 | public の 22（＋v1 の 6）は `proacl` に `=X`（**PUBLIC に EXECUTE**）がある。`private` の 6 は PUBLIC 無し（0012 で外した） |
| 既定の権限 | `pg_default_acl` に grantor = `postgres` と grantor = `supabase_admin` の 2 系統。どちらも public の表（全権限）・関数（EXECUTE）・シーケンスを anon・authenticated・service_role に開く |
| auth.users | 2 件。2 件とも確認済みで、2 件ともサインインの記録あり（作成は 2026-04-14 と 04-19）。identities 2（provider は email だけ） |
| `auth.uid()` | STABLE の SQL 関数（`request.jwt.claim.sub` か `request.jwt.claims` の `sub` を読む）。postgres から呼ぶと NULL |
| migration の記録 | `supabase_migrations.schema_migrations` の列は version・statements・name・created_by・idempotency_key・**rollback**。v2 の 12 本とも `statements` の要素数は **1**（0012 は 43,555 文字で 1 要素） |
| advisor | RLS 無効 21（ERROR）・SECURITY DEFINER の view 1（ERROR）・search_path 未設定 28（WARN）・anon が実行できる SECURITY DEFINER 1（WARN）・漏えいパスワード検査 無効（WARN） |

---

## 1. 正しさ（RLS・権限・Postgres の機能）

### M1（高・AI）anon から EXECUTE を外しても、PUBLIC の EXECUTE が残る
- 場所: 設計 §4（L70）「anon から EXECUTE を外し、authenticated にだけ与える」、§5（L76）
- 問題【事実】: 本番の public の関数は `proacl` が `{=X/postgres, anon=X, authenticated=X, service_role=X}`。先頭の `=X` は PUBLIC（全ロール）への EXECUTE で、Postgres が関数を作ったときに自動で付く。`REVOKE ... FROM anon` だけでは anon は PUBLIC 経由で呼べたまま。RLS と `user_id NOT NULL` のおかげでデータは漏れない（`todo_fetch` は空の配列、INSERT は NOT NULL で失敗）が、「anon から呼べない」という設計の目的は達せず、確かめの「anon では 0 行」も通ってしまう
- 直し方: 公開の関数は `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon;` にする。既定の権限も `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;`（Supabase の文書も `revoke execute on functions from public` を含めている）。`private` スキーマは `REVOKE USAGE ON SCHEMA private FROM anon`。本番適用の確かめに `has_function_privilege('anon', 'public.todo_fetch(date,date,date)', 'EXECUTE')` = false を足す
- 出典: https://supabase.com/docs/guides/database/hardening-data-api

### M2（低・AI）既定の権限は「誰が作った物に効くか」で 2 系統ある
- 場所: 設計 §5（L77）
- 問題【事実】: `pg_default_acl` は grantor ごと。MCP とダッシュボードの SQL は `postgres` で動くので、効くのは `FOR ROLE postgres` の行。`supabase_admin` の行は postgres からは変えられない（その行は Supabase 側が作る物にだけ効く）
- 直し方: `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ...` を表・関数・シーケンスの 3 つに書く（省くと「今のロール」= postgres に効くので同じ結果だが、明示する）。確かめは `SELECT defaclrole::regrole, defaclobjtype, defaclacl FROM pg_default_acl WHERE defaclnamespace = 'public'::regnamespace` に anon が無いこと
- 出典: 同上

### M3（高・AI）`SET search_path = ''` を付けると `SET CONSTRAINTS` が制約名を解けない
- 場所: 設計 §4（L69）「全部の関数に `SET search_path = ''` を付け、中の表は `public.` で書く」。対象は 0010 の `workout_set_delete`（`SET CONSTRAINTS workout_set_entry_id_set_index_key, workout_entry_session_id_sort_order_key DEFERRED`）と `workout_entry_reorder`
- 問題【事実】: `SET CONSTRAINTS` の制約名は「スキーマ名を付けなければ検索パスで最初に見つかった物」を使う（PostgreSQL の文書）。検索パスが空だと見つからず、✓ の取り消し・セットの削除・並べ替えが実行時に失敗する。表名を `public.` にしても制約名は別
- 直し方: `SET CONSTRAINTS public.workout_set_entry_id_set_index_key, public.workout_entry_session_id_sort_order_key DEFERRED` と書く（スキーマ付きの名前は許される）。あわせて、関数の中の `jst_today()`・`schedule_assert_editable()`・`schedule_holiday_pattern_id()`・`schedule_single_delete()` などの関数呼び出しも `public.` を付ける（`private.` は付いている）。`ALTER FUNCTION ... SET search_path = ''` だけを付けて本文を直さないと、全関数が「relation does not exist」で壊れるので、必ず本文の書き直しと同時に行う。docker の確かめにセットの削除と並べ替えを含める
- 出典: https://www.postgresql.org/docs/17/sql-set-constraints.html

### M4（中・AI）付け替えの UPDATE から `exercise` を外す。policy は読みと書きで分ける
- 場所: 設計 §6（L83）「全行を本人の UID で UPDATE」、§3 案 1、§5（L75）
- 問題【推測】: 「全行」のまま流すと seed の 159 件も本人の物になり、案 1（共有 = `user_id IS NULL`）が壊れる。棚卸しで 159 件がすべて seed の名前と一致しているので、`exercise` は 1 行も付け替えない（本人の自作が 0 件）。本人の行は 365 − 159 = 206 行
- 直し方: `exercise` は UPDATE の対象から外し、`SET NOT NULL` もしない（`user_id` は NULL 可のまま。既定値 `auth.uid()` は付ける＝アプリや本人が将来作る自作は本人の物になる）。policy は `FOR SELECT USING (user_id IS NULL OR user_id = (select auth.uid()))` と、`FOR INSERT WITH CHECK (user_id = (select auth.uid()))`・`FOR UPDATE USING (...) WITH CHECK (...)`・`FOR DELETE USING (...)` に分ける（`FOR ALL` 1 つだと共有の行が読めない）。共有の行は API からはだれも書けず、MCP（postgres）だけが書ける＝設計どおり
- 出典: https://www.postgresql.org/docs/17/sql-createpolicy.html

### M5（低・AI）0004 の `ON CONFLICT (name) DO NOTHING` は部分 UNIQUE では効かなくなる
- 場所: 0004:9・設計 §3「名前の一意は 2 つの部分 UNIQUE」
- 問題【事実】: `exercise_name_unique` を `WHERE user_id IS NULL` の部分索引に替えると、`ON CONFLICT (name)` は推論に合う索引が無くなり失敗する。0004 は本番ではもう適用済みなので本番は影響なし。0001 から順に流す docker の確かめでは 0004 が先に走るので通る
- 直し方: これから書く種目の seed（画像の追加など）は `ON CONFLICT (name) WHERE user_id IS NULL DO NOTHING` にする。設計 §3 に 1 行足す

### M6（低・AI）`user_id` を足す順は設計どおり。理由を注記する
- 場所: 設計 §6（L83）「NULL 可で足す → UPDATE → NOT NULL・既定値」
- 【事実】`ADD COLUMN ... DEFAULT <不変の式>` は ALTER の時点で 1 回だけ評価した値を既存の行に入れる。`auth.uid()` は postgres から呼ぶと NULL なので、`ADD COLUMN user_id uuid NOT NULL DEFAULT auth.uid()` と 1 行で書くと既存の行が NOT NULL で失敗する。設計の順（NULL 可 → UPDATE → NOT NULL → DEFAULT）で正しい。実装計画にこの理由を書いて、近道をしないようにする
- 出典: https://www.postgresql.org/docs/17/sql-altertable.html

### M7（低・AI）「anon では 0 行」の期待値は、権限を外すと「権限エラー（42501）」になる
- 場所: 設計 §5（L78）・§11-3（L125）
- 【事実】RLS を有効にして policy が無い／合わないときに 0 行になるのは **権限を持つロール**（authenticated）。anon から表の権限を外すと PostgREST は 42501（permission denied）を返す。期待値は「anon = 権限エラー ／ テスト用の 2 人目 = 0 行 ／ 本人 = 全部」に直す。アプリ側の A5 の文言（42501 →「サインインし直してください」）とも整合する

### M8（低・AI）`fetchTaps` の握りつぶしは、RLS の付け忘れと権限エラーを隠す
- 場所: `SupabaseDayDataSource.swift:136-147`（失敗したら空）
- 直し方: 少なくとも `PostgrestError` の 42501 と PGRST3xx（JWT 系）は握りつぶさず上に投げる（他は今のまま空でよい）。「空の画面」で気づけない問題を 1 つ減らす

### M9（中・AI）`ensure_user_defaults()` は「1 件ずつ」の砦と一緒に作る
- 場所: 設計 §3（L62）・棚卸し F1・F2
- 問題【推測】: 関数は何度呼んでも同じ結果にする設計だが、アプリの起動が重なって同時に 2 回呼ばれると、`WHERE NOT EXISTS` だけでは 2 件入りうる。今はジム・睡眠の種類が「1 件ずつ」である前提をアプリが持つ（`CheckIn.swift`・`SleepStore.swift`）のに、DB に砦が無い
- 直し方: `category` に `CREATE UNIQUE INDEX category_user_kind_unique ON category (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL`（本番は gym 1・sleep 1 なので今から付けられる）。`pattern` は D8 の `(user_id, apply_day) WHERE apply_day IS NOT NULL`。関数の INSERT は `ON CONFLICT DO NOTHING`（部分索引を対象にするときは `ON CONFLICT (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL DO NOTHING` と WHERE まで書く）。代案の「`auth.users` の AFTER INSERT トリガーで作る」（Supabase の文書の形）は、ダッシュボードで作ったユーザーにも効く利点があるが、「トリガーが失敗するとサインアップ自体が止まる」と文書に注意がある。アプリから呼ぶ RPC の案のままでよい（AI 既定）
- 出典: https://supabase.com/docs/guides/auth/managing-user-data

### 確かめて問題なしだったもの【事実】
- `ON DELETE SET NULL (template_id)` の列指定: PG 15 以上の機能で、`ON DELETE` にだけ使える（`ON UPDATE` には不可）。設計の使い方は `ON DELETE` だけなので可。`user_id` は残り、`template_id` が NULL になると MATCH SIMPLE の FK は検査されない（意図どおり）。出典: https://www.postgresql.org/docs/17/sql-createtable.html
- `EXCLUDE USING gist (user_id WITH =, tstzrange(...) WITH &&)`: `btree_gist` は uuid に対応。`CREATE EXTENSION btree_gist WITH SCHEMA extensions` でよい（0001 の pgcrypto と同じ置き場）。出典: https://www.postgresql.org/docs/17/btree-gist.html
- view の `security_invoker = true`: 下の表の権限と RLS を「呼んだ人」で検査する。`ALTER VIEW public.workout_training_day SET (security_invoker = true)` だけで済む。出典: https://www.postgresql.org/docs/17/sql-createview.html
- 関数の中の `INSERT ... ON CONFLICT DO UPDATE` と RLS: 衝突した既存の行が USING に合わないと **エラー**になる（黙って飛ばさない）。衝突キーは親の UUID を含むので、RLS が効けば本人の行としか衝突しない。他人のキーと当たったときにエラーになるのは、むしろ守りとして正しい。出典: https://www.postgresql.org/docs/17/sql-createpolicy.html
- 遅延の制約（`DEFERRABLE`）: RLS と無関係。M3 の名前の問題だけ
- `DEFAULT auth.uid()` と PostgREST の upsert: アプリが `user_id` を送らなくても、`INSERT` の既定値で入り、`ON CONFLICT (user_id, recorded_on)` は表の列で推論するので動く（`onConflict: "user_id,recorded_on"` の書き方は PostgREST の `on_conflict` に合う）
- RLS を有効にして policy が無い表は「全部拒否」（本人も 0 行）。設計の「付け忘れは空の画面」は正しい。出典: https://supabase.com/docs/guides/database/postgres/row-level-security
- policy の `(select auth.uid())`・`user_id` の索引・`TO authenticated` は Supabase の推奨どおり（同上）

---

## 2. migration の手順

### M10（中・AI）`apply_migration` のトランザクション: 証拠は「1 文で保存」。実装の最初に 1 分で確かめる
- 場所: 設計 §6（L83）「`apply_migration` が 1 つのトランザクションで流れるかは未確認」。0007:8 の注記
- 【事実】
  - MCP の `apply_migration` は Management API の `POST /v1/projects/{ref}/database/migrations` に SQL を **そのまま**送る（BEGIN/COMMIT を足さない）。API の文書は body（`query`・`name`・`rollback`）だけで、トランザクションの説明は無い
  - 本番の `schema_migrations.statements` は v2 の 12 本とも **1 要素**（0012 は 43,555 文字で 1 要素）= サーバーは SQL を文ごとに分けていない
  - PostgreSQL の決まり: 1 つの Query メッセージに複数の文が入っていると、明示の BEGIN/COMMIT が無ければ **全体が 1 つのトランザクション**になり、最初のエラーで前の文も戻る
- 【推測】サーバーが 1 文として受けた SQL を 1 回で送っているなら、設計どおり「途中で失敗したら全部戻る」。ただし送り方は閉じた実装で見えない
- 直し方（確かめ方）: 実装の最初に、害の無い migration を 1 本流す: `CREATE TABLE public._txn_probe (x int); SELECT 1/0;`（名前は `probe_txn`）。失敗したあと `SELECT to_regclass('public._txn_probe')` が NULL なら 1 トランザクション。あわせて `list_migrations` に失敗した版が記録されるかも分かる（記録されるなら、失敗した migration が履歴に残ることを運用の注意に書く）。NULL でなければ `DROP TABLE` が要る（下の確認画面）。結果を 0007 の注記の代わりに `docs` に 1 行書く。本文に `BEGIN;`/`COMMIT;` を書くのは、どちらの場合でも害が無い（サーバーが包んでいれば WARNING だけ）が、確かめた後なら不要
- 運用の注意【事実・memory `reference_supabase_accounts`】: この migration は DROP（旧 FK・索引・制約・`user_profile.id`・v1 の関数）を多く含む。MCP は DROP を含む文で確認の要求を出し、すぐ承認しないと `cancelled` で何も実行されない。流す前に本人へ「確認の画面が出たらすぐ承認して」と伝える。`cancelled` の後は読み取りで「何も変わっていない」を確かめる
- 出典: https://www.postgresql.org/docs/17/protocol-flow.html ／ https://supabase.com/docs/reference/api/v1-apply-a-migration ／ https://github.com/supabase-community/supabase-mcp （`packages/mcp-server-supabase/src/platform/api-platform.ts`）

### M11（中・AI）本人の UID を公開 repo の migration に書かない
- 場所: 設計 §6（L82-83）「全行を本人の UID で UPDATE」
- 問題【推測】: UID だけでデータは読めないが、`CLAUDE.md` は Bundle ID や App Group の ID も書かない方針。公開 repo の migration に `UPDATE ... SET user_id = '<uuid>'` を残すのは方針に合わない。メールアドレスで引く（`SELECT id FROM auth.users WHERE email = ...`）のはさらに悪い
- 直し方: migration ファイルには置き換え印（例 `'__OWNER_UID__'`）を書き、流すときに置き換えた SQL を MCP に渡す。先頭に `DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '__OWNER_UID__') THEN RAISE EXCEPTION 'owner uid not found'; END IF; END $$;` を置いて、置き換え忘れ・取り違えを UPDATE の前に止める。UID 本体は vault の memory（`project_life_tracker_auth_multiuser`）に書く。付け替えの SQL は `UPDATE <表> SET user_id = '__OWNER_UID__' WHERE user_id IS NULL` を `exercise` 以外の全表に（M4）

### M12（中・AI）docker の確かめには `auth` のスタブが要る
- 場所: 設計 §9（L108）「docker の Postgres で migration を流して 2 人のテスト用ユーザーで…」
- 問題【事実】: 素の `postgres:17` には `auth.users`・`auth.uid()`・ロール `anon`/`authenticated`/`service_role` が無い。新しい migration はこの 3 つを参照するので、今までの流し方では最初の `REFERENCES auth.users(id)` で止まる
- 直し方: `supabase/test/auth_stub.sql`（migration ではない置き場）を作る: `CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS; CREATE SCHEMA auth; CREATE TABLE auth.users (id uuid PRIMARY KEY); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;`（本番の定義を写した形）。`extensions` スキーマも作る（0001 が使う）。確かめは `SET ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"<uuid A>"}', true);` で A になり、B に切り替えて 0 行、`SET ROLE anon` で 42501 を見る。ユーザーは `INSERT INTO auth.users VALUES (gen_random_uuid())` で 2 件。RLS の付け忘れは `SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND NOT relrowsecurity`（0 行）と `SELECT tablename FROM pg_tables WHERE schemaname = 'public' EXCEPT SELECT tablename FROM pg_policies`（0 行）で機械的に見る
- 【推測】`supabase start`（CLI・本物の auth 付き）の方が忠実だが、repo は CLI を使わない方針（0001 の注記）なので、スタブで足りる

### M13（中・本人の操作を含む）バックアップ: 自動バックアップは無い見込み。pg_dump の版と、復元をリハーサルに使う
- 場所: 設計 §6（L83）「本番のバックアップ（`pg_dump` の写し・repo の外）」
- 【事実】Supabase の日次バックアップは Pro 以上。Free には無く「定期的に書き出す」ことが推奨されている（プランは今回確かめていない【推測: HIBP 無効・標準メールのままなので Free の可能性が高い】）
- 直し方: (1) `pg_dump` はサーバーの版（17）以上のクライアントを使う（Homebrew の `libpq` か `postgresql@17`）。接続先はダッシュボードの接続文字列（セッションプーラー）。パスワードは repo に置かない。(2) 取った dump を docker（M12 のスタブ入り）に復元し、その上で migration を流す＝**本物のデータでのリハーサル**になり、dump が復元できることの確かめにもなる。(3) 戻すときは「このリハーサルで通った手順」で戻す
- 出典: https://supabase.com/docs/guides/platform/backups

### M14（低・AI）0013（旧列と `pattern_template_membership` の削除）を先に流す
- 場所: 設計 §11-1（L123）「0013 は旧列の削除に予約済み」
- 【推測】消す予定の表に `user_id`・RLS・policy を付けるのは無駄で、戻しの migration も増える。0006（9/30 適用）以降の新ビルドで読み書きが確かめられているなら、0013 を先に適用してから複数人化（0014）にする。食事は 0015 以降。0013 は DROP を含むので M10 の確認画面の注意が要る

### M15（低・AI）戻しの migration の限界と置き場
- 場所: 設計 §6（L84）
- 【推測】逆の migration は「本人 1 人しかデータが無いうち」だけ安全（2 人目が記録した後に `user_id` を消すと混ざる）。これを戻しのファイルの先頭に注記する。置き場は `supabase/migrations/` の外（例 `supabase/rollback/0014_down.sql`）にして、番号付きの前進用と見間違えない名前にする。`schema_migrations` に `rollback` 列があり、Management API は `rollback` の SQL を受けるが、MCP の `apply_migration` にはその引き数が無いので使わない

---

## 3. 種目（共有のマスタ＋人ごとの設定）

### M16（中・AI）人ごとの設定は view で今の列の形を保つ。アプリの変更は表名の 1 か所
- 場所: 設計 §3 案 1（L61）「`is_archived`・`note`・`sort_order` を人ごとの表 `exercise_preference` に移す」。アプリは `SupabaseWorkoutDataSource.swift:12-18`（`exercise` を `is_archived = false` で絞り `sort_order`・`name` で並べる）、`Workout.swift:6-14`（`Exercise` が `isArchived`・`sortOrder`・`note` を持つ）
- 問題【推測】: 3 列を別表に移すと、アプリ側は 2 表を読んで結合する変更（`Exercise` の形・`MockWorkoutDataSource`・`WorkoutFixtures`・テスト）になる。`sort_order` は seed が部位ごとに振った **マスタの並び**（100 番台）で、人の好みではない
- 直し方（案 1 の細部）: (1) `exercise.sort_order` はマスタの既定値として残す。`is_archived`・`note` は `exercise_preference (user_id, exercise_id, is_archived, note, sort_order)` に移し、`exercise` から消す（本番は全部 false／NULL なので移すデータは無い）。(2) view `exercise_for_user`（`security_invoker = true`）を `SELECT e.id, e.name, e.muscle_group, e.equipment, e.metric_kind, p.note, COALESCE(p.is_archived, false) AS is_archived, COALESCE(p.sort_order, e.sort_order) AS sort_order FROM public.exercise e LEFT JOIN public.exercise_preference p ON p.exercise_id = e.id` で作る（`exercise_preference` の RLS で本人の設定だけが結合される）。(3) アプリは `from("exercise")` を `from("exercise_for_user")` に変えるだけ。`Exercise` の形・画像（`ExerciseImageNames.byName`）・強さの基準（`StrengthStandards.swift:83`。名前で引く）はそのまま。(4) `exercise_muscle_group_idx`（`WHERE is_archived = false`）は条件なしで作り直す。(5) アーカイブ・メモの書き込みは当面 MCP（`exercise_preference` に `user_id` を明示。M25）。アプリの画面で変える日が来たら `exercise_preference` に upsert（`onConflict: "user_id,exercise_id"`）
- 案 2（人ごとに 159 件を写す）を採らない理由はそのまま妥当: 画像と基準は名前で引くので共有のままで困らない。写すと種目を増やすたびに全員へ配り直す

### M17（低・AI）名前の重なりと、FK が RLS を越える点を設計に明記
- 【事実】部分 UNIQUE を 2 つにすると、本人が共有と同じ名前（例「ベンチプレス」）の自作を作れる。選択の一覧に 2 つ並び、名前で引く画像と基準は両方に当たる。防ぐには trigger が要るので、今は「作らない」運用で足りる（低）。FK の検査は RLS を越えるので、他人の自作の UUID を知っていれば `routine_exercise`・`workout_entry` から参照できる。UUID は推測できないので受け入れる、と設計 §1（L39）にある。これで妥当。`exercise` 以外の子の FK は `(親 id, user_id)` の組にするので、他人の行の存在を FK のエラーで探ることもできない

---

## 4. サインインのアプリ側

### M18（中・AI）確認メール・再設定のリンクは「サインアップした iPhone で開く」。6 桁コードの代案を持つ
- 場所: 設計 §7（L89）「リンクはアプリの URL スキームに戻る」
- 【事実】設計は PKCE で進める（supabase-swift 2.x は `flowType` を省くと PKCE。M23 で明示する）。PKCE の code verifier は「フローを始めた端末に保存され、コードの交換は同じブラウザ・端末で始めなければならない」（Supabase の文書）。つまり iPhone でサインアップし、Mac のメールでリンクを踏むと失敗する（リンクは使い切り）。メールのセキュリティスキャナがリンクを先読みして消費する問題も文書にある
- 直し方: AI 既定は PKCE＋リンクのまま（実装は `onOpenURL { url in supabase.auth.handle(url) }`。カスタムスキームは他のアプリも同じ名前を名乗れるが、PKCE なら横取りされた `code` は verifier が無いと使えない＝implicit より安全）。サインアップ後の画面に「このメールを **この iPhone** で開いてください」と出す。代案: メールの型を `{{ .Token }}`（6 桁）にしてアプリで `verifyOTP(email:token:type:)` を呼ぶと、確認も再設定も URL スキームに依らなくなる（型の変更と入力欄だけ・後から切り替えられる）。本人が「リンクを踏む」と言っているので、まず文書どおりリンクで作り、困ったらコードに替える
- 【推測】iOS のメールからリンクを踏むと Safari が `https://<project>/auth/v1/verify?...` を開き、サーバーが `lifetracker://auth-callback?code=...` に転送し、「LifeTracker で開く」の確認が出てアプリに戻る。実機で 1 回確かめる。シミュレータでは `curl -I` で転送先の URL を取り、`xcrun simctl openurl booted '<転送先>'` で代用できる
- 出典: https://supabase.com/docs/guides/auth/sessions/pkce-flow ／ https://supabase.com/docs/guides/auth/native-mobile-deep-linking ／ https://supabase.com/docs/guides/auth/auth-email-templates

### M19（中・本人の操作を含む）Google: iOS のクライアント ID だけでなく **Web のクライアント ID** も要る。nonce は渡さない
- 場所: 設計 §7（L90）「Google Cloud で iOS 用の OAuth クライアントを作る」、§8（L101）
- 【事実】Supabase の iOS（Swift）向け手順: Google Cloud で **iOS 用と Web 用** の 2 つのクライアント ID を作り、ダッシュボードの Google provider の「Client IDs」に 2 つをコンマ区切りで入れ、**「Skip nonce check」を有効**にする。Swift の例は `GIDSignIn.sharedInstance.signIn(withPresenting:)` → `result.user.idToken?.tokenString` と `accessToken.tokenString` → `signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .google, idToken:, accessToken:))` で、nonce を渡していない。GoogleSignIn-iOS の `GIDSignIn.signIn` に nonce の引き数は無い（API リファレンス）。supabase-swift 2.44.1 の `OpenIDConnectCredentials` は `provider / idToken / accessToken? / nonce?`
- 直し方: 設計 §8 に「Web クライアント ID も作る」「Skip nonce check を有効」「`Info.plist` に `GIDClientID` と、逆順クライアント ID（`com.googleusercontent.apps.…`）の URL スキームを足す（`lifetracker://` と合わせて `CFBundleURLTypes` は 2 つ）」を足す。nonce は Google SDK に渡す口が無いので `signInWithIdToken` にも渡さず、Supabase 側で検査を飛ばす（文書の手順。同じ文書に「クライアントの部品が nonce を扱えないときだけ無効にする」とある＝この場合）。Google Cloud の OAuth 同意画面は「テスト」のままでよい（本人のアカウントをテストユーザーに入れる）【推測】
- 出典: https://supabase.com/docs/guides/auth/social-login/auth-google?queryGroups=platform&platform=ios ／ https://developers.google.com/identity/sign-in/ios/start-integrating ／ https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDSignIn ／ https://github.com/supabase/supabase-swift （`Sources/Auth/Types.swift`）

### M20（中・AI）セッションが無いと、同じクライアントは anon キーで送る → データの呼び出しは 42501 になる
- 場所: 設計 §7（L91）「data source は今の共有のクライアントを使い続ける」「A5・A6」
- 【事実】supabase-swift の `SupabaseClient` は PostgREST などの各リクエストで `auth.session.accessToken` を付け、セッションが無い（`sessionMissing`）ときは **anon キーに落ちる**。つまり、サインインの画面を出す判定が遅れて store が先に読みに行くと、全部 42501 で失敗する。トークンの自動更新は既定で有効。`.signedOut` はサインアウトのほか「別の端末でのサインアウト・セッションの期限」でも届く（文書）
- 直し方: `AuthStore` が `authStateChanges` の `.initialSession` を受けてから TabView を出す（それまでは起動画面）。データの読み込みはセッションがある状態でだけ始める。42501 の文言「サインインし直してください」は保険として残す。オフラインでの更新失敗はサインアウトにしない（`.signedOut` が来たときだけサインインの画面へ）。`AuthStore` は `authStateChanges` を 1 本だけ購読し、`.passwordRecovery` では新しいパスワードの画面を出す
- 出典: https://github.com/supabase/supabase-swift （`Sources/Supabase/SupabaseClient.swift` の `accessTokenProvider`）／ https://supabase.com/docs/reference/swift/auth-onauthstatechange

### M21（低・AI）サインアウトの細部
- 場所: 設計 §7（L92）・§2 A3・棚卸し A4
- 【事実】`signOut()` は **先に端末のセッションを消して `.signedOut` を流し、その後 `/logout` を呼ぶ**。サーバー側の失敗のうち 401/403/404 と sessionMissing は握りつぶすが、ネットワークの失敗は投げる → 端末側はもう消えているので、UI はエラーでも「サインアウト済み」として扱う
- 直し方: (1) store の作り直しは、TabView に `.id(session.user.id)` を付けて人が変わったら SwiftUI に作り直させる（`@StateObject` は `WorkoutView.swift:6-13`・`HomeView.swift:16`・`SleepView.swift:8` にある。手で消す処理を書くより漏れが無い）。(2) App Group は `continuity.v1` を消す（`removeObject`）＋ `WidgetCenter.shared.reloadAllTimelines()`。(3) ウィジェットは「スナップショット無し」を今は「アプリで週の目標回数を設定」と表示している（`StreakWidget.swift:60-66`）ので、「未サインイン」を区別する印（`Snapshot` に `isSignedIn` を足すか、別キー）が要る。(4) 休憩の Live Activity が動いていれば終える。(5) サインアウトの置き場（分析画面のプロフィール）は AI 既定でよい

### M22（中・AI）テストが本番につながない形: TEST_HOST と Keychain のセッション
- 場所: 設計 §9（L106）・棚卸し §2-5
- 【事実】単体テストの TEST_HOST はアプリ本体（project.pbxproj:648）。UI テストは引き数なしで起動（`LifeTrackerUITests.swift:29,38`）。共有の scheme は repo に無い（`xcshareddata/xcschemes` が無い）ので、起動の引き数は Xcode の個人設定かコードで渡すしかない
- 問題【推測】: サインイン後はセッションが Keychain に残る。シミュレータで本人がサインインしたまま単体テストを走らせると、TEST_HOST のアプリが起動時に本物のセッションで本番を読みに行く。今まで（anon で読む）と同じ問題が形を変えて残る
- 直し方: `LifeTrackerApp.makeDataSource()` で、テストの環境変数（`XCTestConfigurationFilePath` か `XCTestBundlePath`）があるなら、`#if DEBUG` でメモリ上の data source と「サインイン済み扱い」（`-mock-auth`）にして Supabase クライアントを作らない。UI テストはコードで `app.launchArguments = ["-mock-day", "-mock-workout", "-mock-auth"]` を渡す。`-mock-auth` はサインインの画面を飛ばす起動引き数（DEBUG だけ）。これで「テストは本番に一切つながない」が機械的に保てる

### M23（低・AI）URL スキーム・再設定・再送の細部
- 【事実】`Info.plist` に `CFBundleURLTypes` は無い（棚卸し）。再設定は `resetPasswordForEmail(email, redirectTo:)` → リンク → アプリ → `.passwordRecovery` → `auth.update(user: UserAttributes(password:))`。確認メールの再送は `auth.resend(email:type:)`。レート制限はサインアップ・再送・回復が IP ごとに 30 回/5 分、同じ人への OTP は 60 秒に 1 回、標準のメール送信は 1 時間 2 通
- 直し方: `SupabaseClientOptions.auth` に `redirectToURL: URL("lifetracker://auth-callback")` と `flowType: .pkce` を明示する。「確認待ち」の画面は、サインアップしたメールアドレスを保ち、再送ボタンに 60 秒の待ちを出す。サインアップで既存のメールアドレスを入れたときの応答は「存在を隠す」形なので（文書）、画面は常に「確認メールを送りました」と出す
- 出典: https://supabase.com/docs/guides/auth/passwords ／ https://supabase.com/docs/guides/auth/rate-limits ／ https://supabase.com/docs/reference/javascript/auth-signup

---

## 5. Supabase の設定の事実

### M24（情報・設計 §8 の【事実は実装の前に確かめる】への答え）

| 設定 | 事実（公式の文書） | 設計への影響 | 出典 |
|---|---|---|---|
| パスワードの最低の長さ・文字種 | 設定できる。「8 文字未満は推奨しない」「数字・大小の英字・記号を要求する最も強い選択肢を推奨」。**プランの制限は書かれていない** | 12 文字・英字と数字は設定できる見込み。既存の v1 ユーザーの古いパスワードには効かない（次に変えるとき） | https://supabase.com/docs/guides/auth/password-security |
| 漏えいしたパスワードの検査（HIBP） | 「**Pro Plan and above**」 | 設計どおり使わない（advisor の WARN は残る） | 同上 |
| 標準のメール送信 | 「プロジェクトのチームに属さないアドレスには配信を拒否」「**1 時間 2 通**（予告なく変わる）」「SLA 無し。探索・テンプレートの試験・デモ用。他のすべての用途で custom SMTP を強く勧める」 | 本人のサインインのアドレスがチームのメンバーでなければ、確認メールが届かない（問い B＋C）。テスト中は 2 通/時に当たるので、テスト用ユーザーはダッシュボードの「Add user（自動確認）」で作る | https://supabase.com/docs/guides/auth/auth-smtp |
| Auth のレート制限 | メール 2 通/時（標準）。`/verify` 30 回/5 分、サインアップ・再送・回復 30 回/5 分（IP ごと）、トークン更新 150 回/5 分、同じ人への OTP・マジックリンクは 60 秒に 1 回 | 実機の確かめの回数を見積もる | https://supabase.com/docs/guides/auth/rate-limits |
| 戻り先 URL の許可 | 「Additional Redirect URLs」に `[スキーム]://[ホスト]` を入れる。ワイルドカード可。`redirectTo` 無しのときは Site URL（既定 localhost:3000）へ | `lifetracker://auth-callback` を入れる。Site URL は変えなくてよいが、`redirectTo` を必ず渡す | https://supabase.com/docs/guides/auth/redirect-urls ／ https://supabase.com/docs/guides/auth/native-mobile-deep-linking |
| Google provider | Client IDs に **iOS と Web の 2 つ**。Skip nonce check を有効 | M19 | https://supabase.com/docs/guides/auth/social-login/auth-google?queryGroups=platform&platform=ios |
| 同じメールアドレスの自動連携 | 「同じメールアドレスの identity を 1 人のユーザーに自動で連携」。未確認のメールアドレスには連携しない（乗っ取り防止） | 本人のメールアドレスと Google のアドレスが同じなら 1 人にまとまる。違えば別のユーザー（空のデータ）になる → 問い B＋C | https://supabase.com/docs/guides/auth/auth-identity-linking |
| 手動の連携 | 設定で有効にできる。**既定の状態は文書に書かれていない**【設計の「既定で無効」は本人のダッシュボードで確かめる】 | 無効のまま | 同上 |
| 新規登録 | 「無効にすると既存のユーザーだけがサインインできる」。OAuth への影響は書かれていない【推測: 新しい Google アカウントの初回サインインも止まる】 | 問い D（§7 で AI 既定に） | https://supabase.com/docs/guides/auth/general-configuration |
| メールの確認 | 「有効にすると初回のサインインの前にメールアドレスの確認が要る」。provider の設定の中にある | 本人の指示どおり有効 | 同上 |
| 6 桁コード | テンプレートで `{{ .Token }}` を使える。リンクの先読みで消費される問題の回避策として文書にある | M18 の代案 | https://supabase.com/docs/guides/auth/auth-email-templates |
| バックアップ | 日次バックアップは Pro 以上。Free は定期的な書き出しを推奨 | M13 | https://supabase.com/docs/guides/platform/backups |

設計の前提（L18-20）のうち、今回確かめていないもの: Sign in with Apple・パスキーが有料の Program を要すること（Apple の対応表はテキストで取れず未確認）、手動連携の乗っ取りの報告（未確認。無効のままなら影響なし）。

---

## 6. 抜けている論点

### M25（中・AI）MCP で直接入れる運用は「使えなくなる」のではなく「`user_id` を明示する」に変わる
- 場所: 設計 §1（L38）「MCP から入れると `auth.uid()` が NULL になり NOT NULL で失敗する」、棚卸し §3-1 R-3（種目の自作・過去日の記録を MCP で INSERT）
- 【事実】MCP は postgres（BYPASSRLS・表の所有者）なので RLS を越えて書ける。既定値だけが NULL になる
- 直し方: 運用の手順を `docs`（`gymwork-alignment-design.md` R-3 の周り）に書き換える: 「MCP の INSERT は `user_id` を明示する（UID は memory）。子の表は複合 FK が持ち主の不一致を止める」。種目の自作は `exercise (user_id = 本人)`、アーカイブ・メモは `exercise_preference`。アプリから自作できるようにするかは今回の範囲外

### M26（中・AI）食事の設計 §2 への波及を具体に書く
- 場所: 設計 §9（L110）「`meal-weight-design.md` の user_id の記述」、`meal-weight-design.md:242`
- 【事実】食事の §2 には 1 人前提の形が残っている: `nutrition_settings`（`id = 1` の CHECK・D1 と同じ）、`meal_day_status`（`day` が主キー・D3 と同じ）、`body_fat_estimate`（`recorded_on` が主キー・D2）、`nutrition_goal`（`effective_from` が UNIQUE・D4）、`ai_usage`（`(day, kind)` が主キー）、`food_item`（店の行は共有・自分の行は人ごと＝種目の案 1 と同じ形。`UNIQUE (source, brand, name, variant)` と `jan_code` の部分 UNIQUE は自分の行に `user_id` を含める）。AI の Edge Function は JWT（`Authorization: Bearer`）で人を特定し、`ai_usage` を人ごとに数える。「合言葉のヘッダー」は JWT で代替できる
- 直し方: この一覧を `meal-weight-design.md` §2 の冒頭に注記として足し、:242 を「10-19 の決定で上書き」と直す（食事の実装前に書き直す）

### M27（中・本人）v1 のユーザーの削除は、付け替えの後は CASCADE で記録ごと消える
- 場所: 設計 問い B「使わない v1 のユーザーを消すか」
- 【事実】`user_id ... REFERENCES auth.users(id) ON DELETE CASCADE` なので、付け替えた側のユーザーを誤って消すと 206 行が消える。auth.users の 2 件は、2 件とも確認済みで 2 件ともサインインの記録がある（04-14・04-19）
- 直し方: 消さない。使わない方は **テスト用の 2 人目**として使う（ダッシュボードでパスワードを設定）。設計 §9 の「2 人のテスト用ユーザー」もこれで済む。消すのは複数人化が落ち着いた後、`SELECT count(*) ... WHERE user_id = <消す側>` が全表で 0 を確かめてから。問い B から「消すか」を外す

### M28（中・AI）本番適用の確かめを SQL の一覧にする
- 場所: 設計 §5（L78）・§9・§11-3
- 直し方: 適用後に MCP で読むだけの確かめを 1 セットにして実装計画に書く:
  1. RLS: `SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND NOT relrowsecurity` → 0 行。`SELECT tablename FROM pg_tables WHERE schemaname = 'public' EXCEPT SELECT DISTINCT tablename FROM pg_policies` → 0 行
  2. 権限: 全表・view で `has_table_privilege('anon', ..., 'SELECT')` = false、`authenticated` は SELECT/INSERT/UPDATE/DELETE = true・TRUNCATE = false。全関数で `has_function_privilege('anon', ..., 'EXECUTE')` = false（PUBLIC 経由も含めて判定される）。`pg_default_acl` に anon が無い
  3. 形: `user_id IS NULL` の件数が `exercise` 以外で 0。`workout_training_day` の `reloptions` に `security_invoker=true`。`pg_extension` に `btree_gist`。関数の `proconfig` が全部 `search_path=`。同名の関数の重なり 0（0012 の確かめと同じ）
  4. advisor（security）: RLS の ERROR 0・view の ERROR 0・search_path の WARN 0・SECURITY DEFINER の WARN 0（v1 の 6 関数を消した後）
  5. アプリ: 本人でサインインして全タブ・ウィジェット。テスト用の 2 人目で全タブが空。anon の `curl`（`apikey` だけ）で 401/403（42501）
- 【事実】RLS を有効にしても MCP（postgres）には効かないので、確かめの SELECT は今までどおり全行が見える。「MCP で見えるから RLS が効いていない」と誤解しないよう注記する

### M29（低・情報）将来、App Store で配るときは Sign in with Apple が要る
- 【事実】App Store Review Guideline 4.8: 第三者のログイン（Google Sign-In を名指し）で主要なアカウントを作るアプリは、同等のログイン（名前とメールだけ・メールを隠せる・広告目的で収集しない）も提供しなければならない。Program に入って配る段階で Sign in with Apple を足す。設計 §10 に 1 行
- 出典: https://developer.apple.com/app-store/review/guidelines/#login-services

### M30（低・AI）複合 FK に書き換える外部キーの一覧（作業量の見積もり）
- 【事実】本番の FK（`pg_constraint`）のうち、`exercise` を指す 3 つ（`routine_exercise`・`workout_entry`・`workout_set`）と `workout_set_entry_fk`（`(entry_id, exercise_id)`）は今のまま。残り **19 本**を `(親 id, user_id)` に作り直す: actual_task → category / scheduled_task（SET NULL (scheduled_task_id)）/ task_template（SET NULL (template_id)）、actual_task_tap → actual_task、day_meta → pattern、pattern_version_membership → pattern / task_template_version、routine_exercise → routine、scheduled_task → category / pattern / task_template、task_template → category、task_template_exdate → task_template、task_template_version → category / task_template、workout_entry → workout_session、workout_session → actual_task（SET NULL (actual_task_id)。`UNIQUE (actual_task_id)` は残す）/ routine（SET NULL (routine_id)）、workout_set → workout_session。親 8 表（category・scheduled_task・task_template・actual_task・pattern・task_template_version・routine・workout_session）に `UNIQUE (id, user_id)`。workout_set と workout_entry の持ち主の一致は、両方が `(session_id, user_id)` で同じセッションを指すことで保たれる（`workout_set_entry_fk` は今のまま）。`pattern_template_membership` は 0013 で消す（M14）
- D5・D8 の部分 UNIQUE は表の制約では書けないので `CREATE UNIQUE INDEX ... WHERE` で作る（設計の `UNIQUE (user_id) WHERE ended_at IS NULL` は索引の意味で読む）

---

## 7. 本人に聞く問い（A〜D の見直し）

memory `feedback_qa_granularity_for_implementation_round`（後から画面・設定で直せるものは聞かない）に照らすと、**聞くのは 1 問**で足りる。

| 元の問い | 判定 | 理由 |
|---|---|---|
| A 種目（共有＋自作は人ごと／人ごとに写す） | **AI 既定で進める**（案 1＋M16 の view）。実装計画に「違えば言ってください」で載せる | 本人が困る差は無く、推奨でない側（写す）は配り直しのコストが明らか。ただし表の形なので「一方的に提示」はする |
| B 今のデータの持ち主 | **聞く**（C と 1 問に） | 本人しか知らない事実。付け替えは migration に入るので先に決める |
| C 確認メールの送り先（チームのメンバーか） | **B と 1 問に** | 「どのメールアドレスでサインインするか」を決めれば、チームのメンバーかどうか・Google のアドレスと同じかは本人がダッシュボードと Google で確かめられる |
| D 新規登録を開く時期 | **AI 既定「複数人化が終わっても、配る準備（Program・外部 SMTP）ができるまで閉じる」** | ダッシュボードのトグル 1 つで戻せる。本人の「逆に閉じる意味は？」への答え（登録の窓口は URL と anon キーで誰でも呼べる・今は配る手段が無いので開けても使う人がいない・AI の入口の費用）は食事の設計の本人回答に残っているので、実装計画に 2 行で再掲する |

**聞く 1 問（案）**: 「サインインに使うメールアドレスは次のどれですか。(1) v1 の 2 件のうち、作った日が 2026-04-14 の方 (2) 04-19 の方 (3) 新しいアドレス。あわせて、そのアドレスは Google のアカウントと同じか、Supabase のチームのメンバー（ダッシュボードに入っているアドレス）か」。選ばなかった v1 のユーザーはテスト用の 2 人目として残す（M27）。新しいアドレスなら、ダッシュボードの Add user で先に作ってから migration に入る。

足さなくてよいと判断した問い: 確認メールをリンクにするか 6 桁コードにするか（本人の言葉がリンク。代案は実装後に切り替えられる・M18）、`ensure_user_defaults` を RPC にするかトリガーにするか（M9・AI 既定）、v1 の残りの 6 関数を消すか（もう無い表を参照しており、1 つは SECURITY DEFINER で anon から呼べる。消す・AI 既定）、0013 を先に流すか（M14・AI 既定）。

---

## AI が直してよい点（番号）

M1・M2・M3・M4・M5・M6・M7・M8・M9・M10（確かめの migration は流す前に本人へ一言）・M11・M12・M14・M15・M16・M17・M18・M20・M21・M22・M23・M25・M26・M28・M30。M24 は設計 §8 の【事実は実装の前に確かめる】を表の内容で置き換える。M29 は §10 に 1 行足す。

## 本人の判断・操作が要る点

- 問い B＋C（§7 の 1 問）
- M27: v1 のユーザーを消さずテスト用に残す（反対があれば言ってもらう）
- M13: バックアップの取得（接続文字列とパスワードは本人の手元。AI は手順を書く）と、migration の適用の OK
- M19: Google Cloud（iOS と Web の 2 つのクライアント ID・同意画面）と Supabase ダッシュボード（Google provider・Skip nonce check・Redirect URLs・メールの確認・パスワードの規則・新規登録のトグル）の操作。手順は AI が書く
- M10: 本番 migration を流すときの確認画面の即時承認

---

## 作業時間（JST）

- 開始: 2026-10-19 14:02
- 終了: 2026-10-19 14:29
- 本番は読むだけ（`list_extensions`・`get_advisors`・`list_migrations`・SELECT 11 回。件数・形・権限だけで、記録の中身は読んでいない）。外部の事実は Supabase・PostgreSQL・Google・Apple の公式の文書と、supabase-mcp・supabase-swift の公開ソースで確かめた
