# 段階 1（週帯＋繰り返しの予定の世代管理）設計レビュー — DB・データ・組み立て・migration

作成: 2026-09-30 / レビュー対象: `docs/day-cycle-walkthrough.md` の「段階 1 の設計」（2026-09-30 本人決定以降）/ 観点: DDL・データの持ち方・日の組み立て・既存コードとの整合・migration の安全性
レビュー方法: リポジトリのファイルだけで判断（DB には触れていない。読み取り SQL も実行していない）

## 0. 先に結論

- 世代管理（案2）そのものは成立する。とくに「除外日と『その日だけの変更』が系列の id を指したままでよい」点は、今の DayBuilder の実体優先ロジック（`templateId` で仮想を抑制）がそのまま使えるので、設計の強みとして本物。
- ただし **このまま実装に入るのは待ったほうがよい**。理由は次の 3 つ。
  1. 既存の DayBuilder と取得条件に、「前日の『その日だけの変更』が当日に重ならないと、前日の仮想の流入が消えない」穴がある（§3-1、重大度 高）。今は実体が 0 件なので出ていないが、段階 1 で「この予定」を作れるようになった瞬間に踏む
  2. 操作表に未定義の遷移が 3 つあり、そのままだと「編集したのに変わらない」「二重に出る」が起きる（§2-1〜2-3、重大度 高）
  3. 「これ以降」系は複数テーブルへの複数書き込みで、途中失敗すると「消したはずの予定が未来のある日に残る」状態になる。RPC（plpgsql 関数）にまとめ、同時に「D ≥ 今日」の検査を DB 側にも置くのがよい（§4、重大度 中だが設計の形を決めるので先に判断）
- migration は「追加 → アプリ切替 → 確認後に削除」の 2 本に分けると戻せる（§1-6）。

## 1. DDL 案の穴

### 1-1. 【中】「D に世代があれば書き換え」を PostgREST の upsert でやると主キーが書き換わる／FK エラーになる
- **何が起きるか**: 世代表の PK は `id`（uuid）、書き換えの単位は `UNIQUE (template_id, effective_from)`。PostgREST の upsert（`onConflict: "template_id,effective_from"`）は、payload に含まれる全列を `DO UPDATE SET 列 = EXCLUDED.列` で上書きする。クライアントが新しい `id` を入れて送ると、既存行の `id` を書き換えようとする。その世代に祝日の登録（`pattern_version_membership.version_id`）があれば FK 違反で失敗、無ければ黙って id が変わる（クライアントが持つ id と食い違う）
- **根拠**: 既存の書き方が `id` を含む全列 upsert（`SupabaseDayDataSource.swift:117-121` の `TemplateRow`、`SupabaseWorkoutDataSource.swift:202-206`）。同じ流儀で世代を書くと踏む
- **修正案**: 世代の書き込みを RPC にする（§4）。RPC にしないなら、upsert の payload から `id` を外す（`DEFAULT gen_random_uuid()` に任せる）か、`SELECT` で既存の id を取ってから `UPDATE`

### 1-2. 【中】「この予定」の実体は式インデックスが一意キーなので、upsert できない
- **何が起きるか**: 同じ系列・同じ日の実体は `scheduled_task_template_day_unique`（`template_id, (start_at AT TIME ZONE 'Asia/Tokyo')::date`）で 1 件に制限される（`0001_initial.sql:94-97`）。PostgREST の `on_conflict` は列名しか受け付けず、式インデックスは指定できない。「あれば書き換え」を素直に upsert では書けない
- **根拠**: `docs/day-cycle-walkthrough.md:125`「あれば書き換え」/ `0001_initial.sql:94`
- **修正案**: UI が「この行は実体か仮想か」を知っていれば `UPDATE ... WHERE id = ?` / `INSERT` に分けられる。ただし今の `DayScheduledTask`（`Day.swift:15-21`）に実体／仮想の区別がない（仮想の id は `UUID.virtual` のハッシュ、`DayBuilder.swift:217`）。`DayScheduledTask` に `isVirtual: Bool`（または `entityId: UUID?`）を足す。RPC 化するなら関数内で `UPDATE ... WHERE template_id = ? AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = ?` → 0 件なら `INSERT` で書く（SQL なら `ON CONFLICT (template_id, ((start_at AT TIME ZONE 'Asia/Tokyo')::date)) WHERE template_id IS NOT NULL DO UPDATE` と式と部分索引の条件をそろえて書いても通るが、UPDATE → INSERT のほうが読みやすい）

