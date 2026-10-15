-- The event trigger is owned by postgres and remains active; the function itself
-- does not need direct API-role EXECUTE grants.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
