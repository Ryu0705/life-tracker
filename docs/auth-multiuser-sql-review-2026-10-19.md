# 0013・0014・戻し・確かめの SQL レビュー（2026-10-19 依頼・10-21 完了）

対象（すべて未 commit・ブランチ `feat/round3-training`）: `supabase/migrations/0013_drop_legacy_template.sql`・`supabase/migrations/0014_multiuser_rls.sql`・`supabase/rollback/0014_down.sql`・`supabase/test/`（`run.sh`・`auth_stub.sql`・`multiuser_test.sql`・`write_all.sql`・`checks.sql`・`normalize_schema.py`・`Dockerfile`）。

土台: 設計 `auth-multiuser-design.md` §1〜§6・§9、計画 `auth-multiuser-implementation-plan.md` §1-2〜§1-5・§3・作業時間、計画レビュー `auth-multiuser-plan-review-2026-10-19.md`（P1〜P24）、棚卸し `auth-multiuser-inventory-2026-10-19.md` §1〜§2。あわせて 0001〜0012 の migration と Swift（`SupabaseWorkoutDataSource.swift`・`SupabaseDayDataSource.swift`・`JSONDecoder+Supabase.swift`・`Models/Workout.swift`・`Models/BodyProfile.swift`）を読んだ。

- 本番 DB・MCP には触れていない。対象のファイルは直していない。書いたのはこのファイルだけ。docker の確かめに使った SQL と script は scratchpad（repo の外）。container `lt-pgtest` は消した
- 凡例: 【事実】ファイル・docker の実測で確かめた ／【推測】見立て。重さ: 高 = 本番で止まる・壊れる・守りの穴 ／ 中 = 直すべき ／ 低 = 好み・将来
- 利用制限で 2 回止まったため、分かった順に書き足し、最後に整えた（10-21）

## 要約

- **高 0・中 3・低 7**（S1〜S10）。本番で止まる・壊れる・守りの大きな穴、は見つからなかった
- 中の 3 つ: **S1** `run.sh --dump`（段階 3-1 のリハーサルの入口）が `pg_restore` の `CREATE SCHEMA public` で止まる（直し方は確かめ済み）／**S2** `workout_set_entry_fk` だけ user_id を含まず、他人の `workout_entry` に自分のセットを付けられ、付けられた側は最後のセットを消せなくなる（docker で再現）／**S3** 多人テストに「自分の行の user_id を他人に渡す」経路（RLS の WITH CHECK だけで守る 10 表）の確かめが無い
- 非 superuser の `postgres`（本番の形: `auth.users` は SELECT と REFERENCES だけ・`extensions` の CREATE 無し）で 0001〜0014・多人テスト・checks・戻しがすべて通った【事実】。superuser の docker では見えない本番の権限の芽は無い
- 計画レビュー P1〜P24 のうち SQL 側のものは、P11（行数の一致を見る SQL が無い）を除き満たしている
- 本人に聞く点: 無し

---

## 指摘

### S1（中）`run.sh --dump` が `pg_restore` の `CREATE SCHEMA public` で止まる

- どこ: `supabase/test/run.sh:71-76`（`--dump` の restore）。計画 §3-1 のリハーサル（本番の写しを stub の上に戻して 0013・0014 を流す）がこの入口を使う
- 何が起きるか【事実】: 0012 まで流した docker から `pg_dump -Fc --schema=public --schema=private` で写しを取り `run.sh --dump <写し>` を流すと、`pg_restore: error: could not execute query: ERROR: schema "public" already exists / Command was: CREATE SCHEMA public;` → `pg_restore failed` で終わる。写しの TOC（`pg_restore -l`）に `8; 2615 2200 SCHEMA - public pg_database_owner` の行がある
- 理由【事実】: `pg_dump` は `--schema=` で名前を絞ると `public` の特別扱い（所有者が `pg_database_owner` なら CREATE SCHEMA を出さない）を通らず、`CREATE SCHEMA public` を出す。stub が public を持つので `--exit-on-error` で止まる。本番の写し（pg_dump 18・`--schema=public --schema=private`）でも同じになる
- 直し方【事実・確かめた】: TOC から `SCHEMA - public` の 1 行だけを外して戻す。`run.sh` の restore を次に変えた写し（scratchpad の `run_patched.sh`）で、restore → 0013 → 0014 → plpgsql_check 0 → multiuser_test 全部通る → checks.sql OK まで通った（4.4 秒）。`ACL - SCHEMA public`（GRANT USAGE）と `DEFAULT ACL`（既定の権限 3 行）の TOC は残るので、写しの中の権限はそのまま戻る。`--exit-on-error` は保つ
  ```bash
  docker exec "$NAME" pg_restore -l /tmp/prod.dump | grep -v -E '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - public ' > "$TMPD/toc"
  docker cp "$TMPD/toc" "$NAME:/tmp/toc"
  docker exec "$NAME" pg_restore -U postgres -d postgres --no-owner --exit-on-error -L /tmp/toc /tmp/prod.dump \
    || { echo "pg_restore failed" >&2; exit 1; }
  ```