### 1-3. 【中】「過去は変わらない」を DB で守る仕組みが無い（今の案は UI だけが砦）
- **何が起きるか**: 世代表には `UNIQUE` と `CHECK` しか無い。過去の世代の `UPDATE`／`DELETE`、過去日への除外日 `INSERT` は、アプリのバグ・端末時計のずれ・MCP からの直接操作で通ってしまう。RLS 無効・anon キーで書ける構成（`docs/continuity-design.md:45`）なので、サーバー側の検査が無ければ「D ≥ 今日」は端末の時計次第
- **根拠**: `docs/day-cycle-walkthrough.md:122`「過去日は編集できないので D ≥ 今日」（UI の前提のみ）/ `docs/domain-model.md:16`「DB 制約は最後の砦」
- **修正案（2 段階）**:
  1. 最低限: 書き込みを RPC にまとめ、関数の先頭で `IF p_date < (now() AT TIME ZONE 'Asia/Tokyo')::date THEN RAISE EXCEPTION` を置く（§4 と同じ関数）
  2. 硬くするなら: 世代表と除外日表に「過去は不変」の行トリガーを置く（backfill の後に作る。CASCADE で消える行にもトリガーは効くので、過去の世代を持つ系列の物理削除も止まる＝設計の「過去の回があれば系列は残す」と一致）
     ```sql
     CREATE FUNCTION jst_today() RETURNS date LANGUAGE sql STABLE
       AS $$ SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date $$;

     CREATE FUNCTION guard_past_template_version() RETURNS trigger LANGUAGE plpgsql AS $$
     BEGIN
       IF TG_OP IN ('UPDATE','DELETE') AND OLD.effective_from < jst_today() THEN
         RAISE EXCEPTION 'past template version is immutable: % %', OLD.template_id, OLD.effective_from;
       END IF;
       IF TG_OP IN ('INSERT','UPDATE') AND NEW.effective_from < jst_today() THEN
         RAISE EXCEPTION 'cannot write a template version in the past: %', NEW.effective_from;
       END IF;
       RETURN COALESCE(NEW, OLD);
     END $$;
     CREATE TRIGGER task_template_version_guard
       BEFORE INSERT OR UPDATE OR DELETE ON task_template_version
       FOR EACH ROW EXECUTE FUNCTION guard_past_template_version();
     -- task_template_exdate にも同型（date 列で判定）
     ```
     `scheduled_task` へのトリガーは段階 2（チェックイン。スキップの持ち方で scheduled_task に列を足す可能性がある）と一緒に決める。今は世代表と除外日表だけにする
- **注意**: トリガーは `structural-conventions.md` D-4 が禁じる「plan ↔ actual の相互更新」ではない（plan 側の不変条件だけ）。ただし将来 MCP で過去データを直したいときは `ALTER TABLE ... DISABLE TRIGGER` が要る。この運用注意を migration のコメントに残す
- **本人判断が要る**: トリガーまで入れるか（「DB 制約は最後の砦」の適用範囲を CHECK/UNIQUE/FK から広げるか）。RPC 内の検査だけでも実用上は足りる

### 1-4. 【低】終了の世代（`is_ended`）が中身の列を必須で持つ
- **何が起きるか**: `is_ended = true` の行も `name`・`category_id`・時刻が `NOT NULL` なので、前の世代の中身をコピーして入れることになる。解決ロジックが `is_ended` を見落とすと「削除した系列が出続ける」。祝日の登録が終了の世代に残っていると、登録側だけ見た解決で祝日にだけ出る
- **根拠**: `docs/day-cycle-walkthrough.md:95-106`
- **修正案（どちらか）**:
  - A. 今の案のまま、`CHECK (NOT is_ended OR rrule IS NULL)` を足し、解決ロジックを「`is_ended` の世代は template も membership も出さない」と 1 か所に固定（§3-2 の pure 関数）
  - B. 系列側に `task_template.ended_on DATE NULL`（この日以降は出ない）を持ち、世代表は中身だけにする。「これ以降を削除」= `ended_on = D` ＋ `effective_from ≥ D` の世代を削除。解決は `effective_from ≤ d AND (ended_on IS NULL OR d < ended_on)`。ダミーの中身が要らない
  - どちらも世代管理（本人決定）の範囲内。A/B は AI 既定の領域

### 1-5. 【低】細かい DDL の不足
- `pattern_version_membership (version_id)` に索引が無い（PK は `pattern_id` 先頭）。世代を消す CASCADE と解決時の join が全走査になる。件数は小さいが、FK 側の索引は入れておく
- `task_template_version.created_at TIMESTAMPTZ NOT NULL DEFAULT now()` を足す（「いつ書いたか」は分析の切り分けに要る。`training_goal` にはある: `0005_training_goal.sql:14`）
- `task_template` は `id` だけになる。`created_at` を足すか、少なくともコメントで「系列の id を保つためだけの表」と明記
- `CHECK (0..1439)` はメモ表記。実 DDL は既存と同じ `BETWEEN 0 AND 1439` / `> 0 AND <= 1440`（`0001_initial.sql:46-55`）

### 1-6. 【中】migration の安全性: 列の削除を同じ migration に入れると、今入っているビルドが即座に壊れ、戻せない
- **何が起きるか**: `task_template` の中身の列と `pattern_template_membership` を消した瞬間、今のアプリは `client.from("task_template").select()` を `TaskTemplate`（`name` 必須）に decode できず、今日タブが「読み込みに失敗しました」になる（`SupabaseDayDataSource.swift:31-34`、`TaskTemplate.swift:3-10`）。新ビルドが入る前に migration だけ当たると復旧はデータの手戻し
- **根拠**: `docs/day-cycle-walkthrough.md:113-114`「移してから削除、task_template の中身の列を削除」/ `docs/implementation-roadmap.md:76`（実運用開始後の DDL 変更は branch 検証）
- **修正案**: 2 本に分ける
  - `0006_template_version.sql`: 表の追加・backfill・（RPC/トリガー）だけ。**破壊的変更なし**。旧列は残す（新アプリは旧列を読まない）
  - `0007_template_version_cleanup.sql`: 新ビルドで実 DB の読み書きが確認できた後に、`DROP TABLE pattern_template_membership` と `ALTER TABLE task_template DROP COLUMN ...`
  - backfill は再適用しても壊れないように `INSERT ... SELECT ... WHERE NOT EXISTS (SELECT 1 FROM task_template_version v WHERE v.template_id = t.id)` で書く
  - `apply_migration` が 1 トランザクションで走るかは確認できていない（推測）。順序を「作る → 入れる → 関数 → トリガー」にしておけば、途中で止まっても手で続きを流せる

