# サインインと複数人化 実装計画レビュー（2026-10-19）

対象: `auth-multiuser-implementation-plan.md`（14:55 下書き）。土台: `auth-multiuser-design.md`（設計）・`auth-multiuser-review-2026-10-19.md`（設計レビュー M1〜M30）・`auth-multiuser-inventory-2026-10-19.md`（棚卸し）。§ の番号は、断りが無ければ計画のもの。

- 読んだもの: 計画・設計・設計レビュー・棚卸し・`CLAUDE.md`・`AGENTS.md`・migration 0001〜0012・Swift（`LifeTrackerApp`・`SupabaseWorkoutDataSource`・`SupabaseDayDataSource`・`SleepRules`・`Continuity`・`ContinuityStore`・`StreakWidget`・`WorkoutDataSource`・UI テスト 2 ファイル・`Info.plist`・`project.pbxproj`・`Package.resolved`）・手元の supabase-swift 2.44.1（`AuthClient`・`AuthClientConfiguration`・`SessionManager`・`APIClient`・`SupabaseClient`・`Types`）
- 確かめ方: 本番は MCP の読むだけの SQL（カタログ・件数・権限・定義だけ。記録の中身は読んでいない）。docker の `postgres:17`（17.11）と `postgrest/postgrest` で動きを実測した（終わったら消した）。外部は GoogleSignIn-iOS・AppAuth-iOS・supabase/auth（GoTrue）の公開ソースと、Supabase・Google の公式文書
- 書いたのはこのファイルだけ。DB・計画・他の docs・コードは変えていない。秘密の値（UID・メールアドレス・キー・Bundle ID・App Group・クライアント ID）は書いていない
- 凡例: 【事実】ファイル・SQL・実測・公式ソースで確かめた ／【推測】見立て。重さ: 高 = 直さないと計画の目的が達せない・本番で壊れる ／ 中 = 実装前に直す ／ 低 = 細部・注記

---

## 要約

- **高 2・中 10・低 12**（P1〜P24）
- **高の 2 つ**: (P1) 既定の権限を `IN SCHEMA public` だけで REVOKE しても、これから作る関数には PUBLIC の EXECUTE（`=X`）が付いたまま（docker で実測）。グローバルの `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` を足す。計画の確かめ「`pg_default_acl` に anon が無い」では見つからない。(P2) PKCE では supabase-swift 2.44.1 が `.passwordRecovery` を出さず、GoTrue の転送先にも `type` が付かないので、再設定のリンクを踏んでも「新しいパスワード」の画面が出ず、ただサインイン済みになる。アプリ側で「再設定を頼んだ」印を持って出し分ける
- 計画が設計から変えた 3 点はいずれも妥当【事実】: 0013 の 5 列削除（本番の 4 系列すべてに世代があり、旧 membership の 1 行も写し済み）、`exercise_for_user` の結合条件、Google の nonce（GoogleSignIn-iOS 9.0.0 が nonce をそのまま AppAuth へ渡し、GoTrue は `sha256` の hex で照合する）
- 依頼の【推測】はほぼ事実に格上げできた（§6 の表）。未確認のまま残るのは `apply_migration` のトランザクション（閉じた実装。probe は妥当）と、実機でメールのリンクがアプリへ戻る動き（実機で確かめる）だけ
- 杞憂だったもの【実測】: `auth.users` の削除の CASCADE の順序（FK の作成順に依らず通る）、pg_dump 18 の形式（pg_restore 17 で読める）、PostgREST の upsert（`user_id` を送らず `on_conflict=user_id` で入り、2 回目は更新になる）、MCP での `SET LOCAL ROLE authenticated`（使える）

---

## 0. 確かめた事実

### 0-1 本番（MCP・読むだけ）

| 項目 | 事実 |
|---|---|
| 実行ロール | MCP の SQL は `postgres`。superuser ではないが BYPASSRLS・CREATEROLE。`anon`・`authenticated`・`service_role`・`authenticator` のメンバー → `SET ROLE authenticated` ができる |
| `SET LOCAL ROLE` | `execute_sql` で `SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', ..., true); SELECT auth.uid()` が通る（`current_user = authenticated`、`auth.uid()` が置いた sub を返す、`transaction_read_only = off`）。§3-2 5 の方法はそのまま使える |
| `auth.users` への権限 | `postgres` は `REFERENCES`・`SELECT` を持つ（0014 の `REFERENCES auth.users(id)` と `DO` の確かめは通る）。所有者は `supabase_auth_admin` |
| `authenticated` | `auth` スキーマの USAGE と `auth.uid()` の EXECUTE を持つ（列の既定値 `auth.uid()` が動く）。`public` の CREATE は無し。`private` の USAGE あり（anon も） |
| 既定の権限 | `pg_default_acl` の public は grantor `postgres`・`supabase_admin` の 2 系統。どちらも表 `arwdDxtm`、関数 `X`、シーケンス `rwU` を `postgres`・`anon`・`authenticated`・`service_role` に。**PUBLIC の `=X` は `pg_default_acl` に無い**（組み込みの既定から来る。P1）。`m` は PG17 の MAINTAIN（P12） |
| 関数 | public 22＋v1 の 6、private 6。すべて所有者 `postgres`。v1 の 6 つのシグネチャは計画 o のとおり（`fn_resolve_month_patterns(integer, integer)` は `LANGUAGE sql`・SECURITY DEFINER・`search_path=public`） |
| 外部キー | 計画の 18 本（設計レビュー M30 の 19 本 − `task_template_category_id_fkey`）と一致。`workout_set_entry_fk` と `exercise` を指す 3 本はそのまま |
| 索引・制約の種類 | `exercise_name_unique`・`pattern_apply_day_unique`・`workout_session_single_in_progress` は **INDEX**（`DROP INDEX`）。`training_goal_effective_from_key`・`workout_session_actual_task_id_key` は **CONSTRAINT**。`sleep_record_no_overlap` は **EXCLUDE 制約**（`DROP CONSTRAINT`）。`exercise_muscle_group_idx` は `WHERE is_archived = false` |
| 0013 の安全 | `task_template` 4 行すべてに `task_template_version` がある。`pattern_template_membership` 1 行は `pattern_version_membership` に写し済み。`task_template.start_minutes_from_midnight`・`duration_minutes` は 0012 で NULL 可に、`name`・`category_id` は NOT NULL のまま |
| 拡張 | `btree_gist` 未インストール。`plpgsql_check` は `pg_available_extensions` にある（未インストール） |
| その他 | public にシーケンス 0・トリガー 0・enum 1（`apply_day_enum`）。view `workout_training_day` の `reloptions` は NULL。`category` の gym 1・sleep 1、休日パターン 1。`exercise` のアーカイブ・メモは 0 |

