# サインインと複数人化の棚卸し（2026-10-19）

`auth-multiuser-design.md` の「進め方 1. 棚卸し」の成果物です。設計の判断はしていません。今の作りの事実の一覧と、直すときに引っかかりそうな点だけを書いています。

- 調べ方: migration 0001〜0012・Swift（`LifeTracker/` 以下）・docs を読みました。本番は MCP の読むだけの操作（`list_tables`・`list_migrations`・`get_advisors`・`list_edge_functions`、SQL は SELECT だけ）で確かめました。DB にもファイルにも変更はしていません（このファイルを書いただけ）
- 本番で読んだのは件数・制約・関数の定義などの形だけです。記録の中身は読んでいません。種目は seed の名前と一致する件数だけを数えました
- 【事実】は、ファイルか SQL で確かめたことです。【推測】は見立てです。印のない表の行はすべて【事実】です
- 秘密の値（anon キー・URL・メールアドレス）は書いていません。Bundle ID・App Group の ID・チーム ID も、`CLAUDE.md` の方針に合わせて書いていません

---

## 要約

| 項目 | 数 |
|---|---|
| 表（public） | **21**。RLS は全部無効、`user_id` 列は 0、policy は 0 |
| view | 1（`workout_training_day`。所有者の権限で動く） |
| 関数 | repo の migration で定義したものが **28**（public 22・private 6）。本番にはこのほかに v1 の残りが public に 6 つあり、計 34。アプリが呼ぶのは 19 |
| 1 人を前提にした形（★） | **15**: DB の制約・view が 9、初期データ・関数の前提が 3、アプリ側が 3（→ §1-2・§1-5・§2-6） |
| 本番の行数 | 計 365 行（うち種目の seed 159・休日パターン 1） |
| 本番の Auth | `auth.users` が 2 件（v1 の時期に作られたもの。下の重い点 4） |

### 特に重い点（5 つ）

1. **全体で一意の制約が 8 つある**【事実】（日付・名前・`id = 1`・「進行中は 1 件」・「睡眠の時間が重ならない」）。【推測】複数人になると、他の人の行とぶつかって保存が失敗します。相手の行は RLS で見えないので、画面ではなぜ失敗したかが分かりません。とくに睡眠の重なりの禁止は、同じ夜に寝た 2 人がほぼ必ずぶつかります。同じことが、進行中のセッションが全体で 1 件という制約（誰かが記録中だと、他の人が記録を始められない）にも言えます
2. **全体で 1 件ある前提の初期データが 3 種類ある**【事実】
   - 休日パターン（`schedule_holiday_pattern_id()` と DayBuilder が「全体で 1 件」を前提にしている）
   - gym と sleep の種類（`category`）。migration には無く、アプリにも作る手段が無いのに、本番に 1 件ずつある
   - 種目のマスタ 159 件（人ごとの設定にも読める列 `is_archived`・`note`・`sort_order` を持つ）

   【推測】新しい人は休日パターンも種類も無い状態で始まり、「祝日も出す」とジム・睡眠の結びつきが動きません
3. **関数はすべて SECURITY INVOKER なので RLS はそのまま効く。ただし関数の中の INSERT が 10 関数・17 か所ある**【事実】。【推測】そのすべてで `user_id` を埋める手段が要ります（列の既定値にするか、関数で入れるか）。ほかにも次の 3 つがあります
   - view は所有者の権限で動きます（advisor の ERROR）
   - 公開の RPC と private の関数を、anon が実行できます
   - アプリの upsert の衝突先 3 つ（`id`・`effective_from`・`recorded_on`）は、制約と一緒に変わります
4. **本番に v1 の残りがある**【事実】
   - 関数が 6 つ。うち `fn_resolve_month_patterns` は SECURITY DEFINER で、anon から呼べます。中身は、もう無い v1 の表と `auth.uid()` を参照しています
   - `auth.users` が 2 件あります（provider はメールだけ、2 件とも確認済み、作成と最後のサインインはともに 2026-04）

   【推測】今のデータをどのユーザーに付け替えるか、v1 のユーザーを残すか消すかを、先に決める必要があります
5. **アプリにサインインの入口が無い**【事実】
   - `SupabaseClient` は起動時に 1 回、anon キーで作るだけです。認証の設定もセッションの扱いも無く、確認メールと Google から戻るための URL スキームもありません
   - データはメモリ上の各 store に持ち、ウィジェットは App Group の UserDefaults の 1 つのキーに直前のデータを持ちます

   【推測】サインアウトや別の人での入り直しのとき、前の人のデータが画面とウィジェットに残ります

---

## 1. DB

### 1-0 本番と migration の突き合わせ

| 項目 | 本番の今の姿【事実】 |
|---|---|
| migration の履歴 | v2 の 0001〜0012 は 12 本とも適用済み（最後は `v2_untimed_tasks`・20261015034314）。その前に v1 の 11 本（2026-04-14〜04-25）と `v1_drop_all_public_tables` がある |
| 表・列・制約・索引 | migration から作られるはずの形と一致した（違いは見つからなかった） |
| v1 の残り | public に関数が 6 つ（§1-4 の末尾）。表・トリガーは残っていない |
| RLS・policy | 21 表とも RLS 無効。policy は 0 |
| 表の権限 | 21 表と view のすべてで、anon と authenticated が SELECT・INSERT・UPDATE・DELETE・TRUNCATE・REFERENCES・TRIGGER を持つ（Supabase の既定。migration は GRANT を書かない方針: 0009:50・0012:50） |
| そのほか | トリガー 0、Realtime の publication 0、Storage のバケット 0、Edge Function 0、enum は `apply_day_enum` が 1 つ。repo の `supabase/` には `migrations/` しか無い（config.toml なし） |
| Auth | `auth.users` が 2 件。provider は email だけ、2 件とも確認済み、作成は 2026-04、最後のサインインも 2026-04（件数と月だけを数えた。中身は読んでいない） |
| advisor（security） | RLS 無効 21（ERROR）、SECURITY DEFINER の view 1（ERROR）、search_path 未設定の関数 28（WARN）、anon・authenticated が実行できる SECURITY DEFINER の関数 1（WARN）、漏えいしたパスワードの検査が無効（WARN） |

