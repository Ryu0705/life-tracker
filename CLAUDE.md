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
- BUILD: `xcodebuild -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17'`
- インストール: `xcrun simctl install booted <app>` (idb は arch 判定バグありのため install には使わない)
- UI 操作確認: idb は `screen` / `describe` / `tap` のみ使用可。詳細は memory `feedback_ios_app_verification_idb.md`

## SourceKit 診断エラー
Agent 実装直後の "Cannot find type/module in scope" は xcodebuild が通っていれば無視可 (IDE インデックスの一時エラー)。

## 秘匿情報・Round 運用
Supabase URL/key、Bundle ID、Round 進行、実装状況はグローバル memory 参照。本ファイルには書かない (git 管理のため)。
