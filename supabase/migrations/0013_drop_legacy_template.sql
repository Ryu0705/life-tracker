-- Life Tracker v2 — task_template の旧列と pattern_template_membership を消す (0006 で予告した後始末)
-- 2026-10-19 / 計画: docs/auth-multiuser-implementation-plan.md §1-2。0014 (人ごとのデータ・RLS) の前に流す
-- 適用方法: Supabase MCP apply_migration (name: v2_drop_legacy_template) / supabase-cli は使わない
-- 本番適用: 未 (段階 3 で本人 OK の後。本番のバックアップの後)
--
-- 0006 の注記「task_template は系列の id を保つためだけの表になる」に合わせる。中身は task_template_version、
-- 祝日に出すかは pattern_version_membership が持ち、アプリ (0006 以降のビルド) は旧列も旧表も読まない。
-- 消すもの: pattern_template_membership (表) / task_template の name・category_id・start_minutes_from_midnight・
--   duration_minutes・rrule (task_template → category の外部キーも一緒に消える)
-- 戻せない (列と行を消す)。消す中身は世代と pattern_version_membership から導けるので、戻すのはバックアップからだけ
-- schedule_template_create は引数を変えずに旧列への写しをやめる (0013 と 0014 の間も今のビルドが動く)。
--   CREATE OR REPLACE なので GRANT は保たれる
-- 順序: 砦 (写し漏れがあれば何も消さずに止める) → 関数 → 表と列

-- ============================================================
-- 砦。0006 の backfill の写し漏れがあれば止める (本番は 2026-10-19 にどちらも 0 件)
-- ============================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM task_template t
    WHERE NOT EXISTS (SELECT 1 FROM task_template_version v WHERE v.template_id = t.id)
  ) THEN
    RAISE EXCEPTION '0013: task_template without any version';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pattern_template_membership m
    WHERE NOT EXISTS (
      SELECT 1 FROM pattern_version_membership pv
      JOIN task_template_version v ON v.id = pv.version_id
      WHERE pv.pattern_id = m.pattern_id AND v.template_id = m.template_id
    )
  ) THEN
    RAISE EXCEPTION '0013: pattern_template_membership not copied to pattern_version_membership';
  END IF;
END $$;

-- ============================================================
-- 関数。旧列を消す前に、旧列への写しをやめた形にする (0012 の定義から INSERT だけを変えた)
-- ============================================================
CREATE OR REPLACE FUNCTION schedule_template_create(
  p_date date, p_name text, p_category_id uuid, p_start int, p_duration int,
  p_rrule text, p_show_on_holiday boolean, p_replace_single_id uuid, p_target int, p_carry_over boolean
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_template_id uuid;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday' USING ERRCODE = 'check_violation';
  END IF;
  -- 系列の id だけを作る (中身は世代に持つ。0013 で旧列を消した)
  INSERT INTO task_template DEFAULT VALUES
  RETURNING id INTO v_template_id;
  INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
  VALUES (v_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule, p_target, p_carry_over)
  RETURNING id INTO v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO pattern_version_membership (pattern_id, version_id)
    VALUES (schedule_holiday_pattern_id(), v_version_id);
  END IF;
  IF p_replace_single_id IS NOT NULL THEN
    -- 単発の検査はつなぎ直す前に (後だと実績が外れて閉じた日が求まらず、今日より前に閉じた単発も通ってしまう。
    -- 2026-10-14 Swift 側の指摘)。検査は削除と同じ (元の日のまま = p_new_date NULL)
    PERFORM private.schedule_assert_single_editable(p_replace_single_id, NULL, NULL);
    UPDATE actual_task
       SET scheduled_task_id = NULL, template_id = v_template_id, occurrence_date = p_date
     WHERE scheduled_task_id = p_replace_single_id;
    PERFORM schedule_single_delete(p_replace_single_id);
  END IF;
  RETURN v_template_id;
END $$;

-- ============================================================
-- 表と列
-- ============================================================
DROP TABLE pattern_template_membership;

ALTER TABLE task_template
  DROP COLUMN name,
  DROP COLUMN category_id,
  DROP COLUMN start_minutes_from_midnight,
  DROP COLUMN duration_minutes,
  DROP COLUMN rrule;