### 0-2 docker（postgres:17.11・postgrest/postgrest latest）で実測したこと

| 項目 | 結果 |
|---|---|
| 既定の権限（P1） | Supabase と同じ既定の権限を置いた後、`ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon` → その後に作った関数の `proacl` は `{=X/app,authenticated=X,...}` で **anon が実行できる**（`has_function_privilege = true`）。グローバルの `ALTER DEFAULT PRIVILEGES FOR ROLE app REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` を足すと `{authenticated=X,...}` になり false。表の方はスキーマ単位の REVOKE で anon の SELECT が false になる |
| `SET search_path = ''` | SQL 関数は表名が未修飾だと **CREATE で失敗**（migration が止まる）。plpgsql は CREATE は通り実行時に失敗。`SET CONSTRAINTS public.x` は通り、未修飾は「constraint does not exist」（設計レビュー M3 の裏付け）。enum は `'Holiday'` のリテラルなら通り、`::apply_day_enum` の明示のキャストは「type does not exist」。`gen_random_uuid()` は空の検索パスでも通る（pg_catalog） |
| plpgsql_check | `apt-get install postgresql-17-plpgsql-check`（2.10.13-1.pgdg13+1）で入る。関数の `SET search_path=''` を尊重し、未修飾の表・関数呼び出しを `error` で出す。**`SET CONSTRAINTS` の制約名は見ない**（未修飾でも 0 件） |
| `ensure_user_defaults` の形 | `ON CONFLICT (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL DO NOTHING` が部分 UNIQUE に合う。2 回呼んで 1 行 |
| CASCADE の順序 | `auth.users` を消すとき、親（RESTRICT・`SET NULL (col)`＋CHECK の子を持つ）の `user_id` FK を先に作っても後に作っても通り、全表 0 行になる（RI の連鎖は同じ query level に積まれ、後から RESTRICT が検査されるため）。FK の作成順を気にする必要は無い |
| pg_dump 18 → 17 | 手元の `pg_dump` 18.0 の `-Fc` を docker の `pg_restore` 17.11 が読める（`-l` で TOC が出る）。手元の `pg_restore` 18 から TCP で戻すのも通る |
| PostgREST | anon で表の GET → **401**（`42501`）、RPC → 401。authenticated で `POST /user_profile?on_conflict=user_id`＋`Prefer: resolution=merge-duplicates`、本文に `user_id` 無し → 201、2 回目 → 200 で更新、行は 1。`on_conflict=user_id,recorded_on`・`user_id,effective_from` も同じ。別の人からは `[]`。別の人が他人の `user_id` を本文に入れると **403**（RLS の WITH CHECK・`42501`） |

### 0-3 手元のパッケージ・外部のソース