### 1-7. 【低】第 1 世代の `effective_from = 2026-04-26` は近似
- **事実**: `task_template` に `created_at` が無いので、今の 2 件（睡眠・ジム）を実際にいつ入れたかはリポジトリからは分からない。0001 の日付（2026-04-26）を採るのは「最も早い可能性」。その日から実際の投入日までの間は、組み立て直すと当時は無かった予定が出る
- **影響**: この期間の実績（`actual_task`）は 0 件なので、分析上の実害はない。ただし「近似である」ことを migration のコメントと `domain-model.md` に残す

### 1-8. 【中】休日パターンの「存在」は世代管理されていない（分析要件の隠れた穴）
- **何が起きるか**: DayBuilder は「祝日で、かつ休日パターンが 1 件でもあれば」パターンモード、無ければ通常日（rrule どおり）にする（`DayBuilder.swift:121-126`）。つまり休日パターンを後から作ると、それ以前の祝日の組み立て結果が「rrule の予定が出ていた日」から「登録された予定だけの日」に変わる。今の実装は「祝日も出す」を初めて入れたときに休日パターンを作る（`SupabaseDayDataSource.swift:154-170`）
- **事実と推測の区別**: 本番 DB には休日パターンが既にある（`docs/day-cycle-walkthrough.md:9`）ので、今の DB では実害がない（事実）。今後パターンを消す・別環境で作り直す場面で出る（推測）
- **修正案**: 0006 で休日パターンを「無ければ作る」（`INSERT ... WHERE NOT EXISTS`）で固定し、アプリ側の lazy 作成（`ensureHolidayPattern`）を外す。パターン行は消さない運用にする（削除 UI は無い）。`domain-model.md` の day_meta/pattern の節に「パターンの存在は世代を持たない。休日パターンは常に存在させる」と書く

### 1-9. 【確認 OK】FK・RESTRICT・CASCADE の整合
- `scheduled_task.template_id ON DELETE RESTRICT`（`0001_initial.sql:84`）は系列の id を指したままなので、「系列ごと消す」は D 以降の実体を先に消してから。設計どおりの順序（実体削除 → 世代 CASCADE → 系列）なら通る。万一 D より前に実体があれば FK が止める＝最後の砦として正しい挙動
- `task_template_exdate.template_id ON DELETE CASCADE`（`:58`）は系列削除時だけ効く。世代の削除では消えない（設計どおり）
- `pattern_version_membership.version_id ON DELETE CASCADE` で、後の世代を消すと祝日の登録も消える。正しい
- `day_meta` は段階 1 では触らない。`applied_pattern_id` のモード判定と世代解決は独立で、干渉しない

## 2. 操作表で壊れるケース

記法: 系列 S、世代 V(d)（d から有効）、その日だけの実体 O(d)（`scheduled_task.template_id = S`、start_at の JST 日 = d）、除外日 X(d)。

### 2-1. 【高】「その日だけ変えた回」がある日から「これ以降」で保存すると、その日の表示が変わらない
- **手順**: ジム（平日 6:45）。10/7 に行をタップ →「この予定」→ 7:00 に変更 → O(10/7) ができる。同じ日にもう一度行（今度は実体 O）をタップ → 7:30 に変えて「これ以降」を選ぶ
- **結果**: V(10/7) = 7:30 ができるが、O(10/7) = 7:00 は「D 以降のその日だけの変更は残す」ルールで残る。DayBuilder は実体を仮想より優先する（`DayBuilder.swift:63-73`）ので、**10/7 は 7:00 のまま**。10/8 以降は 7:30。ユーザーには「保存したのに今日だけ変わらない」に見える
- **根拠**: `docs/day-cycle-walkthrough.md:125`「D 以降のその日だけの変更・除外日は残す」が D 自身を含む書き方になっている
- **修正案**: 「これ以降」保存では **D 自身の O(D) は消す（または新しい中身で書き換える）**。残すのは D より後の O(d > D)。Google カレンダーも「この予定以降」を選ぶと、その回は新しい系列の初回として置き換わる
- **本人判断が要る**: 本人決定「D 以降のその日だけの変更は残す」の「D 以降」を「D より後」と読む解釈。実質は編集している当日の話なので、確認は 1 問で済む

