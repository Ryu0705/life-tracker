#!/usr/bin/env bash
# migration の確かめ（docker の postgres:17。本番には触れない。docs/auth-multiuser-implementation-plan.md §1-1）
#
# 使い方（repo のどこからでも）:
#   supabase/test/run.sh                    空の DB に stub → 0001〜最新 → plpgsql_check → multiuser_test.sql（あれば）
#   supabase/test/run.sh --upto 0013        0013 まで流して止める（確かめの SQL は流さない）
#   supabase/test/run.sh --rollback [N]     N の前まで → 形の写し → N → rollback/N_down.sql → 形の写し → 差分が 0（N の既定は 0014）
#   supabase/test/run.sh --dump <file>      本番の写し（pg_dump -Fc）を stub の上に戻し、--from（既定 0013）から流す（リハーサル）
#                                           --from が 0013 なら「0013 の前の全部 = 0014 の後の本人」、それより後なら「流す前と後で表ごとの行数が同じ」を見る
#   --grow <表>=<N>                         --dump の行数の照合で、その表は流した後が N 行多い（行を足す migration。くり返し指定できる。例: --grow exercise=1）
#   --owner <uuid>                          '__OWNER_UID__' をこの UID にし、auth.users に入れる（本番の写しのリハーサル用。UID は repo に書かない）
#   --keep                                  終わっても container を残す（docker exec -it lt-pgtest psql -U postgres で見る）
#
# 止まったら非 0 で終わる（psql -v ON_ERROR_STOP=1）。0014 と multiuser_test.sql の '__OWNER_UID__' は auth_stub.sql の owner（--owner があればそれ）に置き換えて流す
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPA="$(cd "$HERE/.." && pwd)"
IMAGE=lt-pg17-check
NAME=lt-pgtest
OWNER=00000000-0000-4000-8000-00000000000a

UPTO=""; FROM=""; DUMP=""; ROLLBACK=""; KEEP=0; GROW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upto) UPTO="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --dump) DUMP="$2"; shift 2 ;;
    --rollback)
      if [[ "${2:-}" =~ ^[0-9]{4}$ ]]; then ROLLBACK="$2"; shift 2; else ROLLBACK=0014; shift; fi ;;
    --grow) GROW="$GROW $2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$DUMP" ] && [ -z "$FROM" ]; then FROM=0013; fi

TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; if [ "$KEEP" = 0 ]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== image $IMAGE を作る（初回だけ）"
  docker build -q -t "$IMAGE" "$HERE" >/dev/null
fi
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -v "$SUPA:/work:ro" "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$NAME" pg_isready -U postgres -q 2>/dev/null && break
  sleep 1
done
# 初期化の途中の再起動を避ける（pg_isready は最初の一時起動でも通る）
sleep 2
until docker exec "$NAME" psql -U postgres -tAc 'select 1' >/dev/null 2>&1; do sleep 1; done

psql_file() { # $1 = /work からの相対パス。__OWNER_UID__ を置き換えて流す
  echo "== $1"
  docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q -X \
    < <(sed "s/__OWNER_UID__/$OWNER/g" "$SUPA/$1")
}
psql_c() { docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q -X -tA -c "$1"; }
counts() { # 表 | 全部の行 | 本人の行 | 共有の種目
  docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -X -q -tA -F '|' < <(sed "s/__OWNER_UID__/$OWNER/g" "$HERE/counts.sql")
}
schema_dump() { # 形の写し: 順序に依らない形にそろえた pg_dump と、既定の権限 (グローバルの行は pg_dump の --schema に出ない)
  docker exec "$NAME" pg_dump -U postgres --schema-only --schema=public --schema=private --no-owner \
    | python3 -I "$HERE/normalize_schema.py"
  echo "== pg_default_acl"
  psql_c "SELECT defaclrole::regrole, coalesce(defaclnamespace::regnamespace::text, '(global)'), defaclobjtype, defaclacl
          FROM pg_default_acl ORDER BY 1, 2, 3"
}

psql_file test/auth_stub.sql
psql_c "INSERT INTO auth.users (id) VALUES ('$OWNER') ON CONFLICT DO NOTHING"