### 1-1 表（21）

`!` は NOT NULL です。★ は 1 人を前提にした形（§1-2）です。

**予定・実績（11 表）**

| 表 | 列 | 主キー | 一意 | 外部キー → 親（削除のとき） | 本番の行数 |
|---|---|---|---|---|---|
| category | id, name!, sub_input_kind | id | — | — | 4 |
| pattern | id, name!, apply_day（enum。NULL = 手動で当てる用） | id | ★ apply_day（部分 UNIQUE。NULL を除く） | — | 1 |
| task_template | id, name!, category_id!, start_minutes_from_midnight, duration_minutes, rrule（中身の列は旧ビルド向けの写し。0013 で消す予定: 0006:7-9） | id | — | category（RESTRICT） | 4 |
| task_template_version | id, template_id!, effective_from!, is_ended!, name!, category_id!, start_minutes_from_midnight, duration_minutes, rrule, created_at!, target_count!, carry_over! | id | (template_id, effective_from) | task_template（CASCADE）、category（RESTRICT） | 7 |
| task_template_exdate | template_id!, date! | (template_id, date) | — | task_template（CASCADE） | 0 |
| pattern_template_membership（旧。0013 で消す予定） | pattern_id!, template_id! | (pattern_id, template_id) | — | pattern・task_template（CASCADE） | 1 |
| pattern_version_membership | pattern_id!, version_id! | (pattern_id, version_id) | — | pattern・task_template_version（CASCADE） | 4 |
| scheduled_task | id, name!, category_id!, start_at, end_at, template_id, pattern_id, occurrence_date!, target_count!, created_at! | id | (template_id, occurrence_date)（部分 UNIQUE） | category・task_template・pattern（RESTRICT） | 1 |
| actual_task | id, name!, category_id!, start_at, end_at, status!, template_id, occurrence_date!, scheduled_task_id, skipped_on | id | (template_id, occurrence_date)・(scheduled_task_id)（部分 UNIQUE） | category（RESTRICT）、task_template・scheduled_task（SET NULL） | 2 |
| actual_task_tap | id, actual_task_id!, tapped_at! | id | — | actual_task（CASCADE） | 1 |
| day_meta | date!, applied_pattern_id | ★ date | — | pattern（RESTRICT） | 0 |

**トレーニング（7 表）**

| 表 | 列 | 主キー | 一意 | 外部キー → 親（削除のとき） | 本番の行数 |
|---|---|---|---|---|---|
| exercise | id, name!, muscle_group!, equipment, metric_kind!, note, is_archived!, sort_order | id | ★ name | — | 159 |
| routine | id, name!, note, is_archived!, sort_order | id | — | — | 3 |
| routine_exercise | routine_id!, exercise_id!, sort_order!, target_sets, target_reps, target_weight | (routine_id, sort_order) | — | routine（CASCADE）、exercise（RESTRICT） | 11 |
| workout_session | id, actual_task_id, routine_id, started_at!, ended_at, note | id | actual_task_id・★「ended_at IS NULL」（進行中は 1 件） | actual_task・routine（SET NULL） | 11（うち進行中 1） |
| workout_entry | id, session_id!, exercise_id!, sort_order! | id | (session_id, sort_order) DEFERRABLE・(id, exercise_id) | workout_session（CASCADE）、exercise（RESTRICT） | 33 |
| workout_set | id, session_id!, exercise_id!, set_index!, weight, reps, duration_sec, distance_m, rpe, is_warmup!, completed_at, entry_id! | id | (entry_id, set_index) DEFERRABLE | workout_session（CASCADE）、exercise（RESTRICT）、(entry_id, exercise_id) → workout_entry（NO ACTION） | 110 |
| training_goal | id, weekly_target!, effective_from!, created_at! | id | ★ effective_from | — | 1 |

**睡眠・体（3 表）**

| 表 | 列 | 主キー | 一意 | 外部キー | 本番の行数 |
|---|---|---|---|---|---|
| sleep_record | id, start_at!, end_at!, kind!, created_at! | id | ★ EXCLUDE（時間の重なりの禁止） | — | 9 |
| user_profile | id!（SMALLINT・既定 1）, sex!, birth_date!, created_at! | ★ id（CHECK id = 1） | — | — | 1 |
| body_weight_record | recorded_on!, weight_kg!, created_at! | ★ recorded_on | — | — | 2 |

**CHECK**