### 2-2. 【高】繰り返さない予定 ↔ 系列の相互変換で、元の行が残って二重に出る
- **手順 A（単発 → 系列）**: 10/7 に「＋」で単発（`template_id NULL`）を作る。後で編集して曜日を付ける →「D からの系列に変える」
- **結果 A**: 系列 S と V(10/7) を作るだけだと、10/7 は「単発の実体」＋「S の仮想」の **2 行**。単発は `template_id NULL` なので仮想の抑制（`editedOnDate`）に引っかからない
- **手順 B（系列 → 単発）**: ジム 10/7 を「この予定」で 7:00 にして O(10/7)。次に同じ行で曜日を全部外して保存 →「D に終了の世代＋その日だけの予定」
- **結果 B**: 新しい単発行を入れるだけだと、O(10/7)（S 由来の実体）と新しい単発の **2 行**。さらに「D より後の O・X をどうするか」が未定義（「これ以降を削除」と同じなら消す、「これ以降を保存」と同じなら残す）
- **根拠**: `docs/day-cycle-walkthrough.md:128`
- **修正案（仕様として書く）**:
  - 単発 → 系列: 単発行を **削除** し、S の仮想に置き換える（時刻・名前は同じフォームから来るので等しい）。もし単発行を残したいなら `template_id = S` に書き換えて O(D) にする（この場合は二重にならないが不要な実体が残る）。前者を推す
  - 系列 → 単発: 「これ以降を削除」（終了の世代 or 系列削除、D 以降の O・X を削除）を実行してから、単発行を INSERT。O(D) は「これ以降を削除」の中で消える
  - どちらも複数書き込みなので §4 の RPC に載せる

### 2-3. 【高】「これ以降を削除」で D 以降の除外日を残す判断と、系列を残す判断の組み合わせで「死んだ系列」が残る
- **手順**: 系列を作った日 D0 が土曜で曜日は平日、翌週月曜 D に「これ以降を削除」
- **結果**: 最初の世代は D0 < D なので系列は残り、終了の世代ができる。実際には一度も出ていない系列がデータに残る（表示・分析への実害はない。件数が増えるだけ）
- **根拠**: `docs/day-cycle-walkthrough.md:126`「系列の最初の世代が D 以降なら」＝世代の日付で判定
- **重大度は低に近いが、判定規則を「最初の世代の日付」でなく「D より前に出た回があるか（rrule と除外日を評価）」にするかは判断が要る**。前者は単純で DB だけで判定できる。後者は実装が重く、分析の再現性にも差が出ない。**前者のままでよい**（このケースは許容）と明記する。D 以降の除外日は残す（`:136` の AI 判断）でよい

### 2-4. 【確認 OK】日をまたぐ予定（睡眠 23:00→7:00）と前日の世代
- D（今日）で「これ以降」で睡眠を 22:00→6:00 に変えると: D の朝の流入（前日 23:00 発）は前日の世代 V_old で組み立てるので変わらない。D の夜は V_new、D+1 の朝の流入も V_new。正しい
- D で「これ以降を削除」: D の夜の分（overflow）が消え、D+1 の朝には流入しない（前日の解決が終了の世代 → template 無し）。前日 D-1 からの流入は残る。正しい
- X(D)（今日だけ消す）: D+1 の朝の流入は `previousExdates` で抑制（`DayBuilder.swift:21-26`）。正しい
- 「これ以降を削除」で消す O は「start_at の JST 日 ≥ D」で判定する。D-1 23:00 発の O(D-1) は消さない（前日の回）。設計と一致する。RPC ではこの条件を `(start_at AT TIME ZONE 'Asia/Tokyo')::date >= p_date` と書く（式インデックスと同じ式にして索引を使わせる）
- **ただし §3-1 の既存バグを先に直さないと、O(D-1) が当日に重ならない形に編集されたとき前日の仮想が流入する**

### 2-5. 【確認 OK・注意 1 件】祝日パターン日
- 祝日 H に「この予定」で睡眠を変える → O(H) に `pattern_id = 休日` が付く（`scheduled_task_origin_chk` を満たす）。実体優先で正しく出る
- 祝日 H に「これ以降」で「祝日も出す」を外す → V(H) に登録なし → H 自身から出なくなる（「これ以降」に H が含まれるので妥当）
- **注意（本人決定の帰結）**: 上の操作の前に O(H) があると、O(H) は残るので H には出続ける。曜日を減らした場合も同じで、外した曜日に O があればその日だけ出る。「これ以降で変えたとき D 以降のその日だけの変更は残す」の直接の帰結。仕様どおりだが、UI で「この日だけの変更が N 件残ります」と 1 行出すか、本人が違和感を持つか — **本人判断**。§2-1 と同じ 1 問にまとめて聞ける

### 2-6. 【中】「この予定を削除」は 2 書き込み（X(D) の INSERT ＋ O(D) の DELETE）。途中失敗で「消したのに出続ける」
- X(D) が入って O(D) の削除が失敗すると、仮想は抑制されるが実体 O(D) は残るので、その日に出続ける。やり直せば直る。§4 の RPC に載せる

### 2-7. 【低】「これ以降」保存は D より後に予定していた世代も黙って消す
- 例: 10/5 に「10/12 から 7:00」を先に入れ（V(10/12)）、その後 10/6 に「これ以降」で名前だけ変えると V(10/12) が消え、10/12 からの時刻変更もなくなる。設計どおり（Google の「以降すべて」と同型）。UI で「10/12 からの変更も上書きされます」と出すかは **本人判断**。DB 側の対処は不要

### 2-8. 【低】「今日」は 0 時まで書き換え可能なので、分析の再現性は「日」単位
- 23:30 に今日の予定を「これ以降」で変えると、今日 6:45 のジムも 7:00 に変わる。ルール「D ≥ 今日」の帰結で、当日の計画は当日中は確定しない。段階 2 で実績に「どの予定のどの日の回か」を持たせるときに、当日の書き換えで参照が外れないか（回の同一性を「系列 id ＋ 日」で持てば外れない）を段階 2 で見る。今は仕様として明記だけ

## 3. DayBuilder を「日ごとに解決した templates/memberships を渡す」形にする案