### S2（中）`workout_set_entry_fk` だけ user_id を含まず、他人の entry に自分のセットを付けられる

- どこ: `0014_multiuser_rls.sql:119`（「`workout_set_entry_fk` は今のまま」）、設計 §1「`workout_set` と `workout_entry` は、両方が `(session_id, user_id)` で同じセッションを指すので持ち主がそろう」
- 何が起きるか【事実・docker】: 設計の説明は成り立たない。セットの session と entry の session が同じことは DB のどこも検査していない。B（authenticated）が A の `workout_entry` の id を知っていれば、`INSERT INTO workout_set (session_id = B の session, exercise_id, entry_id = A の entry, set_index = 2, ...)` が**入る**（`b_set_owned_by_b = t, points_to_a_entry = t`。外部キーの検査は RLS を越える）。続けて A が `workout_set_delete` で自分のその entry の最後のセットを消すと、`DELETE FROM public.workout_entry WHERE id = v_entry` が `ERROR: update or delete on table "workout_entry" violates foreign key constraint "workout_set_entry_fk" on table "workout_set"`（23503）で RPC ごと戻り、**A は自分のセットを消せない**。A からは B のセットが見えないので原因も分からない
- 重さの理由: UUID を推測できないので、知っている相手にしか効かない（設計 M17 で種目について受け入れた形と同じ）。ただし種目は共有の行があるので組にできないが、ここは組にできる。直すのは 3 文
- 直し方: g で `workout_entry` に `UNIQUE (id, exercise_id, user_id)` を足し、`workout_set_entry_fk` を `(entry_id, exercise_id, user_id) → workout_entry (id, exercise_id, user_id)`（ON DELETE は今の NO ACTION のまま）に作り直す。旧 `workout_entry_id_exercise_id_key` は消してよい。戻し（g）に逆を足す。合わせて変えるもの: `multiuser_test.sql:171` の 18 → 19、`checks.sql:135` の 18 → 19 と `:146` の `conname <> 'workout_set_entry_fk'` の除外を消す、設計 §1 の「今のままにするもの」から外す（段階 4）
  ```sql
  ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_id_exercise_id_user_id_key UNIQUE (id, exercise_id, user_id);
  ALTER TABLE public.workout_set
    DROP CONSTRAINT workout_set_entry_fk,
    ADD CONSTRAINT workout_set_entry_fk FOREIGN KEY (entry_id, exercise_id, user_id) REFERENCES public.workout_entry (id, exercise_id, user_id);
  ALTER TABLE public.workout_entry DROP CONSTRAINT workout_entry_id_exercise_id_key;
  ```

### S3（中）多人テストに「自分の行の user_id を他人に渡す」経路の確かめが無い

- どこ: `multiuser_test.sql` 1・5。1 は B が A の行を更新できないこと（0 行）、5 は postgres で子の外部キーを見ている
- 何が起きるか: RLS の WITH CHECK だけで守る表（category・pattern・routine・task_template・workout_session・sleep_record・user_profile・body_weight_record・day_meta・training_goal と exercise の自作）で、policy を `FOR SELECT` だけ・`USING` だけに書き間違えても、今のテストは通る。SQL そのものは正しい【事実・docker】: A で `UPDATE public.sleep_record SET user_id = B` と `INSERT INTO public.category (name, user_id) VALUES ('x', B)` はどちらも `new row violates row-level security policy`（42501）
- 直し方: 1 の後に、A で全表を回す 1 ループを足す（`test.fails(format('UPDATE public.%I SET user_id = %L', v_t, B), '42501', ...)`。exercise は `SET user_id = NULL`（共有にする経路）も）。親が壊して確かめた 5 通りに「policy の WITH CHECK を外す」を足すと、この追加が効くことも見える

### S4（低）anon の 42501 の出どころを前提として 1 行確かめる