| 表 | CHECK |
|---|---|
| category | sub_input_kind は gym・sleep か NULL |
| task_template | 開始 0〜1439 分、長さ 1〜1440 分 |
| task_template_version | 同上 ／ 開始と長さは両方あるか両方 NULL ／ 目標 1〜99 ／ 繰り越しは時刻なしだけ ／ 終了の世代は rrule が NULL |
| scheduled_task | end > start（0001 の無名）／ pattern_id があれば template_id もある ／ 目標 1〜99 ／ 時刻ありなら occurrence_date = 開始の JST の日（`'Asia/Tokyo'` 固定） |
| actual_task | status は done・skipped ／ 時刻の組（done は両方ありで end > start か両方 NULL、skipped は NULL）／ template_id と scheduled_task_id の両方は持たない ／ skipped はつながりが要る ／ skipped_on は skipped のときだけ |
| exercise | muscle_group・equipment・metric_kind は決まった値だけ |
| routine_exercise | 目標のセット数・回数 > 0、重量 ≥ 0 |
| workout_session | ended > started |
| workout_entry | sort_order > 0 |
| workout_set | set_index > 0、weight ≥ 0、reps > 0、duration > 0、distance ≥ 0、rpe 1〜10 |
| training_goal | 週の目標 1〜7、effective_from は月曜 |
| sleep_record | end > start、24 時間以内、kind は sleep・nap |
| user_profile | ★ id = 1、sex は male・female |
| body_weight_record | 20〜300 kg |

**索引（一意でないもの）**: actual_task(occurrence_date)、actual_task_tap(actual_task_id, tapped_at)、exercise(muscle_group)（アーカイブを除く）、pattern_version_membership(version_id)、routine_exercise(exercise_id)、scheduled_task(occurrence_date)、sleep_record(end_at)、workout_entry(session_id)、workout_session(started_at DESC)、workout_set(entry_id)・(exercise_id)・(session_id)。
【推測】user_id を足すなら、RLS の式で絞る列の索引も要ります。今の索引に user_id を含むものはありません。

### 1-2 ★ DB の 1 人前提の形（9）

| # | 形 | 場所 | 複数人で起きること【推測】 |
|---|---|---|---|
| D1 | `user_profile` は 1 行だけ（主キー id の既定 1、CHECK id = 1） | 0011:17-24（CHECK は 22） | 2 人目のプロフィールが保存できない |
| D2 | `body_weight_record` は日付だけで一意（主キー recorded_on） | 0011:30 | 他の人と同じ日の体重がぶつかる |
| D3 | `day_meta` は日付だけで一意（主キー date） | 0001:120 | 他の人と同じ日の「その日のパターン」がぶつかる |
| D4 | `training_goal` は週の頭の日だけで一意 | 0005:12 | 他の人と同じ週の目標がぶつかる |
| D5 | 進行中のセッションは全体で 1 件（`workout_session_single_in_progress`） | 0003:92-93 | 誰かが記録中だと、他の人が記録を始められない |
| D6 | 睡眠の時間の重なりを全体で禁止（`sleep_record_no_overlap`） | 0009:28 | 同じ時間帯に寝た 2 人目が保存できない。人ごとにするには `user_id WITH =` を足す。btree_gist の拡張が要る見込み（本番の拡張の一覧は見ていない） |
| D7 | 種目は名前だけで一意（`exercise_name_unique`） | 0003:38 | 人ごとに種目を持つと、同じ名前を 2 人が作れない |
| D8 | 曜日・祝日ごとにパターンは全体で 1 件（`pattern_apply_day_unique`） | 0001:39-40 | 人ごとに休日パターンを持つと、2 人目の分が作れない |
| D9 | view `workout_training_day` が全員の行を DISTINCT で返す。所有者の権限で動く | 0005:21-24 | RLS が効かず、全員のトレーニングした日が混ざって返る。`security_invoker = true` が要る（`auth-multiuser-design.md:18`） |

【推測】一意の制約は、RLS で見えない行にも効きます。全体で一意のまま残すと、ぶつかったエラー（23505・23P01）から「他の人が同じ日に記録している」ことが漏れます。

### 1-3 view

| 名前 | 定義 | 権限 | 読む所 |
|---|---|---|---|
| workout_training_day | `SELECT DISTINCT (completed_at AT TIME ZONE 'Asia/Tokyo')::date AS day FROM workout_set WHERE completed_at IS NOT NULL` | 所有者 postgres。`security_invoker` の設定なし。anon・authenticated に全権限 | `SupabaseWorkoutDataSource.swift:243`（→ ContinuityStore → ウィジェット） |

### 1-4 関数（RPC）

【事実】の共通点:
- 28 個すべて SECURITY INVOKER で、所有者は postgres です。search_path は設定していません（advisor の WARN 28 件）
- 公開の関数（public）: PUBLIC（Postgres の既定）・anon・authenticated・service_role に EXECUTE があります（0006:304-316、0007:308-318、0008:62、0010:132-133、0012:842-858）
- `private`: PUBLIC からは外してあり、anon と authenticated にだけ EXECUTE と schema の USAGE があります（0012:129-130、862-877）。PostgREST の公開の schema に入っていないので、API からは呼べません（0012:124-127 の注記）
- 0012:125-127 の注記: 中から呼ばれる関数にも、呼んだ人の EXECUTE が要る（REVOKE だけで閉じると permission denied になった）

