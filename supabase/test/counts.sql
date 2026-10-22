-- 表ごとの行数と、本人の行数 (計画 §3-1 の 1・3、§3-2 の 4・5。P11・SQL レビュー S5)。読むだけの SELECT 1 つ
-- 0014 の前 (user_id が無い) と後の両方で流せる。owner_rows は user_id がある表だけ。exercise の shared_rows は共有の行
-- 0014 の後の owner_rows が、0014 の前の total と一致すること (exercise と、0013 で消した表を除く) を見る
-- '__OWNER_UID__' は本人の UID に置き換えて流す (docker は run.sh が置き換える。UID は repo に書かない)
SELECT c.relname AS table_name,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', c.relname), false, true, '')))[1]::text::int AS total,
       CASE WHEN EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'user_id' AND NOT a.attisdropped)
            THEN (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I WHERE user_id = %L::uuid', c.relname, '__OWNER_UID__'), false, true, '')))[1]::text::int
       END AS owner_rows,
       CASE WHEN c.relname = 'exercise'
             AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'user_id' AND NOT a.attisdropped)
            THEN (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.exercise WHERE user_id IS NULL', false, true, '')))[1]::text::int
       END AS shared_rows
FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
ORDER BY 1;