- どこ: `multiuser_test.sql` 2
- 何が起きるか: 42501 は「スキーマ public の USAGE が無い」でも同じ SQLSTATE になる。stub が `GRANT USAGE ON SCHEMA public TO anon` を持つので今は表・関数の権限を見ている【事実・docker: `has_schema_privilege('anon','public','USAGE') = t`。本番も t（計画レビュー §0-1）】が、stub を変えると素通りになる
- 直し方: 2 の先頭に `test.ok(has_schema_privilege('anon', 'public', 'USAGE'), 'stub: anon に public の USAGE')` を 1 行

### S5（低）P11（行数の一致）を見る SQL が `supabase/test/` に無い

- どこ: 計画 §3-1 の 1・3、§3-2 の 4・5（手順にだけある）
- 直し方: 読むだけの 1 文を `supabase/test/counts.sql` に置く（表ごとの `count(*)` と `count(*) FILTER (WHERE user_id = '__OWNER_UID__')`。`exercise` は共有を除く）。0014 の前は後者の列が無いので、前後で 2 文にするか `to_regclass`／`information_schema.columns` で分ける。本番でも同じ文を流せる

### S6（低・情報）`service_role` は `private` の関数を呼べない

- 【事実・docker】`has_function_privilege('service_role', 'private.todo_target(uuid,date,uuid)', 'EXECUTE') = f`（0012 から。0014 は変えていない）。公開 RPC は SECURITY INVOKER なので、service キーで `todo_fetch` などを呼ぶと中の `private.*` で `permission denied` になる見込み【推測】。加えて service_role では `auth.uid()` が NULL なので user_id NOT NULL で INSERT も止まる。アプリは service キーを使わないので今は影響なし。Edge Function などで service キーから RPC を呼ぶ日が来たら、`GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA private TO service_role` と user_id の明示が要る、と docs に一言

### S7（低・情報）応答の行に `user_id` が増える

- 【事実・docker】`todo_fetch` の `singles` などの行（`s.*` の写し）と、表の `select()` の応答に `user_id` が付く。Swift の `JSONDecoder.supabase`（`JSONDecoder+Supabase.swift`）は未知のキーを捨てる既定のままなので影響なし。`select()` を列挙に変える必要も無い

### S8（低・情報）0014 の大きさ 67KB

- `apply_migration` の上限は不明（0012 の 43.5KB は通った）。通らなければ計画 §1-3 の代替（SQL エディタで 1 回）。分けて流さない。0014 の先頭の注記にも代替を 1 行書いておくと、流す日に計画を探さずに済む

### S9（低）view の人の分離を、相手にもデータがある形で見る

- どこ: `multiuser_test.sql` 1（B は `workout_training_day` が 0 行、A は 1 行）。このとき B にはセットが無く、8 の C のセットは A と同じ日（今日）なので DISTINCT で見分けがつかない
- 直し方: 4 で B がセットを 1 つ `completed_at = 今日 − 1` で入れ、A の `workout_training_day` にその日が無いことを 1 行確かめる（`security_invoker` を外す・`ALTER VIEW` を書き忘れる、の両方に効く）

### S10（低・運用）MCP で `exercise` に user_id を書かないと共有の行になる

- 設計どおり（159 件の seed は共有）だが、本人の自作を MCP で入れるときに user_id を忘れると全員の種目になる（NOT NULL が無いので止まらない）。段階 4 の docs（`gymwork-alignment-design.md` R-3 の周り・M25）に「自作は `user_id` を明示」を一言。戻しの砦（自作があれば止める）とも関わる

---

## 依頼ごとの判定

### 1. 正しさ（0014 が 0013 の後の本番に流れて設計の形になるか）

