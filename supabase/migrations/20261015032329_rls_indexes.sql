-- Keep tenant lookups and composite foreign key checks indexed as these tables grow.
create index organization_members_user_id on public.organization_members(user_id);
create index assignments_checked_out_by on public.equipment_assignments(checked_out_by);
create index assignments_returned_by on public.equipment_assignments(returned_by);
create index assignments_org_athlete on public.equipment_assignments(organization_id, athlete_id);
create index assignments_org_equipment on public.equipment_assignments(organization_id, equipment_id);
create index events_actor_id on public.equipment_events(actor_id);
create index events_org_assignment on public.equipment_events(organization_id, assignment_id);
create index events_org_athlete on public.equipment_events(organization_id, athlete_id);
create index events_org_equipment on public.equipment_events(organization_id, equipment_id);
create index tags_org_equipment on public.equipment_tags(organization_id, equipment_id);

-- Avoid overlapping SELECT policies while retaining organization and role checks.
drop policy "members read equipment" on public.equipment;
drop policy "members read tags" on public.equipment_tags;
drop policy "members read assignments" on public.equipment_assignments;

drop policy "admins manage memberships" on public.organization_members;
create policy "admins insert memberships" on public.organization_members for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy "admins update memberships" on public.organization_members for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy "admins delete memberships" on public.organization_members for delete to authenticated
  using (private.is_org_admin(organization_id));

drop policy "admins manage athletes" on public.athletes;
create policy "admins insert athletes" on public.athletes for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy "admins update athletes" on public.athletes for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy "admins delete athletes" on public.athletes for delete to authenticated
  using (private.is_org_admin(organization_id));