| 関数 | 最新の定義 | アプリから | 読む表 | 書く表（INSERT のあるものに ●） |
|---|---|---|---|---|
| jst_today() | 0006:80 | — | —（`'Asia/Tokyo'` 固定） | — |
| schedule_assert_editable | 0006:84 | — | — | — |
| schedule_holiday_pattern_id() | 0006:94 | — | pattern（apply_day = 'Holiday' の 1 件を前提） | — |
| schedule_single_save | 0012:275 | ○ | scheduled_task, actual_task | ● scheduled_task、actual_task（UPDATE） |
| schedule_single_delete | 0012:306 | ○ | scheduled_task, actual_task | scheduled_task・actual_task（DELETE） |
| schedule_template_create | 0012:319 | ○ | pattern, actual_task | ● task_template, task_template_version, pattern_version_membership |
| schedule_template_save_following | 0012:363 | ○ | task_template_version, scheduled_task | ● task_template_version, pattern_version_membership |
| schedule_template_delete_following | 0012:406 | ○ | task_template_version | ● task_template_version（ON CONFLICT）、DELETE が多数 |
| schedule_template_end_to_single | 0012:441 | ○ | （single_save・delete_following を呼ぶ） | actual_task（UPDATE） |
| schedule_occurrence_save | 0012:460 | ○ | task_template_version | ● scheduled_task |
| schedule_occurrence_delete | 0012:500 | ○ | （private を呼ぶ） | ● task_template_exdate（ON CONFLICT DO NOTHING） |
| checkin_set | 0012:521 | ○ | scheduled_task, category | ● actual_task（ON CONFLICT）, actual_task_tap |
| checkin_clear | 0012:581 | ○ | — | actual_task（DELETE） |
| actual_save | 0007:140 | ○ | category | ● actual_task |
| actual_delete | 0007:173 | ○ | — | actual_task（DELETE） |
| record_tap_add | 0012:627 | ○ | actual_task_tap, category, actual_task | ● actual_task, actual_task_tap（ON CONFLICT id） |
| record_tap_remove | 0012:675 | ○ | actual_task, actual_task_tap | DELETE |
| record_skip_set | 0012:707 | ○ | category | ● actual_task（ON CONFLICT） |
| record_skip_clear | 0012:744 | ○ | actual_task, actual_task_tap | UPDATE・DELETE |
| todo_fetch | 0012:777 | ○ | scheduled_task, actual_task, actual_task_tap, task_template_version, task_template_exdate, day_meta | —（読むだけ） |
| workout_set_delete | 0010:78 | ○ | workout_set, workout_entry | DELETE・UPDATE（遅延の制約） |
| workout_entry_reorder | 0010:112 | ○ | workout_entry | UPDATE |
| private.todo_occurrence | 0012:136 | — | scheduled_task, task_template_version | — |
| private.todo_target | 0012:176 | — | （todo_occurrence） | — |
| private.todo_closed_on | 0012:183 | — | actual_task, actual_task_tap | — |
| private.schedule_assert_single_editable | 0012:208 | — | scheduled_task, actual_task | — |
| private.todo_is_open_carried | 0012:249 | — | task_template_version, actual_task | — |
| private.record_occurrence_checked | 0012:598 | — | （todo_occurrence） | — |

- INSERT は 10 関数・17 か所です（0012:291, 334, 337, 342, 384, 391, 425, 491, 507, 558, 566, 575, 663, 668, 725, 732、0007:156）。どれも user_id を入れていません（表に列が無いため）
- 関数の中の ON CONFLICT の対象は、どれも親の UUID を含むキーです: (template_id, occurrence_date)、(scheduled_task_id)、(template_id, effective_from)、exdate の主キー、tap の id。【推測】親が本人のものなら、キーはそのままで人をまたいでぶつかりません
- 0012:266-268 の注記: 引数が変わる関数は、古いシグネチャを DROP してから作る。重ねて残すと PostgREST が 1 つに決められない（PGRST203）。【推測】引数に人を足す設計にすると、19 個の RPC すべてと Swift の `ScheduleRPC` が対象になります
- 0007:8-9 の注記: `apply_migration` が 1 トランザクションで流れるかは未確認

**本番にある v1 の残り（repo の migration には無い）**

| 関数 | 種類 | 中身 |
|---|---|---|
| fn_resolve_month_patterns(p_year, p_month) | **SECURITY DEFINER**、search_path=public、anon・authenticated が実行できる | もう無い `schedule_patterns` 表を `user_id = auth.uid()` で読む |
| sync_did_gym_on_insert / on_delete | トリガーの関数（トリガー本体は 0） | もう無い `daily_logs`・`workout_sets` を更新する |
| sync_did_study_on_insert / on_delete | 同上 | もう無い `daily_logs`・`study_logs` を更新する |
| update_updated_at | 同上 | `NEW.updated_at = now()` |

### 1-5 初期データ（seed に当たるもの）

| 表 | 本番の件数 | 出どころ | 人が足した行と区別できるか |
|---|---|---|---|
| exercise | 159 | 0004（159 行、`ON CONFLICT (name) DO NOTHING`） | 本番の 159 件はすべて seed の名前と一致した。アーカイブ 0、メモ 0、sort_order が空のもの 0。**区別する列（作った人・seed の印）は無い**ので、名前で照らすしかない。アプリは exercise を読むだけで書かない（`SupabaseWorkoutDataSource.swift:12`）。docs では、種目の自作は MCP で直接登録する扱い（`gymwork-alignment-design.md:329`） |
| pattern | 1（休日） | 0006:50-52（無ければ入れる） | apply_day = 'Holiday' で区別できる。アプリは pattern を作らない（`domain-model.md:6`） |
| category | 4（gym 1・sleep 1・種類なし 2） | migration には無い。アプリの `createCategory` は name だけを入れる（`SupabaseDayDataSource.swift:188-200`） | 区別する列は無い。【推測】gym・sleep の 2 件はアプリでは作れないので、SQL で直接入れたもの |
| task_template_version | 7 | 0006:59-63 で旧 task_template から写した（effective_from = 2026-04-26） | effective_from = 2026-04-26 の行が写しの候補（件数は数えていない） |
| アプリに同梱（DB の外） | — | `Resources/strength_mapping.json`・`strength_level_standards.json`（種目名で引く: `StrengthStandards.swift:83`）。種目の画像（種目名 → アセット名: `ExerciseImageNames.swift`。未 commit） | — |

