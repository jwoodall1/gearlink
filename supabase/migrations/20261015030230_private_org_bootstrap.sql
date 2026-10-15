create function private.create_organization_impl(org_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare new_org uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  insert into public.organizations(name) values (trim(org_name)) returning id into new_org;
  insert into public.organization_members(organization_id, user_id, role) values (new_org, (select auth.uid()), 'admin');
  return new_org;
end;
$$;
revoke all on function private.create_organization_impl(text) from public, anon;
grant execute on function private.create_organization_impl(text) to authenticated;

create or replace function public.create_organization(org_name text)
returns uuid language sql security invoker set search_path = '' as $$
  select private.create_organization_impl(org_name)
$$;
revoke all on function public.create_organization(text) from public, anon;
grant execute on function public.create_organization(text) to authenticated;
