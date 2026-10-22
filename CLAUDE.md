# Life Tracker - Claude Code 作業ルール

個人用 iOS アプリ。SwiftUI + Supabase + (Phase 2 以降) HealthKit。
2026-04-26 v1 廃止 → v2 として新規作り直し。v1 は `~/dev/life-tracker-archive/` 参照。

## 起動時に読むドキュメント
- `docs/spec.md` — v2 コア定義・スコープ・構造原則
- `docs/domain-model.md` — v15 ドメインモデル (DDL / 設計判断 / DayBuilder / Phase 2 持ち越し)
- `docs/structural-conventions.md` — 構造規約 (Agent 依頼前に必読)
- `docs/agent-delegation-template.md` — Agent 依頼時のプロンプトテンプレ

### Round 別の規約参照範囲
- **Round 1-2 (DDL + DayBuilder)**: `structural-conventions.md` の **D セクション** (D-4 / D-5) と **規約発火タイミング表** が主に発火。View 規約 (A / B / C-1〜C-8 / E) は未発火 — 親レビューで grep が 0 件 hit でも「規約準拠 OK」と誤判定しない
- **View 着手 Round 以降**: A / B / C / E 各規約を該当画面実装時に都度参照

## Agent 依頼時のルール
S級 (構造変更を伴う) タスクは以下を厳守:
1. 親が既存コードを Read し、擬似コード＋規約引用で設計確定してから投げる
2. プロンプトテンプレは `docs/agent-delegation-template.md` (S-DB 級 / S-Pure 級 / S-View 級のバリアントから選ぶ)
3. 1 件ずつ直列で進める (並列 Wave に投げない)
4. BUILD SUCCEEDED のみで満足せず、親が主要変更ファイルを Read + grep で構造規約違反を目視確認 (Round 別 grep は `structural-conventions.md` 末尾参照)
5. 実機確認はユーザーに明示依頼 (`agent-delegation-template.md` の「ユーザー実機確認依頼テンプレ」を使う)

B/C 級 (局所修正) は並列 Wave で可。同一ファイルの編集は直列化。

## BUILD / 検証
- BUILD: `xcodebuild -project LifeTracker.xcodeproj -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build`
- TEST (ユニットテストのみ): `xcodebuild test -project LifeTracker.xcodeproj -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -only-testing:LifeTrackerTests`
  - cwd は `LifeTracker/` (xcodeproj のあるディレクトリ)
  - `-only-testing:LifeTrackerTests` を付けないと UI Tests も走り 3 分弱かかる
- UI TEST: `-only-testing:LifeTrackerUITests -parallel-testing-enabled NO`（並列だと複製のシミュレータの runner が起動に失敗する。2026-10-21）。起動はコードで `-mock-day -mock-workout -mock-auth` を渡す（本番につながない）。サインインはメールのコード（モックは `123456`）で、パスワードを使わない（2026-10-22 から。前にあった「パスワードを保存しますか?」を位置で閉じる処理は外した）
- 日をまたぐ動き (トレーニングの日。前の日は 2:00 まで) は DEBUG の起動引数 `-mock-now 2026-10-23T00:30:00+09:00` で見る (`-mock-workout` と一緒のときだけ・トレーニングのタブの時計だけずれる。2026-10-23)
- Swift Testing の 1 件だけを流すときは `-only-testing:LifeTrackerTests/Suite/name()` と括弧まで書く (括弧が無いと 0 件のまま成功と出る)
- インストール: `xcrun simctl install booted <app>` (idb は arch 判定バグありのため install には使わない)
- UI 操作確認: idb は `screen` / `describe` / `tap` のみ使用可。詳細は memory `feedback_ios_app_verification_idb.md`

## 本番の migration（MCP apply_migration）
- 流す前に本番のバックアップ（本人の `pg_dump`）と、それを docker に戻したリハーサル（`supabase/test/run.sh --dump`）。流す直前に本人へ「確認の画面をすぐ承認」と伝える
- 新しい表・view・関数には GRANT と REVOKE を書き、新しい表には `user_id`（既定値 `auth.uid()`）・RLS・policy を付ける。付け忘れは `supabase/test/checks.sql` が止める（設計 `docs/auth-multiuser-design.md` §1・§5。2026-10-23 の 0014 から）
- MCP で行を入れるときは `user_id` を明示する。`exercise` は書かないと共有の種目になる（全員の一覧に出る）。共有の種目は migration で足す（0016）。UID は repo に書かない
- 確認の画面の承認が遅れると「Invalid or expired requestState」で返る。何も流れていない（1 つのトランザクション）ので、読むだけの SQL で記録・列が無いことを確かめてから流し直す（2026-10-23 0014 で実測）
- 流した後、本番に記録された SQL がファイルと同じかを md5 で確かめる: `SELECT md5(array_to_string(statements, '')) FROM supabase_migrations.schema_migrations WHERE name = '<名前>'` とファイルの `md5 -q`（1 回の呼び出しは 1 つの文で、そのまま記録される。UID を置き換えたファイルなら置き換えた後のもの）。手で写して渡すので、写し間違いをこれで見る（2026-10-23 0013・0014 で一致）
- 本番の checks.sql（execute_sql に読むだけの SELECT 1 つ）でも確認の画面が出ることがある。期限が切れたら流し直す（読むだけなので何も変わらない。2026-10-23 0015 の後で実測。同じときの短い SELECT では出なかった）

## SourceKit 診断エラー
Agent 実装直後の "Cannot find type/module in scope" は xcodebuild が通っていれば無視可 (IDE インデックスの一時エラー)。

## 秘匿情報・Round 運用
Supabase URL/key、Bundle ID、Round 進行、実装状況はグローバル memory 参照。本ファイルには書かない (git 管理のため)。