### 3-1. 【高・既存バグ】前日の実体が当日に重ならないと、前日の仮想の流入が抑制されない
- **手順**: 睡眠（毎日 23:00→7:00）。10/6 に「この予定」で 21:00→23:00（同日内）に変える → O(10/6) = 10/6 21:00–23:00。10/7 を開く
- **結果**: 10/7 の取得は「10/7 に重なる実体」だけ（`start_at < 10/8 0:00 AND end_at > 10/7 0:00`、`SupabaseDayDataSource.swift:58-63`）なので O(10/6) は取れない。仮に取れても、DayBuilder は当日に重なる実体だけを `scheduledFromEntities` にし（`DayBuilder.swift:232-262` の `computeMembership` で nil）、そこから `editedOnPreviousDay` を作る（`:57-61`）ので、10/6 の睡眠は「編集済み」と分からない。結果、**10/6 の世代の仮想（23:00→7:00）が 10/7 の朝に「前日から継続 00:00–07:00 睡眠」として出る**。実際は 23:00 に寝る予定は無い
- **なぜ今出ていないか**: 実体が 0 件で、テストは重なる形（22:30→6:30、`LifeTrackerTests.swift:504-539` T18b）しか無い
- **修正案**:
  1. 取得を前日いっぱいまで広げる: `start_at < dayEnd AND end_at > previousDayStart`（[D-1 0:00, D+1 0:00) に重なるもの）
  2. DayBuilder は `editedOnDate` / `editedOnPreviousDay` を **clip 前の `context.scheduledTasks`** から作る（`collectScheduledEntities` の結果からではなく）。表示用の clip はそのまま
  3. テスト追加: 「前日 21:00–23:00 の実体があれば、前日 virtual の spillover は出ない」「前日の実体は当日の一覧には出ない」
- 世代管理とは独立の穴だが、段階 1 で「この予定」を作れるようになると必ず踏むので、段階 1 の前に直す

### 3-2. 【中】「DayBuilder の合成ロジックは変えない」は言い過ぎ。前日用の入力が要る
- **事実**: `composeVirtualSeeds` は当日・前日の両方で `context.templates` と `context.memberships` を読む（`DayBuilder.swift:157-198`）。前日を前日の世代で組み立てるには、`DayBuilderContext` に `previousTemplates` / `previousMemberships` を足し、`composeVirtualSeeds` に渡す必要がある（`previousExdates` / `previousDayMeta` と同じ形。`DayBuilderContext.swift:3-14`）
- **修正案**:
  - `DayBuilderContext` に `previousTemplates: [TaskTemplate]`、`previousMemberships: [PatternTemplateMembership]` を追加。既定値は当日と同じ（既存テスト T1〜T18d を変えずに通す）
  - 解決は pure 関数 1 つに固定する（`Continuity.target(forWeek:goals:)` と同じ流儀、`Shared/Continuity.swift:35-38`）:
    ```swift
    enum TemplateVersions {
      /// その日に効く世代を系列ごとに 1 つ選ぶ (effective_from ≤ day の最新)。is_ended は除く。
      /// 返す TaskTemplate.id は系列の id。membership は選んだ世代の分だけ
      static func resolve(versions: [TaskTemplateVersion],
                          memberships: [PatternVersionMembership],
                          on day: Date, calendar: Calendar)
        -> (templates: [TaskTemplate], memberships: [PatternTemplateMembership])
    }
    ```
    Service はこれを D と D-1 の 2 回呼ぶ。全世代・全登録を 1 回取得して端末で解決する（件数は数十行。日を移るたびのサーバー往復を増やさない）
  - テスト: 世代境界（D-1 は旧・D は新）で流入が旧世代で出る／終了の世代の翌朝に流入しない／終了の世代の祝日登録が無視される／`effective_from` より前の日は空
- SQL 側にも同じ規則の view（例 `task_template_at(p_date)`）を分析用に置いてよいが、規則の原本は Swift の pure 関数と決め、SQL は「写し」とコメントに書く（2 か所になる drift を認識したうえで、テストできる側を原本にする）

### 3-3. 【確認 OK】spillover の扱い
- 「前日から続く分は押せない」は D = 今日では正しい（前日の回＝過去）。D = 明日を見ているときの流入は今日の回で編集可能だが、その画面からは押せない（今日の画面で編集する）。矛盾はない。UX の話なので DB 観点では指摘なし
- `previousDayMeta` が doNothing なら前日世代に関わらず流入なし（T18c）。世代の追加で変わらない

## 4. 書き込みの原子性

### 4-1. 【中】「これ以降」系と相互変換は 3〜5 書き込み。PostgREST から逐次に書くと途中失敗で壊れた状態が残る
- **事実**: supabase-swift 2.44.1 に `.rpc()` はある（`PostgrestClient.swift` に `func rpc`）。既存コードは RPC を使っておらず（grep で 0 件）、複数書き込みは逐次（`saveTemplate`: `SupabaseDayDataSource.swift:117-136` は upsert → パターン確認 → 登録の 3 往復）
- **壊れ方の例**:
  - 「これ以降を削除」: 終了の世代を書いた後で O(d ≥ D) の削除が失敗 → 系列は消えたのに、個別に変えた回だけ未来の日に残る。ユーザーはその日まで気づかない（「消えるべきものが残る」）
  - 「これ以降を保存」: 世代を書いた後で祝日の登録が失敗 → 祝日に出ない設定で保存されたように見える（黙って設定が落ちる）
  - 単発 → 系列: 系列と世代を書いた後で単発の削除が失敗 → 二重表示（§2-2）