| 項目 | 事実 | 出典 |
|---|---|---|
| `emitLocalSessionAsInitialSession` | 既定 `false`。`true` なら端末のセッションをそのまま `.initialSession` で流し（期限切れでも）、期限切れなら裏で更新する。`false` だと更新を待ってから流し、実行時に `reportIssue` の警告を出す | `AuthClient.swift:1404-1434` |
| `.signedOut` が出るとき | `signOut()` と、API が `session_not_found`・`session_expired`・`refresh_token_not_found`・`refresh_token_already_used` を返したときだけ。ネットワークの失敗では出ない。自動更新は失敗を握りつぶして次の tick で再試行 | `APIClient.swift:43-47, 117-122`、`SessionManager.swift`（`autoRefreshTokenTick` の `try?`） |
| セッション無し・更新失敗のときのヘッダ | リクエストごとに `try? auth.session` → nil なら Authorization を付けず、既定ヘッダの anon キーで送る | `SupabaseClient.swift:160-161, 354-369` |
| PKCE と `.passwordRecovery` | `.passwordRecovery` を出すのは implicit の `type=recovery` だけ。PKCE は `exchangeCodeForSession` → `.signedIn` のみ | `AuthClient.swift:901-902, 905-925, 612-640` |
| GoTrue の PKCE の転送先 | `prepPKCERedirectURL` は `code` だけを付ける。implicit は `type=` を付ける | supabase/auth `internal/api/verify.go` |
| GoTrue の nonce の照合 | `hex(sha256(params.Nonce)) == idToken.Nonce`。両方あるか両方無いかでなければ「Passed nonce and nonce in id_token should either both exist or not.」。Skip nonce check で丸ごと飛ばす。生の比較は無い | supabase/auth `internal/api/token_oidc.go` |
| 新規登録 OFF と Google の連携 | `DisableSignup` の検査は `CreateAccount` の分岐だけ。同じ確認済みメールの `LinkAccount` は通る（新しい Google アカウントの初回は止まる） | supabase/auth `internal/api/external.go` |
| GoogleSignIn-iOS の nonce | 9.0.0「Allow providing a custom nonce via GSI to AppAuth」。`signInWithPresentingViewController:hint:additionalScopes:nonce:completion:`（Swift: `signIn(withPresenting:hint:additionalScopes:nonce:)`）。`nonce:options.nonce` をそのまま AppAuth の初期化子へ渡す（ハッシュしない）。未指定なら AppAuth が乱数の nonce を作る（`nonce:[[self class] generateState]`）= 今の Supabase の手順で Skip が要る理由 | CHANGELOG.md・`GIDSignIn.h`・`GIDSignIn.m`・AppAuth `OIDAuthorizationRequest.m` |
| GoogleSignIn-iOS 10.0.0 | AppAuth 3.0.0・GTMAppAuth 6.0.0、iOS 15 以上（本プロジェクトは 26.2 なので可） | CHANGELOG.md |
| Google の公式手順 | `-ObjC` の指定は無い。`Info.plist` は `GIDClientID`・`CFBundleURLTypes`（逆順のクライアント ID）、`GIDServerClientID` は任意 | developers.google.com/identity/sign-in/ios/start-integrating |
| Supabase の Google（iOS）の手順 | 今も「Skip nonce check を有効」「iOS と Web のクライアント ID をコンマ区切り」。Swift の例は nonce を渡さない | supabase.com/docs/guides/auth/social-login/auth-google?platform=ios |

---

## 1. 設計との整合と、計画が設計から変えた 3 点（依頼 1）

本人の決定（12:1x〜14:4x）と M1〜M30 は計画に反映されている。食い違いは次の 3 つで、いずれも「設計と計画の両方が同じ前提を置いている」もの（P1・P2・P8）。

| 変えた点 | 判定 | 根拠 |
|---|---|---|
| 0013 で `task_template` の中身の列 5 つを消し、外部キーは 18 本 | **妥当**【事実】 | 本番で 4 系列すべてに世代があり、旧 membership 1 行は `pattern_version_membership` に写し済み（§0-1）。Swift に `from("task_template")`・`from("pattern_template_membership")` は無い（grep 0 件）。`INSERT INTO public.task_template DEFAULT VALUES RETURNING id` は `id DEFAULT gen_random_uuid()`（0014 後は `user_id DEFAULT auth.uid()` も）で通る。0013 と 0014 の間も今のビルドは動く（`schedule_template_create` の引数は変えない） |
| `exercise_for_user` の結合に `p.user_id = (select auth.uid())` | **妥当** | `security_invoker = true` のまま。RLS を越える `postgres`（MCP）で読んだとき人の数だけ行が増えるのを防ぐ。`postgres` では `auth.uid()` が NULL なので設定が結合されず既定の形で見える（意図どおり）。`security_invoker` は外せない（外すと `exercise` の他人の自作が見える） |
| Google は nonce を渡し Skip nonce check は OFF | **妥当・成立する**【事実】 | GSI 9.0.0 以上は nonce をそのまま AppAuth へ渡し、Google は ID トークンの `nonce` にそのまま返す。GoTrue は `hex(sha256(request.nonce))` と比べる（§0-3）。したがって「乱数 raw を作り、`sha256(raw)` の**小文字 hex** を GSI の `nonce:` に、raw を `OpenIDConnectCredentials(nonce:)` に」で通る（P19） |

- 設計 §1 の「19 本」は段階 4 で 18 に直す（計画 §1-2 の注記どおり）
- 設計 §7「`.passwordRecovery` で新しいパスワードの画面」は P2 で設計側も直す
- 設計 §2 A3 / 計画 §2-6 の「`continuity.v1` を消す」と「`Snapshot` に `isSignedIn`」は両立しない（P8）

---

## 2. 本番の順序・戻し方・失敗時（依頼 2）

### P3（中・AI）バックアップの `--schema=public` では `private` スキーマが入らない
- 場所: §3-1「`pg_dump ... --schema=public`」
- 問題【事実】: `private` の関数 6 つが写しに入らない。0014 の `todo_fetch`（`LANGUAGE sql`・`private.todo_closed_on` を参照）は `SET search_path = ''` で CREATE 時に本文が検証されるので（§0-2）、写しの DB で 0014 が止まり、リハーサルが成立しない。本番では `private` があるので本番だけ通る＝リハーサルの意味が薄れる
- 直し方: `--schema=public --schema=private`。写しには `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin ...` と `dashboard_user` への GRANT が入りうるので、stub に `supabase_admin`・`dashboard_user` のロールも作る（無いと `pg_restore` がエラーを数える。`--no-owner` だけでは足りない）。pg_dump 18 の `-Fc` は docker の pg_restore 17 で読める（§0-2）ので版の心配は無い

