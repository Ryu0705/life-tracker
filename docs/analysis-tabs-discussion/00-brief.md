# 分析画面の分け方 — 議論の前提（2026-10-10）

## 本人の依頼（原文）
> 正直かなり見づらい。
> 強さ、継続、トレーニングの中身（総ボリュームなど）は分けて表示するのがいいのでは？
> タブで分けていいとは思っているが、どのようにすべきか複数のサブエージェントで相談させて

## 現状
- トレーニングタブ右上の「分析」から push する 1 枚の List（`LifeTracker/LifeTracker/Sources/Views/Workout/WeekAnalysisView.swift`）。上から:
  1. 強さ（`BodyStrengthViews.swift`）: ‹ 30日期間 › ナビ、体重、人体図（前/後）、凡例、部位ごとのレベル行、心肺
  2. 継続（`ContinuityViews.swift`・`MonthHeatmapView.swift`）: 連続日数・今週の回数、ヒートマップ（1か月｜半年 の切替。1か月は ‹ 5週 › ナビ）
  3. 週ナビ ‹ 週 ›（`weekNavigation`）
  4. 総ボリューム（前週比・曜日×部位の棒グラフ）
  5. 本番セット数（部位別）
  6. 種目ごとの推移（一覧 → 種目詳細へ push）
- 期間の単位が 3 種類（強さ=30日、ヒートマップ=5週/26週、中身=1週）縦に並び、期間ナビも 2〜3 個積み上がっている（10/10 に本人が「見づらい」と指摘）
- スクショ（モック・iPhone 17）: `/private/tmp/claude-501/-Users-yamashitaryuunosuke-life/a784738c-f327-4bc1-bb2e-b5ebb374252e/scratchpad/analysis-tabs/a1.png`〜`a6.png`（上から順にスクロール）

## 守るべき本人の過去の指摘・決定（必ず読む）
- 期間だけ違う表示はタブにせず ‹ › ナビで中身だけ替える（本人 10/10）。memory `feedback_period_switch_navigator_not_tabs.md`、`docs/body-strength-and-heatmap-period.md`「期間の動かし方」
  - 今回本人が言う「タブ」は**見せ方・中身が違うもの（強さ／継続／中身）**の分割であり、上の原則とは矛盾しない。ただし境界の扱いは論点
- 分析は「3 つ目のタブにはしない」（WeekAnalysisView の冒頭コメント。経緯は docs/ 内を検索）
- 参考アプリの言及は採用ではない（memory `feedback_reference_app_is_not_adoption.md`）。UI 配置は参考アプリの実物で確認（`feedback_ui_placement_check_real_apps.md`）
- 推奨は UX/システム観点で評価（実装の楽さで選ばない）
- 関連 docs: `docs/continuity-design.md`、`docs/body-strength-and-heatmap-period.md`、`docs/gymwork-alignment-design.md`、`docs/spec.md`、`docs/structural-conventions.md`

## 制約
- Strength Level 由来の数値はアプリ内のみ。外部に出さない
- 実装・commit はしない。読むのと、レポートを書くことだけ
- シミュレータは親が使うので触らない（スクショは上を見る）