さらに 1 人前提の形として、次の 3 つを数えています。

| # | 形 | 場所 | 複数人で起きること【推測】 |
|---|---|---|---|
| F1 | 休日パターンは全体で 1 件ある前提 | 0006:47-52、0006:94-96、`DayBuilder.swift:300`、`ScheduleOperation.swift:154`、`domain-model.md:6` | pattern を人ごとにすると、新しい人には休日パターンが無い。`schedule_holiday_pattern_id()` が NULL を返し、「祝日も出す」の保存が NOT NULL で失敗する |
| F2 | gym・sleep の種類は 1 件ずつある前提 | `CheckIn.swift:310, 355, 361, 619`、`SleepStore.swift:127`、`ScheduleStore.swift:397`、関数の「sleep は sleep_record に」の検査（0012:550 ほか） | 新しい人には種類が無く、ジムの実績の自動判定と睡眠の行の結びつきが動かない |
| F3 | 種目は全員共通のマスタに見えるが、人ごとの設定に読める列を持つ | 0003:14-36（`is_archived`・`note`・`sort_order`） | 共有にすると、ある人のアーカイブ・メモが全員に効く。人ごとにすると、名前で引く強さの基準と画像が、名前を変えた種目や自作の種目で外れる |

---

## 2. Swift

### 2-1 Supabase を呼んでいる所（すべて）

Supabase を import しているのは、アプリ本体の `LifeTrackerApp.swift`・`SupabaseWorkoutDataSource.swift`・`SupabaseDayDataSource.swift`・`SleepRules.swift`（`PostgrestError` の文言の変換だけ）の 4 つと、テストの 2 つです。

**SupabaseWorkoutDataSource.swift**

| 行 | 表・RPC | 操作 | 絞り込み・onConflict・決め打ち |
|---|---|---|---|
| 12 | exercise | select | is_archived = false |
| 22 | routine | select | is_archived = false |
| 32, 42 | routine_exercise | select | routine_id ／ 全件（ページング） |
| 53, 61, 67 | routine | update ／ select（sort_order の最大）／ insert | 新しい sort_order = 全行の最大 + 1 |
| 74, 79 | routine_exercise | delete → insert | 全部消して 1..n で入れ直す |
| 87 | routine | update（is_archived） | id |
| 94 | workout_session | select | **ended_at IS NULL を limit 1（進行中は全体で 1 件の前提）** |
| 104, 113, 120 | workout_session | insert ／ update ／ delete | id |
| 127, 137, 146 | workout_set | select ／ insert ／ update | session_id ／ id |
| 157 | RPC workout_set_delete | — | p_id |
| 161, 176, 189, 198 | workout_entry | select ／ insert ／ delete | session_id（50 件ずつ）／ id |
| 206 | RPC workout_entry_reorder | — | p_session, p_entry_ids |
| 211, 222, 231 | workout_set | select | exercise_id ／ 全件の exercise_id ／ completed_at の範囲（どれもページング） |
| 243 | view workout_training_day | select | 全件 |
| 251, 260 | training_goal | select ／ **upsert `onConflict: "effective_from"`**（261） | — |
| 266, 275 | user_profile | select（limit 1）／ **upsert `ProfileRow(id: 1, …)` `onConflict: "id"`**（276） | **id = 1 の決め打ち** |
| 282, 289 | body_weight_record | select ／ **upsert `onConflict: "recorded_on"`**（290） | — |

**SupabaseDayDataSource.swift**

| 行 | 表・RPC | 操作 | 絞り込み |
|---|---|---|---|
| 33, 162 | task_template_version | select | 全件 |
| 38, 163 | pattern_version_membership | select | 全件 |
| 43, 161 | pattern | select | 全件（休日パターンは端末で `applyDay == .holiday` の最初の 1 件を使う） |
| 48 | task_template_exdate | select | date が当日・前日 |
| 54 | day_meta | select | date が当日・前日 |
| 62 | scheduled_task | select | 前日 0 時〜翌日 0 時に重なるもの |
| 70 | actual_task | select | occurrence_date が当日・前日 |
| 77 | workout_set | select（completed_at だけ） | その日に完了したもの |
| 139 | actual_task_tap | select | actual_task_id。**失敗したら空として扱う（136-147）** |
| 154 | RPC todo_fetch | — | p_date, p_from, p_count_from |
| 160 | category | select | 全件 |
| 172 | RPC（予定の 8 つ） | — | `ScheduleRPC.call(for: ScheduleOperation)`（360-379） |
| 182 | RPC（実績の 8 つ） | — | `ScheduleRPC.call(for: CheckInOperation)`（306-330） |
| 189 | category | insert | name だけ |
| 206, 216, 225, 232 | sleep_record | select ／ insert ／ update ／ delete | 時間の範囲 ／ id |

アプリが呼ぶ RPC は 19 個です: schedule_single_save、schedule_single_delete、schedule_template_create、schedule_template_save_following、schedule_template_delete_following、schedule_template_end_to_single、schedule_occurrence_save、schedule_occurrence_delete、checkin_set、checkin_clear、actual_save、actual_delete、record_tap_add、record_tap_remove、record_skip_set、record_skip_clear、todo_fetch、workout_set_delete、workout_entry_reorder。

書き込みで送る中身（`NewCategory`・`NewRoutine`・`NewRoutineExercise`・`NewWorkoutSession`・`NewWorkoutEntry`・`NewWorkoutSet`・`SleepRecordWrite`・`WeeklyGoalRow`・`ProfileRow`・`BodyWeightRecord`）は、どれも user_id を持っていません。