if [ -n "$DUMP" ]; then
  # 0014 の後の写しを戻す前に、本番を 0014 の後の形にそろえる (0013 から流すときはしない。0014 がするのを確かめる)
  # - btree_gist: 睡眠の EXCLUDE が使う。写しは public と private だけで extensions を含まない
  # - 既定の権限: 写しの GRANT は「持ち主だけ」からの差分で書かれるが、pg_restore が表・view・関数を作った時点で stub の既定の権限
  #   (0014 の前の本番の形。anon・authenticated に ALL) が先に付き、写しの GRANT はそれを外さない (2026-10-23 の模擬の写しで、anon が表を読め、
  #   authenticated が view に書けた)。public の既定の権限を空にしてから戻す (本番の既定の権限は写しの最後で戻る)。
  #   グローバルの関数の行 (0014 の b2 の 1 行目) は --schema の写しに出ないので、ここで本番と同じにする
  if [[ "$FROM" > "0014" ]]; then
    psql_c "CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions"
    psql_c "ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated, service_role;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;"
  fi
  echo "== restore $DUMP"
  docker cp "$DUMP" "$NAME:/tmp/prod.dump"
  # 本番の写しは public と private だけ。--schema で絞った写しは CREATE SCHEMA public を含むので、その 1 行を TOC から外して
  # stub の public に戻す (GRANT と既定の権限の TOC は残す。SQL レビュー S1)
  docker exec "$NAME" pg_restore -l /tmp/prod.dump | grep -v -E '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - public ' > "$TMPD/toc"
  docker cp "$TMPD/toc" "$NAME:/tmp/toc"
  docker exec "$NAME" pg_restore -U postgres -d postgres --no-owner --exit-on-error -L /tmp/toc /tmp/prod.dump \
    || { echo "pg_restore failed" >&2; exit 1; }
fi

MIGRATIONS=$(cd "$SUPA/migrations" && ls [0-9][0-9][0-9][0-9]_*.sql | sort)
for f in $MIGRATIONS; do
  n="${f%%_*}"
  if [ -n "$FROM" ] && [[ "$n" < "$FROM" ]]; then continue; fi
  # 0013 の直前の行数 (0014 の後に本人の行数と照らす。P11)
  if [ "$n" = "0013" ] && [ -z "$ROLLBACK" ]; then counts > "$TMPD/counts-before.txt"; fi
  # 0014 より後から流すリハーサルは、流す前の行数 (後で表ごとに同じかを見る)
  if [ -n "$DUMP" ] && [ "$n" = "$FROM" ] && [[ "$FROM" > "0013" ]]; then counts > "$TMPD/counts-same-before.txt"; fi
  if [ -n "$ROLLBACK" ] && [ "$n" = "$ROLLBACK" ]; then
    schema_dump > "$TMPD/before.txt"
  fi
  psql_file "migrations/$f"
  # 0014 の直後の行数 (後の migration が行を足しても照合がずれないように、ここで取る)
  if [ "$n" = "0014" ] && [ -f "$TMPD/counts-before.txt" ]; then counts > "$TMPD/counts-after.txt"; fi
  if [ -n "$UPTO" ] && [ "$n" = "$UPTO" ]; then echo "== --upto $UPTO で止めた"; exit 0; fi
  if [ -n "$ROLLBACK" ] && [ "$n" = "$ROLLBACK" ]; then
    psql_file "rollback/${n}_down.sql"
    schema_dump > "$TMPD/after.txt"
    if diff -u "$TMPD/before.txt" "$TMPD/after.txt"; then echo "== 戻しの差分 0"; exit 0
    else echo "== 戻しの差分あり" >&2; exit 1; fi
  fi
done
if [ -n "$ROLLBACK" ]; then echo "== --rollback $ROLLBACK: migrations/${ROLLBACK}_*.sql が無い" >&2; exit 1; fi

# 0014 より後から流したリハーサル: 表ごとの行数が流す前と同じ (列を足すだけの migration で行が増減していない)。--grow の表は N 行多い
if [ -f "$TMPD/counts-same-before.txt" ]; then
  echo "== 行数の照合 (流す前 = 流した後)"
  counts > "$TMPD/counts-same-after.txt"
  python3 -I - "$TMPD/counts-same-before.txt" "$TMPD/counts-same-after.txt" $GROW <<'PY'
