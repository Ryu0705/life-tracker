-- 0014 の後の形の機械の確かめ (計画 §1-5 の 10・11)。0015 (トレーニングの日) の後の形も含む (「day:」の行)。読むだけの SELECT 1 つ
-- docker: run.sh が流し、ok が f の行があれば止まる。本番: MCP の execute_sql にそのまま渡す (段階 3-2 の 5)
-- 捨ての関数で既定の権限を見る確かめ (10 の 4 つ目の後半) は書き込みなので、ここには入れない (multiuser_test.sql の 10)
WITH
rel AS (
  SELECT c.oid, c.relname, c.relkind, c.relrowsecurity, c.reloptions
  FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'v')
),
tbl AS (SELECT * FROM rel WHERE relkind = 'r'),
vw AS (SELECT * FROM rel WHERE relkind = 'v'),
fn AS (
  SELECT p.oid, p.oid::regprocedure::text AS sig, p.proname, p.pronamespace, p.proconfig
  FROM pg_proc p
  WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
),
checks AS (
  -- RLS
  SELECT 'rls: 全表で有効' AS name, count(*) = 0 AS ok, string_agg(relname, ',') AS detail
  FROM tbl WHERE NOT relrowsecurity
  UNION ALL
  SELECT 'rls: policy の無い表が 0', count(*) = 0, string_agg(tablename, ',')
  FROM (SELECT tablename FROM pg_tables WHERE schemaname = 'public'
        EXCEPT SELECT tablename FROM pg_policies WHERE schemaname = 'public') x
  UNION ALL
  SELECT 'rls: policy が 24', count(*) = 24, count(*)::text
  FROM pg_policies WHERE schemaname = 'public'
  UNION ALL
  SELECT 'rls: policy の roles が authenticated だけ', bool_and(roles = '{authenticated}'::name[]),
         string_agg(DISTINCT roles::text, ',')
  FROM pg_policies WHERE schemaname = 'public'
  UNION ALL
  SELECT 'rls: 表が 21', count(*) = 21, count(*)::text FROM tbl
  -- 表と view の権限
  UNION ALL
  SELECT 'priv: anon は表と view に何も無い', count(*) = 0, string_agg(relname, ',')
  FROM rel
  WHERE has_table_privilege('anon', oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  UNION ALL
  SELECT 'priv: authenticated は表に読み書きだけ', count(*) = 0, string_agg(relname, ',')
  FROM tbl
  WHERE NOT (has_table_privilege('authenticated', oid, 'SELECT')
             AND has_table_privilege('authenticated', oid, 'INSERT')
             AND has_table_privilege('authenticated', oid, 'UPDATE')
             AND has_table_privilege('authenticated', oid, 'DELETE'))
     OR has_table_privilege('authenticated', oid, 'TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  UNION ALL
  SELECT 'priv: authenticated は view に SELECT だけ', count(*) = 0, string_agg(relname, ',')
  FROM vw
  WHERE NOT has_table_privilege('authenticated', oid, 'SELECT')
     OR has_table_privilege('authenticated', oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  UNION ALL
  SELECT 'priv: service_role の読み書きが残っている', count(*) = 0, string_agg(relname, ',')
  FROM tbl
  WHERE NOT (has_table_privilege('service_role', oid, 'SELECT')
             AND has_table_privilege('service_role', oid, 'INSERT')
             AND has_table_privilege('service_role', oid, 'UPDATE')
             AND has_table_privilege('service_role', oid, 'DELETE'))
  -- 関数の権限 (PUBLIC 経由も含めて判定される)
  UNION ALL
  SELECT 'priv: anon は関数を呼べない', count(*) = 0, string_agg(sig, ',')
  FROM fn WHERE has_function_privilege('anon', oid, 'EXECUTE')
  UNION ALL
  SELECT 'priv: authenticated は全関数を呼べる', count(*) = 0, string_agg(sig, ',')
  FROM fn WHERE NOT has_function_privilege('authenticated', oid, 'EXECUTE')
  UNION ALL
  SELECT 'priv: 関数に PUBLIC の EXECUTE が無い', count(*) = 0, string_agg(fn.sig, ',')
  FROM fn JOIN pg_proc p ON p.oid = fn.oid
  WHERE EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0)
     OR p.proacl IS NULL  -- NULL は組み込みの既定 (PUBLIC に EXECUTE)
  UNION ALL
  SELECT 'priv: anon は private を使えない', NOT has_schema_privilege('anon', 'private', 'USAGE'), NULL
  UNION ALL
  SELECT 'priv: authenticated は private を使える', has_schema_privilege('authenticated', 'private', 'USAGE'), NULL
  -- 既定の権限 (P1)。postgres のグローバルの関数の行が {postgres=X/postgres}、public の行に anon も PUBLIC も無い
  UNION ALL
  SELECT 'default acl: グローバルの関数の行', count(*) = 1, string_agg(defaclacl::text, ',')
  FROM pg_default_acl
  WHERE defaclrole = 'postgres'::regrole AND defaclnamespace = 0 AND defaclobjtype = 'f'
    AND defaclacl::text = '{postgres=X/postgres}'
  UNION ALL
  SELECT 'default acl: public の行に anon と PUBLIC が無い', count(*) = 0, string_agg(defaclobjtype::text || ':' || defaclacl::text, ' ')
  FROM pg_default_acl d
  WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace
    AND EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) a WHERE a.grantee IN (0, 'anon'::regrole))
  UNION ALL
  SELECT 'default acl: public の表の行で authenticated に TRUNCATE 等が無い', count(*) = 0, string_agg(a.privilege_type, ',')
  FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) a
  WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace AND d.defaclobjtype = 'r'
    AND a.grantee = 'authenticated'::regrole AND a.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')
  -- 関数の形
  UNION ALL
  SELECT 'fn: 全関数が search_path = ''''', count(*) = 0, string_agg(sig, ',')
  FROM fn WHERE proconfig IS DISTINCT FROM '{"search_path=\"\""}'::text[]
  UNION ALL
  SELECT 'fn: 31 個 (28 ＋ ensure_user_defaults ＋ 0015 のトリガー 2)', count(*) = 31, count(*)::text FROM fn
  UNION ALL
  SELECT 'fn: 同じ名前の重なりが 0', count(*) = 0, string_agg(proname, ',')
  FROM (SELECT pronamespace, proname FROM fn GROUP BY 1, 2 HAVING count(*) > 1) x
  UNION ALL
  SELECT 'fn: SECURITY DEFINER が 0', count(*) = 0, string_agg(fn.sig, ',')
  FROM fn JOIN pg_proc p ON p.oid = fn.oid WHERE p.prosecdef
  UNION ALL
  SELECT 'fn: v1 の残りが 0', count(*) = 0, string_agg(proname, ',')
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('fn_resolve_month_patterns', 'sync_did_gym_on_insert', 'sync_did_gym_on_delete',
                    'sync_did_study_on_insert', 'sync_did_study_on_delete', 'update_updated_at')
  -- view
  UNION ALL
  SELECT 'view: security_invoker', count(*) = 0, string_agg(relname, ',')
  FROM vw WHERE NOT coalesce('security_invoker=true' = ANY (reloptions), false)
  UNION ALL
  SELECT 'view: 2 つ', count(*) = 2, string_agg(relname, ',') FROM vw
  -- 拡張
  UNION ALL
  SELECT 'ext: btree_gist が extensions に', count(*) = 1, NULL
  FROM pg_extension WHERE extname = 'btree_gist' AND extnamespace = 'extensions'::regnamespace
  -- 列と索引
  UNION ALL
  SELECT 'col: 全表に user_id', count(*) = 0, string_agg(relname, ',')
  FROM tbl WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = tbl.oid AND a.attname = 'user_id' AND NOT a.attisdropped)
  UNION ALL
  SELECT 'col: user_id は exercise 以外で NOT NULL・既定値 auth.uid()', count(*) = 0, string_agg(t.relname, ',')
  FROM tbl t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attname = 'user_id'
  LEFT JOIN pg_attrdef d ON d.adrelid = t.oid AND d.adnum = a.attnum
  WHERE (t.relname <> 'exercise' AND NOT a.attnotnull)
     OR pg_get_expr(d.adbin, d.adrelid) IS DISTINCT FROM 'auth.uid()'
  UNION ALL
  SELECT 'idx: 全表に user_id が先頭の部分でない索引', count(*) = 0, string_agg(relname, ',')
  FROM tbl t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_attribute a ON a.attrelid = t.oid AND a.attname = 'user_id'
    WHERE i.indrelid = t.oid AND i.indpred IS NULL AND i.indkey[0] = a.attnum)
  UNION ALL
  SELECT 'fk: 子の外部キー 19 本が user_id を含む組', count(*) = 19, count(*)::text
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attname = 'user_id'
  WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
    AND c.confrelid <> 'auth.users'::regclass AND a.attnum = ANY (c.conkey)
  UNION ALL
  SELECT 'fk: exercise 以外を指す 1 列の外部キーが 0', count(*) = 0, string_agg(conname, ',')
  FROM pg_constraint c
  WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
    AND c.confrelid NOT IN ('auth.users'::regclass, 'public.exercise'::regclass)
    AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'user_id' AND a.attnum = ANY (c.conkey))
  -- 0015 トレーニングの日
  UNION ALL
  SELECT 'day: workout_session.day と workout_set.day が NOT NULL', count(*) = 2, string_agg(attrelid::regclass::text, ',')
  FROM pg_attribute
  WHERE attrelid IN ('public.workout_session'::regclass, 'public.workout_set'::regclass)
    AND attname = 'day' AND attnotnull AND NOT attisdropped
  UNION ALL
  SELECT 'day: 時刻の窓の CHECK 2 つが有効', count(*) = 2, string_agg(conname, ',')
  FROM pg_constraint
  WHERE conname IN ('workout_session_day_window_chk', 'workout_set_day_window_chk') AND contype = 'c' AND convalidated
  UNION ALL
  SELECT 'day: 1 人 1 日 1 セッションの一意', count(*) = 1, NULL
  FROM pg_constraint c
  WHERE c.conrelid = 'public.workout_session'::regclass AND c.contype = 'u'
    AND (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) = '{user_id,day}'::name[]
  UNION ALL
  SELECT 'day: 進行中 1 件の一意 (workout_session_single_in_progress) が無い',
         to_regclass('public.workout_session_single_in_progress') IS NULL, NULL
  UNION ALL
  SELECT 'day: セットの外部キーの組 (セッションは日まで・種目 1 回分はセッションまで)', count(*) = 2, string_agg(conname, ',')
  FROM pg_constraint c
  WHERE c.conrelid = 'public.workout_set'::regclass AND c.contype = 'f'
    AND (c.conname, (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum))
        IN (('workout_set_session_id_fkey', '{session_id,user_id,day}'::name[]),
            ('workout_set_entry_fk', '{entry_id,session_id,exercise_id,user_id}'::name[]))
  UNION ALL
  SELECT 'day: day を埋めるトリガー 2 つが有効', count(*) = 2, string_agg(tgname, ',')
  FROM pg_trigger
  WHERE tgname IN ('workout_session_fill_day', 'workout_set_fill_day') AND NOT tgisinternal AND tgenabled = 'O'
  UNION ALL
  SELECT 'day: セットの日 = セッションの日', count(*) = 0, count(*)::text
  FROM public.workout_set w JOIN public.workout_session s ON s.id = w.session_id
  WHERE w.day <> s.day
  -- 行 (RLS を越える postgres で見る)
  UNION ALL
  SELECT 'row: user_id が NULL なのは exercise の共有の行だけ', count(*) = 0, string_agg(relname, ',')
  FROM tbl
  WHERE relname <> 'exercise'
    AND (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I WHERE user_id IS NULL', relname), false, true, '')))[1]::text::int > 0
)
SELECT name, ok, detail FROM checks
UNION ALL
-- 11. 関数が docker (リハーサル) と同じか。ok は常に t で、detail の md5 を本番とリハーサルで見比べる (P7)
SELECT 'md5: public と private の関数の定義', true,
       md5(string_agg(pg_get_functiondef(p.oid), E'\n' ORDER BY p.oid::regprocedure::text))
FROM pg_proc p WHERE p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
ORDER BY ok, name;