### P4（中・AI）新しいビルドを先に入れられない、は過大。入れておく方が安全
- 場所: 前提「新しいビルドは 0014 の前の DB では動かない … だから『先に新しいビルドを入れておく』もできない」、U6
- 【事実】0014 の前の DB で新しいビルドがサインインすると、`authenticated` は全表に権限があり RLS も無いので、予定・睡眠タブは動く。壊れるのは種目の view（`exercise_for_user` が無い）・プロフィール／体重／週の目標の upsert（`user_id` 列が無い）・`ensure_user_defaults`（無い。計画どおり握りつぶす）だけ。自動の書き込み（前日のセッションを閉じる等）は `user_id` 無しの行になるが、0014 の e（`WHERE user_id IS NULL` を本人に）が拾う
- 直し方（順の提案）: U6 を 0013 の**直前**に動かす。本人がつないだ iPhone に新しいビルドを入れ、起動してサインインの画面まで見る → 0013 → 0014 → アプリを再起動。これで (1) 署名・インストールの失敗が DB を変える前に分かる、(2)「何も動かない時間」が再起動の数秒になる。ただし入れた時点からトレーニングタブは 0014 まで使えないので、入れるのは流す直前。計画の順のままでも成立はする（差は失敗の場所と空白の長さ）

### P5（中・AI）1 つのトランザクションでなかったときの後始末と、戻した後の履歴
- 場所: §3-3「0014 の途中の失敗」、§1-4
- 問題: 0-3 で「1 つのトランザクションでない」と分かった場合、途中で止まった 0014 の後に部分的な状態が残る。戻しの SQL が「0014 が全部流れた形」だけを前提にしていると、そのときに使えない
- 直し方: 戻しの SQL を最初から `IF EXISTS`・`DO $$ IF to_regclass(...) ... $$` で「部分的な状態からも通る」形に書く（戻しの確かめは同じ手順で済む）。戻しても `supabase_migrations.schema_migrations` には 0014 の記録が残り `list_migrations` は適用済みに見える、と戻しの先頭に書く。`_txn_probe` が残った場合も、消すまでは anon に開いた表になる（害は無いが DROP を忘れない）

### 問題なし（依頼 2 のうち確かめて問題が無かったもの）
- **0013 が戻せないこと**: 消す中身は第 1 世代と `pattern_version_membership` から導ける（本番で全行に対応あり・§0-1）。読む側は 0006 より前のビルドだけで、Personal Team の署名は 7 日で切れる【推測・Apple の無料署名の仕様として知られている】ので、戻す必要は出ない。保険として P14 の guard を足す
- **トランザクションの確かめ（0-3）**: Management API の送り方は閉じた実装で確かめられないので、probe は妥当。失敗した版が `list_migrations` に残るかも同時に分かる
- **確認の画面の `cancelled`**: 0013・0014 とも DROP を含むので確認は 2 回出る。`cancelled` なら何も流れていない、の扱いでよい（1 つのトランザクションなら）
- **`'__OWNER_UID__'` の置き換え忘れ**: `'__OWNER_UID__'::uuid` の時点で 22P02 になり UPDATE の前に止まる。`DO` の確かめと二重の砦

---

## 3. 0014 の中身の順 a〜p（依頼 3）

### P1（高・AI）スキーマ単位の既定の権限の REVOKE では、これから作る関数に PUBLIC の EXECUTE が残る
- 場所: §1-3「既定の権限」（`FOR ROLE postgres IN SCHEMA public` で … 関数は `PUBLIC`・anon から `EXECUTE` を外す）、§1-5 #10「`pg_default_acl` に anon が無い」、設計 §5・設計レビュー M1・M2
- 問題【事実・docker で実測・§0-2】: スキーマ単位の既定 ACL は「空から始まり、作成時に組み込みの既定と足し算で合成される」（PostgreSQL の `aclmerge`）。関数の組み込みの既定は PUBLIC に EXECUTE なので、`IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` は何も消さない。本番の `pg_default_acl` に `=X` が無いのに、作った関数には `=X/postgres` が付いている（§0-1）のはこのため。計画の確かめ「`pg_default_acl` に anon が無い」は通るが、0015 以降で作る関数（食事の RPC・AI の入口）は REVOKE を書き忘れると anon から呼べる。Supabase の hardening の文書が `in schema public` で書いているが、PostgreSQL の挙動は上のとおり
- 影響の範囲: 0014 自身は m の `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon` で閉じるので、今回の 29 関数は漏れない。漏れるのは「これから」
- 直し方: (1) m に `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;`（`IN SCHEMA` 無し）を足す。`postgres` が作る関数すべてに効く（`private` にも効き、望ましい）。(2) 戻しの SQL に `ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC;` を足す（グローバルの行が消えて元に戻る）。(3) §1-5 #10 に「0014 の後に捨て関数を 1 つ作り、`proacl` に `=X` が無い・anon の `has_function_privilege` が false・消す」を足す。(4) 本番の確かめ 2 の照会を `WHERE defaclnamespace IN (0, 'public'::regnamespace)` にし、`defaclrole = postgres, defaclnamespace = 0, defaclobjtype = 'f', defaclacl = {postgres=X/postgres}` の行があることを見る。(5) 設計 §5・設計レビュー M2 の記述も直す（段階 4）

### P6（中・AI）既定の権限の変更は b の直後へ。m の REVOKE は `ALL ... IN SCHEMA` の形で
- 場所: 順 i（`exercise_preference`・`exercise_for_user`）・l（`ensure_user_defaults`）・m（権限）
- 問題: 既定の権限を変えるのが m なので、i と l で作る物は古い既定（表は anon に全部、関数は PUBLIC＋anon）で作られる。m の REVOKE を個別に列挙すると漏れる
- 直し方: `ALTER DEFAULT PRIVILEGES`（P1 のグローバル分を含む）を b の直後に移し、さらに m の REVOKE は `REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon`（view を含む）・`REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon`・`REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon`・`REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM authenticated`（P12）・2 つの view から `INSERT, UPDATE, DELETE` を `authenticated` から外す、の形にする。`private` は `REVOKE USAGE ON SCHEMA private FROM anon` と `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM anon`

