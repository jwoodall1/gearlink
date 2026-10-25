-- Minimal Supabase Auth contract for a disposable local PostgreSQL cluster.
-- Never run this fixture on a hosted project.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to authenticated,anon;
grant execute on function auth.uid() to authenticated,anon;
-- The existing hosted-only trigger-function permission migration expects this.
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin return; end $$;