### 2-2 DataSource の protocol と実装の対応

| protocol（定義の場所） | Supabase | メモリ上（`-mock-*` の起動とテスト） | テストだけの作り物 |
|---|---|---|---|
| DayDataSource（`DayDataSource.swift:3`） | SupabaseDayDataSource | InMemoryScheduleDataSource（`-mock-day`）、MockDayDataSource（固定の context。Environment の既定値: `DayDataSourceEnvironment.swift:4`） | GatedCheckInSource、FailFirstCheckInSource |
| ScheduleDataSource（`ScheduleDataSource.swift:7`） | SupabaseDayDataSource の extension | InMemoryScheduleDataSource | GatedCheckInSource、FailFirstCheckInSource |
| TodoDataSource（`ScheduleDataSource.swift:16`） | 同上 | InMemoryScheduleDataSource | ThrowingTodoSource、GatedTodoSource、ToggleableTodoSource |
| SleepDataSource（`SleepDataSource.swift:6`） | 同上 | InMemoryScheduleDataSource | — |
| WorkoutDataSource（`WorkoutDataSource.swift:5`。プロフィールは「1 行・id = 1 の upsert」と注記: 61-64） | SupabaseWorkoutDataSource | MockWorkoutDataSource（`WorkoutFixtures.makeMockDataSource`。`-mock-workout`、`-mock-no-profile`、`-mock-fetch-delay`） | — |

- 切り替えは `LifeTrackerApp.swift:73-92` の `#if DEBUG` で、起動の引数を見て行います
- メモリ上の初期データ（`InMemoryScheduleDataSource.makeFixture`、709 行〜）は、睡眠と「ジム」の種類、休日パターンを 1 つずつ作ります（711-713）。`WorkoutFixtures` はプロフィールを 1 件入れます（98-99）
- メモリ上の実装には「誰のデータか」の考えがありません

### 2-3 SupabaseClient と anon キー

| 項目 | 事実 |
|---|---|
| 作る所 | `LifeTrackerApp.swift:56-62`。起動時に 1 回作り、4 つの data source で共有する（`AppDataSources`）。オプションは DB の encoder・decoder だけで、auth の設定は無い |
| URL とキーの読み込み | `SupabaseConfig.swift` が Info.plist の `SUPABASE_URL`・`SUPABASE_ANON_KEY` を読む。Info.plist は `$(SUPABASE_URL)`・`$(SUPABASE_ANON_KEY)` を `LifeTracker.xcconfig` から受ける（`Info.plist:25-28`。Debug・Release の両方が xcconfig を基にする: project.pbxproj:451, 516） |
| 秘密の扱い | `LifeTracker.xcconfig` は .gitignore 済み。git にあるのは `LifeTracker.xcconfig.example` だけ |
| 読めないとき | `ConfigErrorView` を出す（`LifeTrackerApp.swift:33-34`） |
| サインインのために今は無いもの | サインインの画面・セッションの扱い・URL スキーム（Info.plist に `CFBundleURLTypes` が無い）・`onOpenURL` |
| パッケージ | supabase-swift 2.44.1（Package.resolved）。アプリが使う product は `Supabase` で、Auth の部品も含む |

### 2-4 拡張（ウィジェット・Live Activity）

| 拡張 | DB を読むか | 事実 |
|---|---|---|
| ホーム画面のウィジェット（`RestTimerWidget/StreakWidget.swift`） | 読まない | アプリが App Group の UserDefaults のキー `continuity.v1` に書いたデータ（トレーニングした日・目標の履歴）を読む（`Shared/Continuity.swift:73-93`）。書くのは `ContinuityStore.share`（`ContinuityStore.swift:66-73`） |
| Live Activity（休憩タイマー） | 読まない | `RestActivityAttributes`（題名 = 種目名とセット）。`RestAlerts.swift` が開始・終了する |
| リンクする Supabase | 無し | Supabase パッケージをリンクしているのはアプリ本体だけ（project.pbxproj:189-192） |

### 2-5 テストのうち Supabase に関わるもの

本物の DB につなぐテストはありません。Supabase の形に関わるのは次のとおりです。

| ファイル:行 | 中身 |
|---|---|
| ScheduleStage1Tests.swift:555〜 | `ScheduleRPCTests`: 予定の操作 → 関数名と引数名 |
| ScheduleStage2Tests.swift:442, 458-477 | actual_task の JSON の読み込み、実績の操作 → RPC |
| UntimedTasksTests.swift:721-792, 1220, 1238, 1254 | 時刻なしの RPC と引数、todo_fetch の JSON、`RuleErrorMapping`（`PostgrestError` の文言とコード → 規則のエラー） |
| WorkoutTests.swift:208-225 | workout_set・workout_entry・exercise の JSON の読み込み |
| SleepRulesTests.swift:230-233 | `PostgrestError`（23P01・23514・42501）→ 画面の文言。42501（権限なし）はそのままの文言で出す |

単体テストの TEST_HOST はアプリ本体です（project.pbxproj:648）。UI テストは起動の引数なしで起動します（`LifeTrackerUITests.swift:29, 38`）。【推測】テストのたびにアプリが本番の DB に anon キーでつないで読みに行っていると考えられます。サインインを入れると、UI テストはサインインの画面で止まります。

### 2-6 アプリ側で引っかかりそうな点

★ はアプリ側の 1 人前提の形（3）です。