### P12（低・AI）PG17 の MAINTAIN 権限
- 【事実】本番の既定 ACL `arwdDxtm` の `m` は PostgreSQL 17 の MAINTAIN（VACUUM・ANALYZE・REINDEX・LOCK TABLE など）。「authenticated には SELECT・INSERT・UPDATE・DELETE だけ」にするなら `REVOKE MAINTAIN` も要る（既定の権限の REVOKE も同じ）。確かめの表に `MAINTAIN = false` を足す。PostgREST からは出せない文なので実害は小さい

### P13（低・AI）g・h・i の DROP は種類を間違えると失敗する
- 【事実・§0-1】`exercise_name_unique`・`pattern_apply_day_unique`・`workout_session_single_in_progress` は `DROP INDEX`。`training_goal_effective_from_key`・`workout_session_actual_task_id_key`（残す）は制約。`sleep_record_no_overlap` は `ALTER TABLE sleep_record DROP CONSTRAINT sleep_record_no_overlap` → `ADD CONSTRAINT ... EXCLUDE USING gist (user_id WITH =, tstzrange(start_at, end_at) WITH &&)`。`user_profile` は `DROP COLUMN id` で主キーと `user_profile_single_chk` が自動で落ちる（その列だけの制約）ので、`ADD PRIMARY KEY (user_id)` だけでよい。`body_weight_record`・`day_meta` は `DROP CONSTRAINT xxx_pkey` → `ADD PRIMARY KEY (user_id, ...)`。計画にこの一覧を書くと、サブエージェントの試行錯誤が減る

### P14（低・AI）0013 に guard を 2 つ
- `DO $$ … IF EXISTS (SELECT 1 FROM task_template t WHERE NOT EXISTS (SELECT 1 FROM task_template_version v WHERE v.template_id = t.id)) THEN RAISE … $$` と、`pattern_template_membership` の各行が `pattern_version_membership` に写っていることの guard。今は本番で 0 件（§0-1）だが、流す日までに変わらない保証は無く、1 行で済む

### P15（低・AI）j の「user_id が先頭の索引」は部分索引を数えない
- `category_user_kind_unique`・`pattern` の `(user_id, apply_day) WHERE …` は部分索引で、RLS の `user_id = …` の絞り込みには使えない。`category`・`pattern` には素の `(user_id)` を足す。§1-5 #10 の照会は `pg_index.indpred IS NULL` を条件にする

### P16（低・AI）l の書き直しの規則に「キャストはスキーマ付き」を足す
- 【事実・§0-2】`'Holiday'` のようなリテラルは通るが、`::apply_day_enum` の明示のキャストは `::public.apply_day_enum` でないと失敗する。今の関数本文に明示のキャストは無い（grep 0 件）が、サブエージェントへの指示に 1 行足す。`gen_random_uuid()`・`make_interval`・`tstzrange` などの pg_catalog の関数は修飾不要

### P17（低・情報）MCP の呼び出しの大きさ
- 0012 は 43.5KB で通った。0014 は 29 関数の本文＋DDL で 70KB 前後の見込み【推測】。通らなければ `AGENTS.md` の代替（ダッシュボードの SQL エディタ）でも 1 回の query なので 1 トランザクションは保てる。分割はしない（原子性が崩れる）

### 問題なし
- **RLS と複合外部キー**: 外部キーの検査と ON DELETE の動作は表の所有者（`postgres`・BYPASSRLS）で走り RLS を越える。`ON DELETE SET NULL (template_id)` は PG15 以上の形で本番 17.6 で使える（設計レビューで確認済み）
- **ON CONFLICT と部分 UNIQUE**: `ON CONFLICT (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL DO NOTHING` が推論に合う（実測）。関数の中の既存の `ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL` は、`template_id` が複合 FK で本人の物に限られるのでそのままでよい（設計 §4 の判断は正しい）
- **`SET search_path = ''` と型・enum・キャスト**: 上の P16 以外は問題なし。SQL 関数は CREATE で検証されるので修飾漏れは migration 自体が止めてくれる（§0-2）
- **`ensure_user_defaults` の同時呼び出し**: 部分 UNIQUE＋`ON CONFLICT DO NOTHING` で 2 件にならない（2 回目は待って何もしない）。本人（付け替え済み）では 0 行（gym 1・sleep 1・休日 1 が既にある・§0-1）
- **view の権限**: `security_invoker = true` の view は呼んだ人の権限で下の表を読むので、authenticated に SELECT だけで足りる。anon は `ALL TABLES` の REVOKE に view が含まれる
- **`ALL FUNCTIONS IN SCHEMA public` の REVOKE**: public に拡張の関数・シーケンスは無い（§0-1）。v1 の 6 つも対象になるが o で消す
- **`auth.users` の削除（将来の退会・M27 のテスト用ユーザーの削除）**: FK の作成順に依らず通る（§0-2）。順序の調整は不要

---

## 4. 確かめ §1-5 の 1〜10・§3-2（依頼 4）

### P7（中・AI）`plpgsql_check が 0 件` は本番では流せない。関数の同一性は md5 で示す
- 場所: §1-5 #10「本番でも同じ SQL を流す」、§3-2 3
- 【事実】本番に `plpgsql_check` は入っていない（入れられるが `CREATE EXTENSION` は DDL）。また plpgsql_check は `SET CONSTRAINTS` の制約名を見ない（§0-2）ので、M3 の経路は #9 の実行の確かめでしか止められない（#9 は過剰ではない）
- 直し方: #10 の本番版から plpgsql_check を外し、代わりに docker（写し）と本番で `SELECT md5(string_agg(pg_get_functiondef(p.oid), E'\n' ORDER BY p.oid::regprocedure::text)) FROM pg_proc p WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)` を比べる（同じなら docker の plpgsql_check の結果が本番にも当てはまる）