- 順序: ADD COLUMN（NULL 可）→ UPDATE → NOT NULL・既定値、の順【事実】。b2（既定の権限）は i の表・view と l の関数より前にある【事実】。既定の権限は P1 のグローバルの `REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` ＋ `IN SCHEMA public` の 4 行で、0014 の後の `pg_default_acl` は `(global) f {postgres=X/postgres}` ／ `public S {authenticated=rwU, service_role=rwU}` ／ `public f {authenticated=X, service_role=X}` ／ `public r {authenticated=arwd, service_role=arwdDxtm}`【事実・docker】
- 名前（P13）: DROP INDEX と DROP CONSTRAINT の取り違えは無い。索引: `exercise_name_unique`・`pattern_apply_day_unique`・`workout_session_single_in_progress`・`exercise_muscle_group_idx`・`actual_task_occurrence_date_idx`・`scheduled_task_occurrence_date_idx`・`sleep_record_end_at_idx`・`workout_session_started_at_idx`。制約: `training_goal_effective_from_key`・`body_weight_record_pkey`・`day_meta_pkey`・`sleep_record_no_overlap`・外部キー 18 本。0001〜0012 の定義から導いた自動の名前と一致し、計画レビュー §0-1 の本番のカタログとも一致【事実】。名前が違えば `DROP` で止まって全部戻る（黙って進まない）
- 外部キー 18 本と ON DELETE: 設計 §1 の一覧（0013 で 1 本減って 18）と一致。`SET NULL (列)` の 4 本は user_id を残す。`auth.users` からの CASCADE と RESTRICT・SET NULL＋CHECK の組み合わせは、親の実測に加えて、自作の種目を自分のセット・ルーティンで参照、時刻なしの単発に skipped の実績、`day_meta → 休日パターン`、系列と O(d)、実績につないだセッション、を持つ人 D を `DELETE FROM auth.users` → 止まらず 21 表すべてで D の行が 0【事実・docker】。理由は RI の cascade が入れ子の問い合わせの AFTER トリガーを外の query level に積むため（`SPI_execute_snapshot(fire_triggers = false)`）。作る順に依らない
- EXCLUDE と btree_gist: `user_id WITH =` は btree_gist の `gist_uuid_ops`。既定の演算子クラスはスキーマに依らず探されるので `WITH SCHEMA extensions` で解ける【事実・docker で通る】
- view `exercise_for_user` の列: `id uuid, name text, muscle_group text, equipment text, metric_kind text, note text, is_archived boolean, sort_order integer`【事実・docker】= Swift の `Exercise`（`Models/Workout.swift:6-14`: id・name・muscleGroup・equipment?・metricKind・note?・isArchived・sortOrder?）。`is_archived` は `COALESCE(..., false)` で実際は NULL にならない。`.eq("is_archived", false).order("sort_order").order("name")` は view の列で解ける。postgres（claims 無し）で読んでも行数は `exercise` と同じ（161 = 共有 159 ＋ 自作 2。人の数だけ増えない）【事実・docker】。アプリ側の `from("exercise")`（`SupabaseWorkoutDataSource.swift:12`）の切り替えは段階 2
- `ensure_user_defaults` の `ON CONFLICT (user_id, apply_day) WHERE apply_day IS NOT NULL`・`(user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL` は h の部分 UNIQUE と一致し、2 回呼んで増えない（多人テスト 8）【事実】
- 今ある本人の行での新しい制約: 休日パターン 1・gym 1・sleep 1・体重は日が別・プロフィール 1・週の目標 1・睡眠は重なり無し・進行中のセッション 1（棚卸し §1-1）。0014 が足す一意・EXCLUDE は、1 人のデータでは今の制約と同じ条件なので、今日まで入っている行が新たに引っかかることは無い【事実・読んだ】。流す日までに増える行も同じ

### 2. 本番での失敗の芽

- **非 superuser のリハーサル**【事実・docker・scratchpad の `nosu_run.sh`】: superuser を `supabase_admin` にし、`postgres` を NOSUPERUSER CREATEDB CREATEROLE BYPASSRLS LOGIN・DB の所有者・anon／authenticated／service_role のメンバーで作り、`auth` スキーマ・`auth.users`・`auth.uid()` は `supabase_auth_admin` の所有、postgres には `auth.users` の SELECT と REFERENCES だけ（計画レビュー §0-1 で本番に確かめた 2 つ）、`extensions` は supabase_admin の所有で postgres に CREATE を与えない（USAGE だけ）形で、0001〜0014 を postgres で流した → すべて通った。plpgsql_check（supabase_admin で入れた）error 0、multiuser_test 全部通る（`auth.users` の INSERT／DELETE だけテストのために足した）、checks.sql 32 項目 t、関数の md5 は superuser の run.sh と同じ `6070b8acfbce6843e1a656b4a307456d`、A・B を消してから `0014_down.sql` も postgres で通る
  - `CREATE EXTENSION btree_gist WITH SCHEMA extensions` は extensions の CREATE が無くても入った（trusted extension の script は bootstrap superuser として走る。入った拡張の中の関数の所有者は `supabase_admin`、拡張そのものは `postgres`）。本番は supautils もあり、なお通りやすい【推測】。不安なら流す前にダッシュボード（Database → Extensions）で btree_gist を有効にしておけば `IF NOT EXISTS` で素通りする
  - `ALTER DEFAULT PRIVILEGES FOR ROLE postgres`（自分のロール）・`REVOKE ... ON ALL TABLES/FUNCTIONS IN SCHEMA public`（所有者 postgres）・`CREATE POLICY`・`ENABLE ROW LEVEL SECURITY`・`DROP FUNCTION`（v1 の 6 つ。トリガー 0 なので依存で止まらない）・`REFERENCES auth.users`・`DO` の `SELECT FROM auth.users`・`MAINTAIN`（PG17）はすべて非 superuser で通った
  - グローバルの既定の権限（b2）は postgres が作る関数にしか効かない。拡張の関数（所有者は superuser）には効かないので、後でダッシュボードから拡張を入れても PUBLIC の EXECUTE は消えない【事実・docker の所有者で確認】
