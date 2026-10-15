create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'coach')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create table public.athletes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  first_name text not null check (length(trim(first_name)) between 1 and 80),
  last_name text not null check (length(trim(last_name)) between 1 and 80),
  team text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.equipment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  category text not null,
  size text,
  color text,
  condition text not null default 'good' check (condition in ('new', 'good', 'fair', 'needs_repair', 'retired')),
  status text not null default 'available' check (status in ('available', 'checked_out', 'maintenance', 'retired')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.equipment_tags (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  equipment_id uuid not null,
  uid text not null unique check (length(uid) between 4 and 64),
  is_active boolean not null default true,
  registered_at timestamptz not null default now(),
  disabled_at timestamptz,
  foreign key (organization_id, equipment_id) references public.equipment(organization_id, id) on delete cascade,
  unique (organization_id, id)
);

create table public.equipment_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  equipment_id uuid not null,
  athlete_id uuid not null,
  checked_out_by uuid not null references auth.users(id),
  checked_out_at timestamptz not null default now(),
  returned_by uuid references auth.users(id),
  returned_at timestamptz,
  foreign key (organization_id, equipment_id) references public.equipment(organization_id, id),
  foreign key (organization_id, athlete_id) references public.athletes(organization_id, id),
  unique (organization_id, id),
  check ((returned_at is null) = (returned_by is null))
);
create unique index equipment_one_open_assignment on public.equipment_assignments(equipment_id) where returned_at is null;
create index equipment_org_created on public.equipment(organization_id, created_at desc);
create index athletes_org_name on public.athletes(organization_id, last_name, first_name);
create index assignments_org_open on public.equipment_assignments(organization_id, checked_out_at desc) where returned_at is null;

create table public.equipment_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  equipment_id uuid not null,
  athlete_id uuid,
  assignment_id uuid,
  event_type text not null check (event_type in ('registered', 'tagged', 'checkout', 'return', 'updated', 'tag_disabled')),
  actor_id uuid not null references auth.users(id),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (organization_id, equipment_id) references public.equipment(organization_id, id),
  foreign key (organization_id, athlete_id) references public.athletes(organization_id, id),
  foreign key (organization_id, assignment_id) references public.equipment_assignments(organization_id, id)
);
create index equipment_events_org_recent on public.equipment_events(organization_id, created_at desc);

create function private.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organization_members m where m.organization_id = target_org and m.user_id = (select auth.uid()))
$$;
create function private.is_org_admin(target_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organization_members m where m.organization_id = target_org and m.user_id = (select auth.uid()) and m.role = 'admin')
$$;
revoke all on function private.is_org_member(uuid) from public, anon;
revoke all on function private.is_org_admin(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_org_member(uuid), private.is_org_admin(uuid) to authenticated;

create function public.create_organization(org_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare new_org uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  insert into public.organizations(name) values (trim(org_name)) returning id into new_org;
  insert into public.organization_members(organization_id, user_id, role) values (new_org, (select auth.uid()), 'admin');
  return new_org;
end;
$$;
revoke all on function public.create_organization(text) from public, anon;
grant execute on function public.create_organization(text) to authenticated;

create function public.checkout_equipment(target_equipment uuid, target_athlete uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare org_id uuid; assignment_id uuid;
begin
  select e.organization_id into org_id from public.equipment e where e.id = target_equipment and e.status = 'available' for update;
  if org_id is null or not private.is_org_member(org_id) then raise exception 'Equipment is unavailable'; end if;
  if not exists (select 1 from public.athletes a where a.id = target_athlete and a.organization_id = org_id and a.active) then raise exception 'Athlete is unavailable'; end if;
  insert into public.equipment_assignments(organization_id, equipment_id, athlete_id, checked_out_by)
    values (org_id, target_equipment, target_athlete, (select auth.uid())) returning id into assignment_id;
  update public.equipment set status = 'checked_out', updated_at = now() where id = target_equipment;
  insert into public.equipment_events(organization_id, equipment_id, athlete_id, assignment_id, event_type, actor_id)
    values (org_id, target_equipment, target_athlete, assignment_id, 'checkout', (select auth.uid()));
  return assignment_id;
end;
$$;

create function public.return_equipment(target_assignment uuid)
returns void language plpgsql security invoker set search_path = '' as $$
declare current_assignment public.equipment_assignments%rowtype;
begin
  select * into current_assignment from public.equipment_assignments where id = target_assignment and returned_at is null for update;
  if not found or not private.is_org_member(current_assignment.organization_id) then raise exception 'Assignment is unavailable'; end if;
  update public.equipment_assignments set returned_at = now(), returned_by = (select auth.uid()) where id = target_assignment;
  update public.equipment set status = 'available', updated_at = now() where id = current_assignment.equipment_id;
  insert into public.equipment_events(organization_id, equipment_id, athlete_id, assignment_id, event_type, actor_id)
    values (current_assignment.organization_id, current_assignment.equipment_id, current_assignment.athlete_id, target_assignment, 'return', (select auth.uid()));
end;
$$;

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.athletes enable row level security;
alter table public.equipment enable row level security;
alter table public.equipment_tags enable row level security;
alter table public.equipment_assignments enable row level security;
alter table public.equipment_events enable row level security;

create policy "members read organizations" on public.organizations for select to authenticated using (private.is_org_member(id));
create policy "members read memberships" on public.organization_members for select to authenticated using (private.is_org_member(organization_id));
create policy "admins manage memberships" on public.organization_members for all to authenticated using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy "members read athletes" on public.athletes for select to authenticated using (private.is_org_member(organization_id));
create policy "admins manage athletes" on public.athletes for all to authenticated using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy "members read equipment" on public.equipment for select to authenticated using (private.is_org_member(organization_id));
create policy "staff manage equipment" on public.equipment for all to authenticated using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id));
create policy "members read tags" on public.equipment_tags for select to authenticated using (private.is_org_member(organization_id));
create policy "staff manage tags" on public.equipment_tags for all to authenticated using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id));
create policy "members read assignments" on public.equipment_assignments for select to authenticated using (private.is_org_member(organization_id));
create policy "staff manage assignments" on public.equipment_assignments for all to authenticated using (private.is_org_member(organization_id)) with check (private.is_org_member(organization_id));
create policy "members read events" on public.equipment_events for select to authenticated using (private.is_org_member(organization_id));
create policy "staff record events" on public.equipment_events for insert to authenticated with check (private.is_org_member(organization_id) and actor_id = (select auth.uid()));

grant select, insert, update, delete on public.organizations, public.organization_members, public.athletes, public.equipment, public.equipment_tags, public.equipment_assignments to authenticated;
grant select, insert on public.equipment_events to authenticated;
grant execute on function public.checkout_equipment(uuid, uuid), public.return_equipment(uuid) to authenticated;