- **修正案**: 0006 に plpgsql 関数を置き、アプリはそれを呼ぶ。1 関数 = 1 トランザクションになり、「D ≥ 今日」の検査も 1 か所に置ける（§1-3）。下の `jst_today()` は §1-3 で定義したもので、トリガーを入れない場合も関数だけは作る
  ```sql
  -- 「これ以降」で保存。祝日の登録も一緒に受ける。D 自身の「その日だけの変更」は消す (§2-1)
  CREATE FUNCTION template_save_following(
    p_template_id uuid, p_date date, p_name text, p_category_id uuid,
    p_start int, p_duration int, p_rrule text, p_show_on_holiday boolean
  ) RETURNS uuid LANGUAGE plpgsql AS $$
  DECLARE v_version_id uuid; v_holiday uuid;
  BEGIN
    IF p_date < jst_today() THEN RAISE EXCEPTION 'past day is not editable: %', p_date; END IF;
    DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
    UPDATE task_template_version
       SET is_ended = false, name = p_name, category_id = p_category_id,
           start_minutes_from_midnight = p_start, duration_minutes = p_duration, rrule = p_rrule
     WHERE template_id = p_template_id AND effective_from = p_date
     RETURNING id INTO v_version_id;
    IF v_version_id IS NULL THEN
      INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                         start_minutes_from_midnight, duration_minutes, rrule)
      VALUES (p_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule)
      RETURNING id INTO v_version_id;
    END IF;
    SELECT id INTO v_holiday FROM pattern WHERE apply_day = 'Holiday';
    DELETE FROM pattern_version_membership WHERE version_id = v_version_id;
    IF p_show_on_holiday THEN
      INSERT INTO pattern_version_membership (pattern_id, version_id) VALUES (v_holiday, v_version_id);
    END IF;
    DELETE FROM scheduled_task
     WHERE template_id = p_template_id
       AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date;   -- §2-1: D 自身の O(D) は消す
    RETURN v_version_id;
  END $$;

  -- 「これ以降」で削除。過去の回が無ければ系列ごと消す
  CREATE FUNCTION template_delete_following(p_template_id uuid, p_date date)
  RETURNS void LANGUAGE plpgsql AS $$
  DECLARE v_first date;
  BEGIN
    IF p_date < jst_today() THEN RAISE EXCEPTION 'past day is not editable: %', p_date; END IF;
    DELETE FROM scheduled_task
     WHERE template_id = p_template_id
       AND (start_at AT TIME ZONE 'Asia/Tokyo')::date >= p_date;
    DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
    SELECT min(effective_from) INTO v_first FROM task_template_version WHERE template_id = p_template_id;
    IF v_first IS NULL OR v_first >= p_date THEN
      DELETE FROM task_template WHERE id = p_template_id;   -- 世代・除外日・登録は CASCADE
      RETURN;
    END IF;
    -- 終了の世代 (中身は直前の世代のコピー。§1-4 の B 案なら ended_on を書くだけ)
    INSERT INTO task_template_version (template_id, effective_from, is_ended, name, category_id,
                                       start_minutes_from_midnight, duration_minutes, rrule)
    SELECT template_id, p_date, true, name, category_id, start_minutes_from_midnight, duration_minutes, NULL
      FROM task_template_version
     WHERE template_id = p_template_id AND effective_from < p_date
     ORDER BY effective_from DESC LIMIT 1
    ON CONFLICT (template_id, effective_from) DO UPDATE
      SET is_ended = true, rrule = NULL;
    DELETE FROM pattern_version_membership
     WHERE version_id IN (SELECT id FROM task_template_version
                           WHERE template_id = p_template_id AND effective_from = p_date);
  END $$;

  -- 「この予定」を削除: 除外日 ＋ その日だけの実体を消す
  CREATE FUNCTION occurrence_delete(p_template_id uuid, p_date date) RETURNS void LANGUAGE plpgsql AS $$
  BEGIN
    IF p_date < jst_today() THEN RAISE EXCEPTION 'past day is not editable: %', p_date; END IF;
    INSERT INTO task_template_exdate (template_id, date) VALUES (p_template_id, p_date) ON CONFLICT DO NOTHING;
    DELETE FROM scheduled_task
     WHERE template_id = p_template_id AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date;
  END $$;
  -- ほかに template_create(単発→系列を含む) / template_end_to_single(系列→単発) を同型で
  ```
  - `structural-conventions.md` D-4（RPC で plan と actual を join しない）には触れない。上の関数は plan 側の表だけを扱う
  - アプリ側: `ScheduleSettingsDataSource` を「操作の単位」の protocol に組み直す（§6-1）。`InMemoryScheduleDataSource` は同じ操作をメモリ上で実装し、単体テストの対象にする。SQL と Swift の 2 実装になる drift は、SQL を上のように「Swift の手順の写し」に留めることと、branch DB での手順チェックリスト（§6-4）で受ける
- **本人判断が要る**: RPC を入れるか。入れない場合は「各手順を冪等にして順序を固定し、失敗時は再読込して現状を見せる」で受けることになるが、上の壊れ方は残る。**RPC を推す**

## 5. 分析要件（過去のある日の予定を同じ結果で組み立て直せる）