| # | 点 | 場所 | 【推測】 |
|---|---|---|---|
| ★A1 | クライアントを起動時に 1 回、anon キーで作るだけで、サインインの入口が無い | `LifeTrackerApp.swift:49-97` | サインインの状態で TabView を出し分ける所が要る。data source は今、起動時に作ったクライアントを抱えている |
| ★A2 | upsert の衝突先が 1 人前提のキー（`id` に 1 を決め打ち・`effective_from`・`recorded_on`） | `SupabaseWorkoutDataSource.swift:261, 276, 290` | DB の D1・D2・D4 と同時に変わる。`fetchProfile` の limit 1（266-270）と `fetchInProgressSession`（93-101）は、RLS で本人の行だけになれば今のままでも動く |
| ★A3 | ウィジェットへの受け渡しが App Group の 1 つのキーだけ | `Shared/Continuity.swift:75-93` | サインアウトしても前の人の連続週数が残る。消す処理が要る |
| A4 | 各 store がデータをメモリに持つ（WorkoutView の @StateObject: `WorkoutView.swift:8-13`、予定・睡眠の store も同じ） | Views・Services | 人が変わったら作り直す必要がある |
| A5 | タップの読み込みは失敗を空として扱う | `SupabaseDayDataSource.swift:136-147` | RLS の付け忘れも、権限のエラーも、空の画面に見える（`auth-multiuser-design.md:19` と同じ） |
| A6 | 外部キーの違反（23503）を、すべて「過去の予定から参照されている」に変える | `SupabaseDayDataSource.swift:396` | 持ち主の一致を複合の外部キーで守る形にすると、別の理由の 23503 も同じ文言で出る。権限のエラー（42501）は変換が無く、英語のまま出る |
| A7 | 日付と時刻は JST 固定 | `LifeTrackerApp.swift:52`、`DateOnly.swift:32`、`HomeView.swift:449`、`CurrentBlockCard.swift:32`、`DayDataSourceEnvironment.swift:17`（DB も `'Asia/Tokyo'` を CHECK・view・関数に持つ） | 1 人前提ではないが、日本の外の人は日がずれる |
| A8 | RPC の引数は名前で合わせている | `SupabaseDayDataSource.swift:290-380` | 関数の引数を変えると、Swift と DB を同時に変える必要がある（PGRST203。§1-4） |

---

## 3. docs にある 1 人前提の規則・不変条件

行番号はすべて Read か grep で確かめました。INV-1〜10 の原文は `gymwork-alignment-design.md:43` にあります（INV-6 は 2026-09-30 に廃止）。

### 3-1 DB の形に効いている規則

| ID・名前 | 要旨 | 場所 | 複数人で引っかかる点【推測】 |
|---|---|---|---|
| INV-2 | 1 日 = 1 セッションを記録から自動で作る。進行中は 1 件まで | gymwork-alignment-design.md:43、domain-model.md:253-255、0003:92 | D5。「前日の分を閉じる」も本人の分だけにする |
| プロフィール 1 行 | `user_profile` は id = 1 の 1 行 | body-strength-and-heatmap-period.md:99、0011:22 | D1 |
| 体重 1 日 1 件 | 主キー recorded_on、同じ日は上書き | body-strength-and-heatmap-period.md:100、0011:30 | D2 |
| day_meta | 日付が主キー。行があること = その日を操作した印 | domain-model.md:147-152、0001:120 | D3 |
| 1 値 = 1 pattern | 曜日・祝日の既定のパターンは 1 つずつ | domain-model.md:59-63, 457、0001:39 | D8 |
| 休日パターン 1 件 | 0006 で作り、アプリは作らない | domain-model.md:6、day-cycle-walkthrough.md:157, 209, 222 | F1 |
| 種目名の一意・seed | 159 種目を seed で入れる。強さの基準と画像は名前で引く | domain-model.md:213、training-domain-design.md:194、exercise-images-design.md:62, 127 | D7・F3 |
| 週の目標 | effective_from が一意（月曜） | continuity-design.md:28、0005:12 | D4 |
| 睡眠の重なりの禁止 | 全体で EXCLUDE。未来の時刻はアプリで検査（本人 1 人の入力なので十分） | sleep-design/synthesis.md:29, 142 | D6 |
| view | トレーニングした日は view で返す | continuity-design.md:29 | D9 |
| R-3 ほか | 種目の自作と過去日の記録忘れは、MCP で直接 INSERT する | gymwork-alignment-design.md:329, 342 | MCP は RLS を越えて書けるので、user_id を入れ忘れた行ができうる。他の人には使えない逃げ道 |

### 3-2 権限・認証

| 要旨 | 場所 | 引っかかる点【推測】 |
|---|---|---|
| RLS は全表で無効。表の権限は Supabase の既定（anon・authenticated に開く）に任せ、GRANT を書かない | domain-model.md:334、continuity-design.md:44、untimed-tasks-implementation-plan.md:220 | 既定の権限も変えないと、これから作る表がまた anon に開く |
| 本番適用の確認手順が「anon で読み書きできる」を期待値にしている | untimed-tasks-implementation-plan.md:219-225, 249、sleep-design/synthesis.md:413 | 複数人化の後は期待値が逆になる |
| 食事の設計の「user_id は無い（単一ユーザー）・各表に user_id は要らない」 | meal-weight-design.md:242 | 10-19 13:3x の決定（同 :186-191「食事の表は最初から user_id」）で上書き済みだが、:242 自体に注記が無い |
| AI の入口の守り（本人の UID だけ・上限は全体で 1 日あたり） | meal-weight-design.md:170, 319、meal-weight-review-2026-10-17.md:258-261 | 上限は人ごとにする必要がある |

### 3-3 方針として 1 人を前提にした記述