### P11（中・AI）「206 行」は固定の数にしない
- 場所: §3-1「本人で見える行 = 付け替えの前の 206 行＋種目 159 件」
- 【事実】206 は 10-19 の棚卸しの数で、0013 が消す `pattern_template_membership` の 1 行を含む（0013 後は 205）。段階 3 までに記録は増える
- 直し方: リハーサルと本番で「0014 の前に各表の `count(*)` を取り（`exercise` を除く）、0014 の後に `WHERE user_id = '<本人>'` の合計と一致」を見る。数は取った時点の値

### P18（低・AI）§1-5 に足す 4 つ・§3-2 の注記 2 つ
- 足す: (a) `postgres` で `INSERT INTO public.category (name) VALUES ('x')` → 23502（MCP の入れ忘れを NOT NULL が止める設計の確かめ）、(b) A の自作種目が A の view に出て B には出ない、(c) C を `auth.users` から消すと C の行が全表で 0（§0-2 の実測を migration の形で再確認）、(d) `pg_policies` が 24（21 表＋`exercise` の追加 3）で `roles` が `{authenticated}` だけ、`service_role` の表の権限が残っている（REVOKE の書き過ぎを止める）
- §3-2 5 の注記: 2 人目の「全表 0 行」は**アプリでサインインする前**に見る。アプリで入ると `ensure_user_defaults` が 3 行（pattern 1・category 2）を作るので、設計 §9 の「全タブが空」は記録が無いという意味で、行数は 3 になる
- §3-2 6 の注記: anon キーだけの `curl` は **401**（JWT 無し）、RLS の WITH CHECK 違反は 403（実測）。「401／403」の書き方は合っている

### 過剰な所
- 無い。戻しの「`pg_dump --schema-only` の差分 0」は戻しの SQL に 28 関数の本文をそのまま持つことになるが、機械的に作れる（`pg_get_functiondef` の写し）ので保つ価値がある。`ALTER FUNCTION … RESET search_path` だけにすると本文の `public.` が残り差分 0 にならないので、その近道は採らない

---

## 5. アプリ側（依頼 5）

### P2（高・AI）PKCE では `.passwordRecovery` が来ない。再設定のリンクを踏んでもパスワードの画面が出ない
- 場所: §2-1「新しいパスワードの入力（再設定のリンクから）」、§2-2、§2-7 の単体テスト「再設定のリンク」、§2-8 3、設計 §7（M23）
- 問題【事実・§0-3】: supabase-swift 2.44.1 の PKCE の経路は `exchangeCodeForSession` → `.signedIn` だけ（`.passwordRecovery` は implicit の `type=recovery` のときだけ）。GoTrue の PKCE の転送先も `code` だけで `type` が付かない。→ リンクを踏むとサインイン済みになるだけで、新しいパスワードを入れる画面に行かない。設定画面はまだ無いので、パスワードを変える手段が無い
- 直し方: `AuthStore` が「再設定を頼んだ」印を持つ。`resetPasswordForEmail` が成功したら UserDefaults に時刻を保存し（アプリが落ちた後にリンクを踏んでも効くよう永続）、URL 経由（`session(from:)`）の `.signedIn` が来たときに印があれば「新しいパスワード」画面 → `update(user: UserAttributes(password:))` → 印を消す。メールとパスワードの通常のサインインでも印を消す。印は 1 時間などで失効。単体テストの「再設定のリンク」のケースはこの形で書く。代案: 再設定だけ 6 桁コード（`verifyOTP(email:token:type: .recovery)`。種別が自明）。本人の言葉が「リンク」なので印の案を既定にする

### P8（中・AI）ウィジェットの「消す」と「印を足す」は両立しない
- 場所: §2-6「App Group の `continuity.v1` を消す」と「`Snapshot` に `isSignedIn` を足す形が小さい」、設計 §2 A3
- 問題: キーを消すと印を置く場所が無い。また `Snapshot` に必須の `isSignedIn` を足すと、既存の保存（`Continuity.swift:79-82` の形）の decode が失敗して nil（「目標を設定」の表示）になる
- 直し方: (a) 別キー（例 `auth.signedIn.v1` の Bool）を持ち、サインアウトで `continuity.v1` を消し Bool を false にする。ウィジェットは Bool が false なら「アプリでサインインしてください」、true で snapshot 無しなら今の文言。`Snapshot` は変えない。または (b) `Snapshot` に `isSignedIn` を足し、サインアウトでは消さず `Snapshot(trainingDays: [], goals: [], isSignedIn: false)` を書く。足すなら decode に既定値（`decodeIfPresent ?? true`）を持たせる。(a) の方が互換の心配が無い

### P9（中・AI）期限切れ＋更新失敗のときの 42501 は「サインインし直してください」ではない
- 場所: §2-5「42501 を『サインインし直してください』に」、設計 §7 のエラーの文言
- 【事実・§0-3】期限切れのセッションの更新がネットワークの失敗で落ちた直後は、`SupabaseClient` が Authorization を付けずに既定ヘッダの anon キーで送るので、データの呼び出しは 42501 になる。このときセッションは端末に残り `.signedOut` も来ない（来るのは `session_not_found` 等のときだけ）
- 直し方: 42501 を受けたら `auth.currentSession` が nil でなければ「確認できませんでした。もう一度お試しください」とし、`refreshSession()` を 1 回試す。サインインの画面へ戻すのは `.signedOut` だけ（計画 §2-1 の方針どおり）。`currentSession` が nil のときだけ「サインインし直してください」