### 5-1. 【確認 OK】操作表の範囲では満たす
- 日 d の組み立てに要る入力: 世代（`effective_from ≤ d`）とその祝日登録、X(d)・X(d-1)、day_meta(d)・(d-1)、d に重なる実体、パターン、祝日判定
- 世代は D ≥ 今日にしか作られず、消えるのは `effective_from > D` の世代だけ。除外日・実体も D ≥ 今日にしか書かない。よって過去の d の入力はどの操作でも変わらない。設計どおり
- 実体 O(d) は中身をコピーで持つので、その O が「どの世代から派生したか」は日付から復元でき、組み立て結果は変わらない

### 5-2. 満たさない／条件付きのもの
1. **【中】休日パターンの存在**が世代管理されていない（§1-8）。今の DB では既に存在するので実害なし。lazy 作成をやめて migration で固定する
2. **【中】旧画面の物理削除**（`deleteTemplate(id:)`、`SupabaseDayDataSource.swift:138-143`）が残ると、過去の世代ごと消せる。段階 1 で「いつもの予定」一覧を消す決定なので、この経路も protocol ごと消す（§6-1）。残すなら「最初の世代が今日以降の系列だけ」に限定
3. **【低】第 1 世代の日付が近似**（§1-7）。実績 0 件の期間なので実害なし。前提として記録する
4. **【低】今日は 0 時まで書き換わる**（§2-8）。日単位の再現性。段階 2 で「回の同一性」を系列 id ＋ 日で持てば影響しない
5. **【低】祝日ライブラリ（HolidayJp）の更新**で過去の祝日判定が変わり得る。DB の外で、今回の設計とは無関係。ここでは扱わない

## 6. 既存コードからの移行で壊れるもの・テストの穴

### 6-1. 壊れる箇所（0006 と同時に直す）
| 箇所 | 何が壊れるか | 直し方 |
|---|---|---|
| `Models/TaskTemplate.swift:3-10` | `task_template` から decode している。列削除後は `name` が無く decode 失敗 | `TaskTemplate` は「解決後の形」として残し、DB 行は新しい `TaskTemplateVersion`（`id, templateId, effectiveFrom, isEnded, name, ...`）で受ける |
| `Services/SupabaseDayDataSource.swift:31-34, 41-44` | `task_template` / `pattern_template_membership` を直接読む | `task_template_version` と `pattern_version_membership` を全件読み、§3-2 の `resolve` を D と D-1 で呼ぶ |
| `SupabaseDayDataSource.swift:58-63` | 取得窓が当日に重なる実体だけ（§3-1） | `end_at > previousDayStart` に広げる |
| `SupabaseDayDataSource.swift:108-171` | `fetchScheduleSettings` / `saveTemplate` / `deleteTemplate` / `ensureHolidayPattern` が旧表・旧列を書く | protocol ごと「操作の単位」に組み直す: `saveOccurrence(this)` / `saveFollowing` / `deleteOccurrence` / `deleteFollowing` / `createSeries` / `saveSingle` / `deleteSingle` / `createCategory`。`ensureHolidayPattern` は migration 固定に置き換え |
| `Services/ScheduleSettingsDataSource.swift:5-12, 33-46` | `TemplateInput` に日付・範囲（この予定／これ以降）・繰り返し無しの表現がない | 入力型に `date: Date`、`repeat: Repeat?`（nil = 繰り返さない）、書き込み時に `scope` を持つ |
| `Services/ScheduleSettingsStore.swift:65` | `noRepeat`（曜日か祝日を 1 つ以上）が「新規の既定は繰り返さない」と矛盾。保存できない | 検査を「名前が空」「開始＝終了」だけにする |
| `Services/InMemoryScheduleDataSource.swift:22-27` | `loadDayContext` が `date` を無視し、除外日・実体・day_meta を常に空で返す | 世代・登録・除外日・実体を日付で返す形に作り直す（`-mock-day` で操作表を再現できないと、段階 1 のシミュレータ確認が成立しない） |
| `Services/TodayDataLoader.swift:24-36` | `now()` の日しか読めない | `selectedDate` を受ける（トレーニングの `selectedDay: Date?`（nil = 今日）と同じ持ち方。`gymwork-alignment-design.md:376` の理由「開いたまま日付をまたぐ」がここにも当てはまる） |
| `DayBuilder/DayBuilderContext.swift:3-14`, `DayBuilder.swift:157-198` | 前日用の templates/memberships が無い（§3-2） | `previousTemplates` / `previousMemberships` 追加 |
| `DayBuilder/Day.swift:15-21` | 実体／仮想の区別が無い（§1-2） | `isVirtual` を足す |
| `Views/Home/HomeView.swift:26-33, 38-40`、`ScheduleSettingsViews.swift:15-59` | 「予定」一覧・`ScheduleTemplateListView` は廃止決定 | 削除。編集シートは「1 回分」の編集に作り替え |
| `Views/Workout/WeekStripView.swift:60` | 未来日を `disabled` にしている | 今日タブでは未来を有効にする引数を足す（コピーしない。`structural-conventions.md` B-1） |

### 6-2. 既存テストへの影
- `ScheduleSettingsTests.swift:98-101`: `.noRepeat` を期待している → 削除
- `ScheduleSettingsTests.swift:57-66, 92-107`: `makeFixture` と `delete(id:)` 前提 → 操作単位の API に書き直し
- `LifeTrackerTests.swift` T1〜T18d: `previousTemplates` の既定を当日と同じにすれば **そのまま通る**。変えないこと（回帰の基準にする）
- `MockDayDataSourceTests.swift:41-123`: 新フィールドの保持を 1 行ずつ足す