import sys
before = {l.split('|')[0]: l.split('|')[1] for l in open(sys.argv[1]).read().split() if l}
after = {l.split('|')[0]: l.split('|')[1] for l in open(sys.argv[2]).read().split() if l}
grow = {k: int(v) for k, v in (a.split('=') for a in sys.argv[3:])}
bad = []
for t in sorted(set(before) | set(after)):
    want = str(int(before[t]) + grow[t]) if t in grow and t in before else before.get(t)
    line = f"{t}: before {before.get(t, '-')} / after {after.get(t, '-')}" + (f" (+{grow[t]})" if t in grow else "")
    print(line)
    if after.get(t) != want:
        bad.append(t)
if bad:
    print("== 行数が合わない: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
fi

# 付け替えの前後の行数: 0013 の前の全部の行 = 0014 の後の本人の行 (exercise と、0013 で消した表を除く)
if [ -f "$TMPD/counts-before.txt" ]; then
  echo "== 行数の照合 (0013 の前の全部 = 0014 の後の本人)"
  python3 -I - "$TMPD/counts-before.txt" "$TMPD/counts-after.txt" <<'PY'
import sys
before = {l.split('|')[0]: l.split('|') for l in open(sys.argv[1]).read().split() if l}
after = {l.split('|')[0]: l.split('|') for l in open(sys.argv[2]).read().split() if l}
bad = []
for t, row in sorted(before.items()):
    if t in ('exercise', 'pattern_template_membership'):
        continue
    total, owner = int(row[1]), (after.get(t) or [t, '', ''])[2]
    line = f"{t}: before {total} / owner after {owner or '-'}"
    print(line)
    if str(total) != owner:
        bad.append(line)
ex_b, ex_a = before.get('exercise'), after.get('exercise')
if ex_b and ex_a:
    print(f"exercise: before {ex_b[1]} / shared after {ex_a[3]} / owner after {ex_a[2]}")
    if ex_b[1] != ex_a[3]:
        bad.append('exercise shared')
if bad:
    print("== 行数が合わない: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
fi

# plpgsql の関数を実行せずに検査する（関数の SET search_path を尊重する。SET CONSTRAINTS の名前は見ない・P7）
# トリガーの関数は、付いている表を渡して検査する（NEW の列を見る。0015）
echo "== plpgsql_check"
psql_c "CREATE EXTENSION IF NOT EXISTS plpgsql_check WITH SCHEMA extensions"
CHECK=$(psql_c "
  SELECT p.oid::regprocedure || ' ' || c.lineno || ': ' || c.message
  FROM pg_proc p
  CROSS JOIN LATERAL extensions.plpgsql_check_function_tb(p.oid) c
  WHERE p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
    AND p.prorettype <> 'trigger'::regtype
    AND p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
    AND c.level = 'error'
  UNION ALL
  SELECT p.oid::regprocedure || ' on ' || t.tgrelid::regclass || ' ' || c.lineno || ': ' || c.message
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  CROSS JOIN LATERAL extensions.plpgsql_check_function_tb(p.oid, t.tgrelid) c
  WHERE NOT t.tgisinternal
    AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
    AND p.pronamespace IN ('public'::regnamespace, 'private'::regnamespace)
    AND c.level = 'error'")
psql_c "DROP EXTENSION plpgsql_check"
if [ -n "$CHECK" ]; then echo "$CHECK"; echo "== plpgsql_check: error あり" >&2; exit 1; fi
echo "== plpgsql_check: error 0"

if [ -f "$HERE/multiuser_test.sql" ]; then psql_file test/multiuser_test.sql; fi

# 機械の確かめ (本番でも同じ SELECT を流す)。ok が f の行があれば止まる
echo "== checks.sql"
RESULT=$(docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -X -tA -F ' | ' < "$HERE/checks.sql")
echo "$RESULT"
if echo "$RESULT" | grep -q ' | f | '; then echo "== checks.sql: f あり" >&2; exit 1; fi
echo "== OK"