### P10（中・AI）UI テストの起動は 3 か所
- 【事実】`LifeTrackerUITests.swift:29`（`testExample`）、`:38`（`testLaunchPerformance` の `measure` の中で `XCUIApplication().launch()` を作り直している）、`LifeTrackerUITestsLaunchTests.swift:22`（`testLaunch`。`runsForEachTargetApplicationUIConfiguration`）。計画の「既存の 2 つ」では LaunchTests と `measure` の中が引数なしのまま本物のクライアントを作る（サインイン画面で止まるので DB は読まないが「一切つながない」に反する）。3 か所とも `launchArguments` を渡す

### P19（中・AI）URL の受け取りは `handle(url)` でなく `session(from:)` で失敗を画面に出す
- 【事実】`AuthClient.handle(_:)` は `Task` の中で `session(from:)` を呼び、失敗はログに流すだけ（`AuthClient.swift:823-831`）。別の端末で踏んだ（verifier が無い）・使い切り・`code` 無しのとき、画面に何も出ない
- 直し方: `onOpenURL` で `lifetracker://` は `try await supabase.auth.session(from: url)` を呼び、失敗を「このメールをこの iPhone で開いてください」「リンクが無効です。もう一度送ってください」に出す。Google の URL は `GIDSignIn.sharedInstance.handle(url)` のまま

### P20（低・AI）nonce の細部
- raw は 32 バイト程度の乱数（`SecRandomCopyBytes` または `UUID` 2 つ）。GSI に渡すのは `SHA256(raw)` の**小文字 hex**（GoTrue は `fmt.Sprintf("%x", …)` と比べる）。Swift の呼び名は `signIn(withPresenting:hint:additionalScopes:nonce:)`（9.0.0〜。10.0.0 は iOS 15 以上で可）。`-ObjC` は Google の公式手順に無い（§0-3）。`signInWithIdToken` の `accessToken` も今の手順どおり渡す

### 問題なし
- **`emitLocalSessionAsInitialSession: true`**: 計画の記述は手元のソースと一致（§0-3）。`false` のままだと実行時に `reportIssue` の警告が毎回出るので、`true` にする判断は正しい。「期限切れでもサインイン済みとして出し、更新はクライアントに任せ、`.signedOut` が来たときだけ戻す」は supabase-swift の挙動に合う
- **`.id(uid)` での作り直し**: `@StateObject` は `HomeView.swift:16`・`SleepView.swift:8`・`WorkoutView.swift:6-13` にあり、`static let shared` のような作り直しを免れる持ち物は無い（grep 0 件）。`ClockTick` は App にあり共有でよい
- **テストで本番につながない切り替え**: 単体テストは TEST_HOST のアプリに `XCTestConfigurationFilePath` が渡るので `makeDataSource` の分岐でよい【推測・XCTest の一般の挙動。計画 §2-7 の単体テストで確かめる】。UI テストは起動引数（P10）
- **PostgREST の upsert**: 実測で通る（§0-2）。`ProfileRow` から `id` を消し `onConflict: "user_id"`、体重は `"user_id,recorded_on"`、週の目標は `"user_id,effective_from"` でよい。`training_goal` の `id` 列は残してよい（衝突先は UNIQUE (user_id, effective_from)）
- **Google の nonce の流れ**: §1 の表のとおり成立する
- **新規登録 OFF と Google**: 同じ確認済みメールなら 1 人にまとまる（§0-3・事実）。§2-8 3 の「同じ UID になる」は U3 で新規登録を閉じた後でも通る

---

## 6. 【推測】の検証結果（依頼 6）

| 計画の【推測】 | 結果 | 根拠 |
|---|---|---|
| GoogleSignIn-iOS の Swift の公開 API に nonce の引数がある（§2-3） | **事実**。9.0.0 で追加。`signIn(withPresenting:hint:additionalScopes:nonce:)`。そのまま AppAuth へ渡す（ハッシュしない）。未指定なら AppAuth が乱数を作る | §0-3 |
| Supabase の照合が通る（§2-3） | **事実**。`hex(sha256(request.nonce)) == id_token.nonce`。raw を Supabase に、`sha256(raw)` の hex を Google に | §0-3 |
| MCP の `execute_sql` で `SET LOCAL ROLE authenticated` が使える（§3-2 5） | **事実**。`set_config('request.jwt.claims', …, true)` と `auth.uid()` も効く | §0-1 |
| `postgres:17` の image に `plpgsql_check` が apt で入る（§1-1） | **事実**。`postgresql-17-plpgsql-check` 2.10.13。関数の `SET search_path=''` を尊重して未修飾を見つける。`SET CONSTRAINTS` は見ない | §0-2 |
| Supabase の既定の権限の正確な形（§1-3） | **事実**（§0-1 の表）。ただし PUBLIC の `=X` は `pg_default_acl` に無く、スキーマ単位の REVOKE では消えない → P1 |
| `emitLocalSessionAsInitialSession: true` の挙動（§2-1） | **事実**。期限切れでも流れ、裏で更新し、更新の失敗ではサインアウトしない | §0-3 |
| `apply_migration` が 1 つのトランザクション（0-3） | **未確認のまま**（閉じた実装）。probe は妥当。P5 の備えを足す | — |
| 0013 の前提「旧列を読むビルドはもう無い」（§1-2） | 【推測のまま】Apple の無料署名の 7 日の期限として知られている。旧列は Swift のどこからも読まれていない（grep 0 件）ので、前提が崩れても壊れるのは「0006 より前のビルド」だけ | — |
| 新規登録を閉じても本人の Google は同じ UID になる（§2-8 3） | **事実**。`DisableSignup` は新規作成の分岐だけ。新しい Google アカウントの初回は止まる（設計 §8 の推測も事実） | §0-3 |
| メールのリンク → Safari → アプリ（設計 §7） | **未確認**（実機）。ただし PKCE の転送先に `type` は付かない → P2 | §0-3 |