### 6-3. 足すべきテスト（pure 関数・DayBuilder）
1. 世代解決: 境界日・`is_ended`・最初の世代より前・同じ系列の登録が世代ごとに切り替わる（旧世代は祝日に出る／新世代は出ない → 過去の祝日は旧世代で出る）
2. §3-1: 前日の実体が当日に重ならない形でも前日 virtual の流入が出ない
3. §2-1: 「これ以降」保存の後、D の表示が新しい中身になる（O(D) が消えている）
4. §2-2: 単発 ↔ 系列の変換で D の行数が 1
5. 「これ以降を削除」: `start_at` の日 ≥ D の実体だけ消え、D-1 23:00 発の実体は残る。D+1 の朝に流入しない
6. 「この予定を削除」: X(D) ＋ O(D) 削除で D に出ない、D+1 の朝の流入も出ない（睡眠）
7. 系列削除の判定: 最初の世代 = D なら系列ごと消え、除外日・登録も消える（InMemory で CASCADE 相当を実装する）

### 6-4. SQL 側の確認（単体テストでは書けない）
- 0006 を `mcp__supabase-personal__create_branch` の branch に当て、上の 1〜7 と同じ手順を RPC で流して行数を確認するチェックリストを `docs/day-cycle-walkthrough.md` の完了条件に入れる（`implementation-roadmap.md:76` の運用。今回は破壊的変更を 0007 に分けるので、0006 単体なら main 直当てでも戻せるが、RPC の動作は branch で見ておく）
- backfill 後の期待値: `task_template_version` 2 件（effective_from = 2026-04-26、is_ended = false）、`pattern_version_membership` 1 件（休日 × 睡眠の世代）、`task_template` 2 件のまま

## 7. 指摘の一覧（重大度順）

| # | 重大度 | 節 | 要点 | 本人判断 |
|---|---|---|---|---|
| 1 | 高 | §3-1 | 前日の実体が当日に重ならないと前日 virtual の流入が消えない（既存バグ。段階 1 で踏む） | 不要（直す） |
| 2 | 高 | §2-1 | 「その日だけ変えた回」がある日から「これ以降」保存 → その日が変わらない。D 自身の O は消す | 要（「D 以降」の読み方の確認 1 問） |
| 3 | 高 | §2-2 | 単発 ↔ 系列の変換が未定義で二重表示になる | 不要（仕様に書く） |
| 4 | 中 | §4 | 「これ以降」系が複数書き込み。RPC 化＋「D ≥ 今日」の DB 側検査 | 要（RPC を入れるか） |
| 5 | 中 | §1-6 | 列・表の削除を 0007 に分けて戻せるようにする | 不要 |
| 6 | 中 | §1-1 | upsert に `id` を含めると PK 書き換え／FK エラー | 不要 |
| 7 | 中 | §1-2 | 式インデックスは upsert できない。実体／仮想の区別を出力に足す | 不要 |
| 8 | 中 | §1-3 | 「過去は変わらない」の DB 側の砦（RPC 検査 ＋ 任意でトリガー） | 要（トリガーまで入れるか） |
| 9 | 中 | §1-8 / §5-2 | 休日パターンの存在が世代管理されない。migration で固定・lazy 作成をやめる | 不要 |
| 10 | 中 | §3-2 | 「DayBuilder は変えない」は言い過ぎ。前日用入力と解決の pure 関数 | 不要 |
| 11 | 中 | §5-2 / §6-1 | 旧画面の物理削除経路を消す。`noRepeat` 検査を外す | 不要 |
| 12 | 中 | §6-1 | InMemory が日付を無視するため段階 1 の確認ができない | 不要 |
| 13 | 低 | §1-4 | 終了の世代がダミーの中身を持つ。`ended_on` 案も可 | AI 既定でよい |
| 14 | 低 | §1-5 / §1-7 | 索引・`created_at`・第 1 世代の日付が近似 | 不要（前提を記録） |
| 15 | 低 | §2-3 / §2-5 / §2-7 / §2-8 | 死んだ系列・残る個別変更・未来世代の上書き・今日は当日中は変わる | 要（UI の 1 行案内を出すかだけ） |

## 8. このまま実装に入ってよいか

- **入る前に直す**: #1（DayBuilder の取得窓と抑制集合。世代管理と独立なので先に単独で直してテストを足せる）、#2・#3（操作表の 3 遷移を仕様に書く。本人への確認は「D 自身のその日だけの変更は消してよいか」の 1 問）、#4（RPC にするかを決める。データソース protocol の形が変わるので先）。
- **migration は 2 本に分ける**（#5）。0006 は追加だけにし、旧ビルドを壊さない。休日パターンの固定（#9）も 0006 に入れる。
- **設計文書に反映してから着手**: `DayBuilderContext` の前日用入力と解決の pure 関数（#10）、`noRepeat` 撤去と物理削除経路の廃止（#11）、InMemory の日付対応（#12）。
- 上が済めば、世代管理の骨格（系列 id 固定・世代表・登録の世代化・除外日と実体は系列参照）は変えずに実装に入れる。分析要件は操作表の範囲で満たす（§5-1）。