- 残る違い【推測】: Management API の送り方（1 つのトランザクションは probe で確認済み）・`apply_migration` の大きさの上限（S8）・supautils の挙動。いずれも「止まる」側の違いで、「違う形で通る」側ではない。止まれば全部戻る
- 本番でだけ意味が変わるもの: 無し。`auth.uid()` の定義は stub が本番の写し、既定の権限の行は本番と同じ形（grantor `postgres`）。`supabase_admin` の既定の権限の行は postgres が作る物に効かない

### 3. 守り

- RLS: 21 表で有効・policy 24・`TO authenticated` だけ。`postgres`（所有者・BYPASSRLS）・`service_role`（BYPASSRLS）は越え、`anon` は表・view・関数の権限が無いので policy 以前に止まる【事実・docker checks】
- 権限: anon は表・view・シーケンス・public の関数・private の USAGE のどれも無し。authenticated は表に `arwd`、view に SELECT だけ、関数は全部呼べる。PUBLIC の EXECUTE は 0。既定の権限も閉じている（多人テスト 10 の捨ての関数・表）【事実】
- 他人の行に触れる経路: 外部キーの検査（18 本の組・S2 の 1 本・種目を指す 3 本）、`ON CONFLICT`（対象のキーが親の UUID を含むので本人の行としかぶつからない）、関数の中の SELECT（SECURITY INVOKER なので RLS が効く）、view の結合（`security_invoker` ＋ `p.user_id = (select auth.uid())`）を見た。穴は S2 と、設計 M17 で受け入れ済みの種目の 3 本（B が `routine_exercise` に A の自作の id を入れると入る【事実・docker】）だけ
- MCP（postgres）の入れ忘れ: 19 表と `exercise_preference` は NOT NULL（23502。多人テスト 3）、子は組の外部キー（23503。多人テスト 5）で止まる。`exercise` だけは共有の行になる（S10）

### 4. 0013

- 砦 2 つ（世代の無い系列・写していない旧 membership）は P14 のとおりで十分。消す列の中身は第 1 世代と `pattern_version_membership` から導ける（本番の 4 系列すべてに世代・1 行の旧 membership は写し済み【事実・計画レビュー §0-1】）
- `schedule_template_create` は引数を変えずに `INSERT INTO task_template DEFAULT VALUES`。CREATE OR REPLACE なので GRANT は保たれる。0013 と 0014 の間、今のビルド（RPC の名前と引数は同じ・`exercise` と `user_profile` は 0014 まで変わらない・`pattern_template_membership` は Swift のどこも読まない）は動く【事実・読んだ・docker で 0013 の後に 19 の RPC が通る】
- 旧列を読む関数はほかに無い（plpgsql_check 0・grep 0）

### 5. 戻し

- 本当に戻るか: 親の `--rollback`（順序をそろえた pg_dump と pg_default_acl の差分 0）に加えて、非 superuser の postgres でも通った【事実】。pg_default_acl は PostgreSQL が格納のときに並べ替える（`SetDefaultACL` の `aclitemsort`）ので、差分 0 は行の並びに依らない
- 砦: 19 表＋`exercise_preference` の user_id の種類が 2 以上なら止める・自作の種目があれば止める。postgres（BYPASSRLS）で数えるので全行を見る。A・B・本人の 3 人がいる状態で流すと先頭で `ERROR: rollback: data of 3 users exists (only safe with one)` で止まり、policy は 24 のまま【事実・docker】。十分
- 本番で止まる所: 非 superuser で通ったので無し。`CREATE TEMP TABLE` は TEMP の権限（既定で PUBLIC）で通る
- 列の並び: `user_profile.id`・`exercise.note`・`exercise.is_archived` が末尾に付く。PostgREST は JSON のキーで返し、Swift は Codable のキーで読む。関数の `s.*`・`a.*` は `to_jsonb` でキーになる。影響なし【事実・読んだ】
- 戻さないもの（v1 の関数 6 つ・btree_gist・`schema_migrations` の記録）は先頭に書いてある。戻した後は今のビルド（anon キー）が動く形（anon に表と関数の権限が戻る）【事実・docker: `anon select on category = true`・`jst_today` の PUBLIC EXECUTE = true】