| 要旨 | 場所 | 引っかかる点【推測】 |
|---|---|---|
| 「個人用 iOS アプリ」「個人ツール」 | spec.md:3, 21、meal-weight-design.md:20 | 10-19 の「将来ほかの人にも使ってもらう」と食い違う（positioning.md には追記済み。spec.md には注記が無い） |
| 「汎用化はする（データ・設定可変、UI 自分向け）」ほか | spec.md:95-97、training-domain-design.md:36 | 同上 |
| オンボーディングは作らない（INV-9 の周り） | gymwork-alignment-design.md:10, 43, 326、continuity-design.md:23 | 新しい人は休日パターン・種類・目標が何も無い状態で始まる。食事の設計にはすでに「初回設定」がある（meal-weight-design.md:301） |
| INV-10: 本人が決めた値（刻み・休憩 3:00）を上書きしない | gymwork-alignment-design.md:43 | 定数なので、他の人の好みを置く場所が無い |
| 強さの基準の数字は「個人用アプリの中だけで使う・公開・再配布しない」（strengthlevel.com から写したもの） | body-strength-and-heatmap-period.md:25, 34、strength_mapping.json の note | 他の人に配ると、この前提を越える |
| 店の栄養表示は本人の DB にだけ置く（私的使用） | meal-weight-design.md:83, 380, 382 | 共有にすると、私的使用の前提が崩れる |
| ウィジェットは App Group の UserDefaults から計算する | continuity-design.md:39 | A3 |
| 日は JST 固定、週は月曜始まり（R-2） | domain-model.md:5, 26、gymwork-alignment-design.md:341 | A7 |
| 構造規約 D-4（予定と実績は緩くつなぐ。SET NULL）・D-5（DayBuilder は pure） | structural-conventions.md:220-249 | D-4: PostgreSQL の外部キーの検査は RLS を越えて行われる（一般的な仕様）。他の人の id を指す行が作れてしまう。D-5 への影響は小さい |

### 3-4 古くなっている記述（後の決定で上書きされたもの）

| 記述 | 上書きした決定 | 注記の有無 |
|---|---|---|
| 「RLS 無効」の各記述（domain-model.md:334、continuity-design.md:44 ほか） | 10-19 12:1x「全部の表に RLS」（meal-weight-design.md:171-174） | 各記述には無い |
| spec.md:3, 21, 95-97 の「個人ツール」 | 10-19 12:3x「将来ほかの人にも使ってもらう」 | spec.md には無い |
| domain-model.md:394「週の目標回数は DB に置かず UserDefaults」 | 0005 で `training_goal` を作った | 無い（domain-model.md に training_goal の記述が無い） |
| meal-weight-design.md:177 の推奨（TOTP・新規登録を閉じる） | :183 でメール＋パスワードと Google に決定。新規登録を開くかは未決 | — |

---

## 4. git（未 commit の変更のうち、この作業で触りそうなもの）

【事実】ブランチは `feat/round3-training` です（main ではない）。最後の commit は c142a88（2026-10-15）。未 commit は、変更 18・未追跡 17 です。中身は主に、連続日数を連続週数にした変更と、種目の画像です。

| ファイル | 状態 | 触りそうな理由【推測】 |
|---|---|---|
| `LifeTracker/Shared/Continuity.swift` | 変更 | ウィジェットへの受け渡し（A3）。サインアウトで消す処理 |
| `LifeTracker/LifeTracker/Sources/Services/ContinuityStore.swift` | 変更 | 同上（`share`） |
| `LifeTracker/RestTimerWidget/StreakWidget.swift` | 変更 | 同上（未サインインのときの表示） |
| `LifeTracker/LifeTrackerTests/ContinuityTests.swift` | 変更 | 同上のテスト |
| `LifeTracker/LifeTracker/Sources/Services/WorkoutDataSource.swift` | 変更（注記の 1 行） | protocol。プロフィールの「id = 1」の注記（61-64） |
| `LifeTracker/LifeTracker/Sources/Views/Workout/WorkoutView.swift` | 変更（注記の 2 行） | store を持つ所（A4） |
| `LifeTracker/LifeTracker/Sources/Views/Workout/ExerciseImageNames.swift`・`ExerciseImageViews.swift`・`LifeTrackerTests/ExerciseImageTests.swift` | 未追跡 | 種目名で画像を引く（F3。種目を人ごとにするかで影響） |
| `docs/spec.md`・`docs/continuity-design.md`・`docs/gymwork-alignment-design.md` | 変更 | 1 人前提の記述と INV がある（§3） |
| `docs/auth-multiuser-design.md`・`docs/meal-weight-design.md` | 未追跡 | 設計書そのもの、user_id の記述（:242） |
| `AGENTS.md` | 変更 | repo の作業ルール（memory の場所の書き換え） |

- 触りそうで、今は差分が無いもの: `LifeTrackerApp.swift`・`SupabaseWorkoutDataSource.swift`・`SupabaseDayDataSource.swift`・`SupabaseConfig.swift`・`Info.plist`・`supabase/migrations/`
- 見た目だけの変更（`BodyDiagramView`・`ExerciseDetailView`・`ExercisePickerView`・`MonthHeatmapView`・`TodayExerciseCard`・`WeekStripView`）は触らない見込みです
- 【推測】未 commit の 2 つの変更（連続週数・種目の画像）と、この作業の差分が同じファイル（Continuity・ContinuityStore・WorkoutView）で混ざりやすいです

---

## 作業時間（JST）

- 開始: 2026-10-19 13:38
- 終了: 2026-10-19 13:51
- docs（§3）の読み込みはサブエージェント（opus）に任せ、行番号を抜き取りで確かめてから載せました