---

## 7. 作業の分担と順（依頼 7）

### P21（低・AI）DB とアプリの並行は `CLAUDE.md` の「1 件ずつ直列」に反する
- 場所: 「順 2〜7（DB）と順 8〜9（アプリ）は別のファイルなので並べて進められる」
- `CLAUDE.md` の S 級の決まり 3「1 件ずつ直列で進める (並列 Wave に投げない)」。DB も認証の層も S 級。しかもアプリの 2-5 は 0014 の最終の名前（`exercise_for_user`・`ensure_user_defaults`・衝突先）に依存し、2-8 3 は U3 待ち。DB を先に（2〜7）、次にアプリ（8〜9）の直列でよい。並行にしたいなら本人に例外を一言（新しい方針なので）

### P22（低・AI）順 7 の deep-task レビューに認証の層を足す
- 1-6 は SQL だけが対象。2-1〜2-4（nonce・PKCE の印・テストの切り替え・URL の受け取り）は本番に効く守りなので、順 9 の後に同じ deep-task で見る（1 回で両方でもよい）

### P23（低・AI）順 4・5 の分け方
- 0014 は 1 ファイルで、l（関数）が m（権限）より前に要る（`ensure_user_defaults` の ACL を m で外すため。P6 で既定の権限を先に動かしても、`CREATE OR REPLACE` は既存の ACL を保つので m の `ALL FUNCTIONS` は要る）。順 4 のサブエージェントに「l の場所を空けて `-- l: 関数（順 5）` と印を置く」よう指示し、順 5 がそこに入れる。docker の `run.sh` は順 4 の時点でも流し、途中まで通ることを見る

### P24（低・運用）UID の扱い
- 置き換え後の SQL は MCP の呼び出し（会話のログ）と本番の `schema_migrations.statements` に残る。repo には残らない。0-2 の「会話の要約には書かない」は、要約（memory・daily）に書かないという意味で守れる。memory に「UID は本番の migration の記録にも入っている」と 1 行書いておくと、後で `list_migrations` を見た人が驚かない

### 問題なし
- 0-1 の commit の分け方、0-2、U1〜U6 の割り当て（P4 で U6 の時期だけ動かす）、段階 4 の一覧は妥当。段階 4 に P1（設計 §5・§9 の既定の権限の記述）・P2（設計 §7）・P8（設計 §2 A3）の設計側の修正を足す

---

## 確かめて問題なしだったもの（まとめ）

- `postgres` の権限（`REFERENCES auth.users`・`SET ROLE`・`ALTER DEFAULT PRIVILEGES FOR ROLE postgres`・v1 関数の所有者）は本番で確かめた。docker の `postgres` は superuser なのでこれらは docker では検出できないが、本番の読むだけの照会で代えた（§0-1）
- 18 本の外部キーの一覧、親 8 表の `UNIQUE (id, user_id)`、`workout_set`・`workout_entry` の持ち主の一致の論理（設計レビュー M30）は本番の `pg_constraint` と一致
- `auth.uid()` の定義は `request.jwt.claim.sub` と `request.jwt.claims` の両方を読む形（設計 §9 の stub と同じ）
- `exercise` の policy 4 つ・他の表 1 つ、`service_role` は BYPASSRLS で policy 不要
- `signOut()` の順（端末のセッションを消して `.signedOut` → `/logout`。401/403/404 は無視、ネットワークの失敗は投げる）は計画どおり。セッションが無いときは何もせず戻る（`.signedOut` も出ない）ので、サインアウトの UI は「結果に依らずサインイン画面へ」でよい
- 設計レビュー M3 の `SET CONSTRAINTS public.…` は実測で通る

---

## AI が直してよい点

P1・P2（印の案で実装。設計 §7 も直す）・P3・P4（U6 の時期を 0013 の直前に動かす。本人の操作の順が変わるので一言知らせる）・P5・P6・P7・P8（(a) 別キー）・P9・P10・P11・P12・P13・P14・P15・P16・P17・P18・P19・P20・P21（直列にする）・P22・P23・P24。設計側の修正（§1 の 19→18・§5 と §9 の既定の権限・§7 の `.passwordRecovery`・§2 A3）は段階 4 の一覧に足す。

## 本人に聞く点

無し。本人の選好・新しい方針に当たるものは見つからなかった。知らせるだけのもの: U6 の時期を 0013 の直前に動かす提案（P4）、再設定のリンクはアプリ側の印で画面を出し分ける（P2。リンクのままで変わらない）。

---

## 作業時間（JST）

- 2026-10-19 15:0x 開始（途中、利用制限で中断・15:2x 再開）
- 2026-10-19 15:4x このファイルを書いて終了
- 本番は読むだけ（`execute_sql` 9 回。件数・形・権限・定義だけ）。docker の container と network は消した。scratchpad の SQL・dump・JWT のスクリプトは `~/dev/life-tracker` の外にある
