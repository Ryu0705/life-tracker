-- docker の素の postgres:17 で migration を確かめるための、Supabase の写し（migration ではない・本番に流さない）
-- 本番の姿は 2026-10-19 に読むだけの SQL で確かめた（docs/auth-multiuser-implementation-plan.md §1-1）
-- 写すもの: ロール / auth.users と auth.uid() / extensions・auth・public の USAGE / public の既定の権限（postgres の行）

-- ロール。本番の anon・authenticated は NOBYPASSRLS、service_role は BYPASSRLS
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
-- 本番の写し（pg_dump）の既定の権限・GRANT に出てくる。無いと pg_restore がエラーを数える（P3）
CREATE ROLE supabase_admin NOLOGIN;
CREATE ROLE dashboard_user NOLOGIN;

-- auth: 外部キーの先と auth.uid() だけ。auth.uid() は本番の定義の写し（claim.sub と claims の両方を読む）
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $function$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$function$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- extensions: 0001 の pgcrypto・0014 の btree_gist の置き場
CREATE SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- public: 本番は PUBLIC と 3 ロールに USAGE
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- public の既定の権限（本番の FOR ROLE postgres の行: 表 arwdDxtm・関数 X・シーケンス rwU）。
-- 0014 がこれを外せることを確かめるため、同じ形で置く。関数は組み込みの既定で PUBLIC にも EXECUTE が付く
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO anon, authenticated, service_role;

-- 確かめの人（UID は repo に書かない本人のものではなく、テスト用の決まった値）
-- owner: 0014 の '__OWNER_UID__' を置き換える先（本番の本人の役）
INSERT INTO auth.users (id) VALUES ('00000000-0000-4000-8000-00000000000a');