### 6. 確かめの穴

- 「通るべきでないのに通る」作りは見つからなかった。`test.n`／`test.affected` はエラーを例外のまま上げる（黙って 0 にならない）。2 は anon に SELECT が残っていれば 0 行で「成功」になって FAIL する。5 は 18 本を数える。10 は捨ての関数で既定の権限を実際に見る
- 足すべきもの: S3（WITH CHECK の経路）・S4（anon の前提）・S5（P11 の行数）・S9（view の分離）。S2 を直すなら 18 → 19
- `run.sh --dump` は S1 を直すまで使えない

### 7. 計画レビュー P1〜P24 の充足（SQL 側）

| P | 判定 |
|---|---|
| P1 | 満たす（b2 のグローバルの REVOKE・戻しの GRANT・多人テスト 10・checks の `default acl` 3 項目） |
| P3 | run.sh の `--dump` が private 込みの写しを前提にしている。ただし S1 |
| P5 | 満たす（`IF EXISTS`・先頭の注記） |
| P6 | 満たす（b2 の位置・`ALL ... IN SCHEMA`） |
| P7 | 満たす（checks の md5・write_all の 9） |
| P11 | **未**（S5） |
| P12 | 満たす（MAINTAIN の REVOKE・既定の権限・checks） |
| P13 | 満たす |
| P14 | 満たす（0013 の砦 2 つ） |
| P15 | 満たす（`category_user_idx`・`pattern_user_idx`・checks の `indpred IS NULL`） |
| P16 | 満たす（明示のキャスト無し） |
| P17 | 代替は計画に。0014 の注記には無い（S8） |
| P18 | 満たす（23502・自作の view・C の CASCADE・policy 24／roles／service_role） |
| P23 | 満たす（l が m より前） |
| P2・P4・P8〜P10・P19〜P22・P24 | アプリ・運用側（この依頼の外） |

---

## 本人に聞くべき点

無し。S2 を直すかは細部（AI 既定: 直す。3 文で、設計の説明どおりの形になる）。

---

## docker の確かめ（10-21・container `lt-pgtest`・終わったら消した）

| 手順 | 結果 |
|---|---|
| `supabase/test/run.sh --keep` | 0001〜0014 → plpgsql_check 0 → multiuser_test 全部通る → checks.sql 31 項目 t（4.6 秒） |
| probe（上の container に。scratchpad `probe1.sql`〜`probe3.sql`） | (a) A が自分の行の user_id を B に: 42501 ／ (b) A が user_id = B を明示して INSERT: 42501 ／ (c) B が A の entry にセットを付ける: 入る → A の `workout_set_delete` が 23503（S2）／ (c') B が `routine_exercise` に A の自作を入れる: 入る ／ (d) 人 D の CASCADE: 21 表で 0 ／ (e) anon の public USAGE: t ／ (f) `todo_fetch` の行に `user_id` ／ (g) view の列 ／ (h) service_role の private EXECUTE: f ／ (l) pg_default_acl 4 行 ／ (m) postgres で view 161 行 ／ (i) 3 人いる状態の戻し: 砦で止まる |
| `nosu_run.sh`（非 superuser の postgres） | 0001〜0014・plpgsql_check 0・multiuser_test・checks 32 t・戻し、すべて通る。md5 同じ |
| `run.sh --upto 0012 --keep` → `pg_dump -Fc --schema=public --schema=private` → `run.sh --dump` | `CREATE SCHEMA public` で `pg_restore failed`（S1） |
| `run_patched.sh --dump`（TOC から `SCHEMA - public` を外す） | restore → 0013 → 0014 → plpgsql_check 0 → multiuser_test → checks OK（4.4 秒） |

## 作業時間（JST）

- 2026-10-19 18:52 依頼。ファイルと土台の文書を読んだ所で利用制限（2 回）
- 2026-10-21 18 時台: 読んだ段階の指摘を書き出し → docker の probe → 非 superuser のリハーサル → `--dump` の確かめ → このファイルを整えた
