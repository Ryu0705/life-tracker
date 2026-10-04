# AGENTS.md

このリポジトリの作業ルールは `CLAUDE.md` に集約している (Claude Code 向けに書かれているが、Codex でも同じルールで作業する)。作業前に必ず読むこと。

- 進行中の作業: `docs/round-3-work-plan.md` (Round 3 トレーニング記録。前提・既定値・完了条件・進捗ログ)
- Claude 固有の記述の読み替え:
  - 「memory」: `~/.claude/projects/-Users-yamashitaryuunosuke-life/memory/`。Life Tracker の要点は `project_life_tracker_v2_core.md`
  - 「Agent 依頼」「サブエージェント」: Codex では自分で実装する。`docs/agent-delegation-template.md` の設計確定・親レビューのチェックリストはそのまま自己レビューに使う
  - `mcp__supabase-personal__*`: Supabase の personal プロジェクトへの接続。使えない場合は SQL をユーザーに渡して Dashboard の SQL Editor で実行してもらう
