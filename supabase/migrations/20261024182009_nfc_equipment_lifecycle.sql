-- NFC lifecycle foundation. Apply only after the preflight succeeds and clients
-- have moved equipment/tag/assignment mutations to the guarded RPCs below.
-- Existing UUIDs, raw UIDs, legacy inventory and assignment history are retained.
begin;

create function private.normalize_tag_uid(value text)
returns text language plpgsql immutable strict set search_path = '' as $$
declare normalized text := upper(translate(value, ' :-', ''));
begin
  if value !~ '^[0-9A-Fa-f :\-]+$' or normalized !~ '^[0-9A-F]{4,64}$' or length(normalized) % 2 <> 0 then
    raise exception 'GL_INVALID_UID' using errcode = '22023';
  end if;
  return normalized;
end;
$$;
revoke all on function private.normalize_tag_uid(text) from public, anon, authenticated;

-- Abort rather than silently reconcile legacy collisions or malformed UIDs.
do $$
begin
  perform private.normalize_tag_uid(uid) from public.equipment_tags;
  if exists (
    select 1 from public.equipment_tags where is_active
    group by private.normalize_tag_uid(uid) having count(*) > 1
  ) then raise exception 'GL_PREFLIGHT_DUPLICATE_ACTIVE_UID'; end if;
  if exists (
    select 1 from public.equipment_tags where is_active
    group by equipment_id having count(*) > 1
  ) then raise exception 'GL_PREFLIGHT_MULTIPLE_ACTIVE_TAGS'; end if;
end;
$$;

alter table public.equipment
  add column gearlink_id text unique,
  add column original_tag_uid text,
  add column registration_status text,
  add column brand text,
  add column model text,
  add column jersey_number text,
  add column serial_number text,
  add column purchase_year integer,
  add column purchase_price numeric(12,2),
  add constraint equipment_gearlink_format check (gearlink_id ~ '^GL-[0-9A-F]{6}-[0-9A-F]{16}$'),
  add constraint equipment_registration_state check (registration_status in ('pending_write','active','write_failed','retired')),
  add constraint equipment_nfc_identity_complete check (
    (gearlink_id is null and original_tag_uid is null and registration_status is null)
    or (gearlink_id is not null and original_tag_uid is not null and registration_status is not null
        and original_tag_uid ~ '^[0-9A-F]{6,64}$' and length(original_tag_uid) % 2 = 0
        and substring(gearlink_id from 4 for 6) = right(original_tag_uid, 6))
  ),
  add constraint equipment_purchase_year_valid check (purchase_year between 1900 and 9999),
  add constraint equipment_purchase_price_valid check (purchase_price >= 0),
  add constraint equipment_metadata_lengths check (
    length(brand) <= 120 and length(model) <= 120 and length(jersey_number) <= 20
    and length(serial_number) <= 120
  );
alter table public.equipment drop constraint equipment_status_check;
alter table public.equipment add constraint equipment_status_check
  check (status in ('available','checked_out','maintenance','retired','pending_registration'));
-- Existing clients count status=available. Pending records use a distinct status
-- so those clients remain accurate even before they know registration_status.
create index equipment_org_registration on public.equipment(organization_id, registration_status)
  where registration_status in ('pending_write','write_failed');

alter table public.equipment_tags
  add column physical_uid text generated always as (private.normalize_tag_uid(uid)) stored,
  add column technology text,
  add column write_verified_at timestamptz,
  add column activation_status text not null default 'available'
    check (activation_status in ('available','maintenance'));
alter table public.equipment_tags drop constraint equipment_tags_uid_key;
create unique index equipment_tags_active_uid on public.equipment_tags(physical_uid) where is_active;
create unique index equipment_tags_active_equipment on public.equipment_tags(equipment_id) where is_active;
create index equipment_tags_uid_history on public.equipment_tags(physical_uid);
alter table public.equipment_assignments add constraint assignment_return_after_issue
  check (returned_at is null or returned_at >= checked_out_at);

alter table public.equipment_events drop constraint equipment_events_event_type_check;
alter table public.equipment_events add constraint equipment_events_event_type_check check (
  event_type in ('registered','tagged','checkout','return','updated','tag_disabled',
                'registration_pending','write_failed','tag_replaced','transfer','retired')
);

-- Request ledger is private, not a new public business entity. An operation UUID
-- is bound to its actor and complete arguments. Exact retries return the original
-- result; reuse with different arguments fails without mutating data.
create table private.equipment_operations (
  request_id uuid primary key,
  organization_id uuid not null references public.organizations(id),
  actor_id uuid not null references auth.users(id),
  operation text not null,
  arguments jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table private.equipment_operations enable row level security;
revoke all on private.equipment_operations from public, anon, authenticated;
create index equipment_operations_org on private.equipment_operations(organization_id);
create index equipment_operations_actor on private.equipment_operations(actor_id);

-- Defense against accidental identity edits even inside privileged operations.
create function private.protect_equipment_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
     or new.gearlink_id is distinct from old.gearlink_id
     or new.original_tag_uid is distinct from old.original_tag_uid then
    raise exception 'GL_IMMUTABLE_IDENTITY' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.protect_equipment_identity() from public, anon, authenticated;
create trigger equipment_immutable_identity before update on public.equipment
  for each row execute function private.protect_equipment_identity();

-- Canonical complete edit payload. Explicit nulls clear optional attributes.
create function private.equipment_details(value jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare key text; text_value text; result jsonb := '{}'::jsonb; year_value integer; price_value numeric;
begin
  if value is null or jsonb_typeof(value) <> 'object' then raise exception 'GL_INVALID_DETAILS' using errcode='22023'; end if;
  for key in select jsonb_object_keys(value) loop
    if key not in ('name','category','size','color','condition','brand','model','jersey_number','serial_number','purchase_year','purchase_price','notes') then
      raise exception 'GL_INVALID_DETAILS' using errcode='22023';
    end if;
  end loop;
  foreach key in array array['category','size','color','condition','name','brand','model','jersey_number','serial_number','notes'] loop
    if value ? key and jsonb_typeof(value->key) not in ('string','null') then
      raise exception 'GL_INVALID_DETAILS' using errcode='22023';
    end if;
    text_value := nullif(btrim(value->>key),'');
    if key in ('category','size','color','condition') and text_value is null then
      raise exception 'GL_REQUIRED_EQUIPMENT_FIELDS' using errcode='22023';
    end if;
    if length(text_value) > (case when key='notes' then 4000 when key='jersey_number' then 20 else 120 end) then
      raise exception 'GL_INVALID_DETAILS' using errcode='22023';
    end if;
    result := result || jsonb_build_object(key,text_value);
  end loop;
  if result->>'condition' not in ('new','good','fair','needs_repair') then
    raise exception 'GL_INVALID_CONDITION' using errcode='22023';
  end if;
  if result->>'name' is null then
    result := result || jsonb_build_object('name',left((result->>'category') || ' · ' || (result->>'size'),120));
  end if;
  if value->>'purchase_year' is not null then
    if jsonb_typeof(value->'purchase_year') <> 'number' or (value->>'purchase_year') !~ '^[0-9]{4}$' then
      raise exception 'GL_INVALID_PURCHASE_YEAR' using errcode='22023';
    end if;
    year_value := (value->>'purchase_year')::integer;
    if year_value not between 1900 and 9999 then raise exception 'GL_INVALID_PURCHASE_YEAR' using errcode='22023'; end if;
  end if;
  if value->>'purchase_price' is not null then
    if jsonb_typeof(value->'purchase_price') <> 'number' or (value->>'purchase_price') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' then
      raise exception 'GL_INVALID_PURCHASE_PRICE' using errcode='22023';
    end if;
    price_value := (value->>'purchase_price')::numeric;
  end if;
  return result || jsonb_build_object('purchase_year',year_value,'purchase_price',price_value);
end;
$$;
revoke all on function private.equipment_details(jsonb) from public, anon, authenticated;

create function private.require_equipment_member(org_id uuid, admin_only boolean default false)
returns void language plpgsql set search_path = '' as $$
begin
  if auth.uid() is null or org_id is null or not private.is_org_member(org_id)
     or (admin_only and not private.is_org_admin(org_id)) then
    raise exception 'GL_NOT_AUTHORIZED' using errcode='42501';
  end if;
end;
$$;
revoke all on function private.require_equipment_member(uuid,boolean) from public, anon, authenticated;

create function private.equipment_snapshot(target uuid)
returns jsonb language sql set search_path = '' as $$
  select jsonb_build_object(
    'equipment',to_jsonb(e),
    'tag',(select to_jsonb(t) from public.equipment_tags t where t.equipment_id=e.id and t.is_active),
    'current_assignment',(select to_jsonb(a) from public.equipment_assignments a where a.equipment_id=e.id and a.returned_at is null)
  ) from public.equipment e where e.id=target
$$;
revoke all on function private.equipment_snapshot(uuid) from public, anon, authenticated;

create function private.replay_equipment_operation(req uuid, org_id uuid, op text, args jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare previous private.equipment_operations;
begin
  if req is null then raise exception 'GL_REQUEST_ID_REQUIRED' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('gearlink:operation:' || req::text,0));
  select * into previous from private.equipment_operations where request_id=req;
  if found then
    if previous.actor_id <> auth.uid() or previous.organization_id <> org_id
       or previous.operation <> op or previous.arguments <> args then
      raise exception 'GL_REQUEST_CONFLICT' using errcode='23505';
    end if;
    return previous.result;
  end if;
  return null;
end;
$$;
revoke all on function private.replay_equipment_operation(uuid,uuid,text,jsonb) from public, anon, authenticated;

create function private.begin_equipment_registration_impl(
  p_organization_id uuid, p_equipment_id uuid, p_gearlink_id text,
  p_physical_uid text, p_technology text, p_details jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid_value text; tag_row public.equipment_tags; equipment_row public.equipment;
        details public.equipment; violated text;
begin
  perform private.require_equipment_member(p_organization_id);
  uid_value := private.normalize_tag_uid(p_physical_uid);
  if uid_value is null or length(uid_value)<6 or p_equipment_id is null
     or p_gearlink_id is null or p_gearlink_id !~ '^GL-[0-9A-F]{6}-[0-9A-F]{16}$'
     or substring(p_gearlink_id from 4 for 6) <> right(uid_value,6)
     or p_technology is null or p_technology not in ('mifare','iso15693') then
    raise exception 'GL_INVALID_IDENTITY' using errcode='22023';
  end if;
  -- Serialize attempts for equivalent full UIDs, including different formatting.
  perform pg_advisory_xact_lock(hashtextextended('gearlink:tag:' || uid_value,0));
  select * into tag_row from public.equipment_tags where physical_uid=uid_value and is_active;
  if found then
    if tag_row.organization_id <> p_organization_id then raise exception 'GL_TAG_UNAVAILABLE' using errcode='42501'; end if;
    select * into equipment_row from public.equipment where id=tag_row.equipment_id for update;
    if not exists(select 1 from public.equipment_tags where id=tag_row.id and is_active) then raise exception 'GL_INACTIVE_TAG'; end if;
    if equipment_row.gearlink_id is null then raise exception 'GL_LEGACY_TAG_REQUIRES_MIGRATION'; end if;
    if equipment_row.registration_status='retired' then raise exception 'GL_EQUIPMENT_RETIRED'; end if;
    return private.equipment_snapshot(equipment_row.id);
  end if;
  if exists (select 1 from public.equipment_tags where physical_uid=uid_value) then
    raise exception 'GL_INACTIVE_TAG' using errcode='23505';
  end if;
  details := jsonb_populate_record(null::public.equipment, private.equipment_details(p_details));
  begin
    insert into public.equipment(id,organization_id,gearlink_id,original_tag_uid,registration_status,
      name,category,size,color,condition,status,brand,model,jersey_number,serial_number,purchase_year,purchase_price,notes)
    values(p_equipment_id,p_organization_id,p_gearlink_id,uid_value,'pending_write',
      details.name,details.category,details.size,details.color,details.condition,'pending_registration',
      details.brand,details.model,details.jersey_number,details.serial_number,details.purchase_year,details.purchase_price,details.notes);
  exception when unique_violation then
    get stacked diagnostics violated = constraint_name;
    if violated='equipment_gearlink_id_key' then raise exception 'GL_GEARLINK_ID_COLLISION' using errcode='23505'; end if;
    raise exception 'GL_REGISTRATION_CONFLICT' using errcode='23505';
  end;
  insert into public.equipment_tags(organization_id,equipment_id,uid,technology,activation_status)
    values(p_organization_id,p_equipment_id,uid_value,p_technology,
      case when details.condition='needs_repair' then 'maintenance' else 'available' end);
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id,details)
    values(p_organization_id,p_equipment_id,'registration_pending',auth.uid(),jsonb_build_object('gearlink_id',p_gearlink_id));
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.lookup_equipment_tag_impl(p_organization_id uuid, p_physical_uid text, p_gearlink_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid_value text; tag_row public.equipment_tags; equipment_row public.equipment;
begin
  perform private.require_equipment_member(p_organization_id);
  uid_value := private.normalize_tag_uid(p_physical_uid);
  if uid_value is null then raise exception 'GL_INVALID_UID' using errcode='22023'; end if;
  if p_gearlink_id is not null and p_gearlink_id !~ '^GL-[0-9A-F]{6}-[0-9A-F]{16}$' then
    raise exception 'GL_INVALID_GEARLINK_ID' using errcode='22023';
  end if;
  select * into tag_row from public.equipment_tags where physical_uid=uid_value and is_active;
  if not found then
    if p_gearlink_id is not null or exists(select 1 from public.equipment_tags where physical_uid=uid_value) then
      raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT';
    end if;
    return jsonb_build_object('resolution','unregistered');
  end if;
  if tag_row.organization_id <> p_organization_id then raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT'; end if;
  -- Serialize resolution with replacement/retirement and recheck the association.
  select * into equipment_row from public.equipment where id=tag_row.equipment_id for share;
  select * into tag_row from public.equipment_tags where id=tag_row.id and is_active;
  if not found then raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT'; end if;
  if equipment_row.gearlink_id is null then raise exception 'GL_LEGACY_TAG_REQUIRES_MIGRATION'; end if;
  if equipment_row.registration_status='retired' or equipment_row.status='retired' then raise exception 'GL_EQUIPMENT_RETIRED'; end if;
  if p_gearlink_id is not null and p_gearlink_id <> equipment_row.gearlink_id then raise exception 'GL_IDENTITY_CONFLICT'; end if;
  if equipment_row.registration_status='active' and (p_gearlink_id is null or tag_row.write_verified_at is null) then
    raise exception 'GL_TAG_CONTENT_MISMATCH';
  end if;
  return private.equipment_snapshot(equipment_row.id) || jsonb_build_object('resolution',
    case when equipment_row.registration_status='active' then 'registered' else 'pending' end);
end;
$$;

create function private.confirm_equipment_registration_impl(
  p_equipment_id uuid, p_tag_id uuid, p_physical_uid text, p_gearlink_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment; tag_row public.equipment_tags; uid_value text;
begin
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  perform private.require_equipment_member(equipment_row.organization_id);
  uid_value := private.normalize_tag_uid(p_physical_uid);
  select * into tag_row from public.equipment_tags where id=p_tag_id and equipment_id=p_equipment_id and is_active for update;
  if not found or uid_value is null or tag_row.physical_uid <> uid_value
     or p_gearlink_id is null or equipment_row.gearlink_id is distinct from p_gearlink_id then
    raise exception 'GL_IDENTITY_CONFLICT';
  end if;
  if equipment_row.registration_status='active' and tag_row.write_verified_at is not null then
    return private.equipment_snapshot(p_equipment_id);
  end if;
  if equipment_row.registration_status is null or equipment_row.registration_status not in ('pending_write','write_failed')
     or equipment_row.status <> 'pending_registration' then raise exception 'GL_REGISTRATION_NOT_PENDING'; end if;
  -- The client must have completed real NFC read-back before calling this RPC.
  -- This transaction enforces state/identity consistency, not radio attestation.
  update public.equipment_tags set write_verified_at=now() where id=tag_row.id;
  update public.equipment set registration_status='active',status=tag_row.activation_status,updated_at=clock_timestamp() where id=p_equipment_id;
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id,details)
    values(equipment_row.organization_id,p_equipment_id,'registered',auth.uid(),jsonb_build_object('tag_id',tag_row.id,'gearlink_id',p_gearlink_id));
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.record_equipment_write_failure_impl(
  p_equipment_id uuid, p_tag_id uuid, p_physical_uid text, p_gearlink_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment; tag_row public.equipment_tags;
begin
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  perform private.require_equipment_member(equipment_row.organization_id);
  select * into tag_row from public.equipment_tags where id=p_tag_id and equipment_id=p_equipment_id and is_active;
  if not found or private.normalize_tag_uid(p_physical_uid) is distinct from tag_row.physical_uid
     or p_gearlink_id is null or equipment_row.gearlink_id is distinct from p_gearlink_id then raise exception 'GL_IDENTITY_CONFLICT'; end if;
  -- A delayed failure must never demote a subsequently verified registration.
  if equipment_row.registration_status in ('active','write_failed') then return private.equipment_snapshot(p_equipment_id); end if;
  if equipment_row.registration_status is distinct from 'pending_write' then raise exception 'GL_REGISTRATION_NOT_PENDING'; end if;
  update public.equipment set registration_status='write_failed',updated_at=clock_timestamp() where id=p_equipment_id;
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id)
    values(equipment_row.organization_id,p_equipment_id,'write_failed',auth.uid());
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.update_equipment_details_impl(p_equipment_id uuid, p_expected_updated_at timestamptz, p_details jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment; details public.equipment; old_details jsonb;
begin
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  perform private.require_equipment_member(equipment_row.organization_id);
  if p_expected_updated_at is null or equipment_row.updated_at <> p_expected_updated_at then raise exception 'GL_STALE_EQUIPMENT'; end if;
  if equipment_row.status='retired' then raise exception 'GL_EQUIPMENT_RETIRED'; end if;
  details := jsonb_populate_record(null::public.equipment,private.equipment_details(p_details));
  old_details := to_jsonb(equipment_row) - array['id','organization_id','gearlink_id','original_tag_uid','registration_status','created_at','updated_at'];
  update public.equipment set name=details.name,category=details.category,size=details.size,color=details.color,
    condition=details.condition,brand=details.brand,model=details.model,jersey_number=details.jersey_number,
    serial_number=details.serial_number,purchase_year=details.purchase_year,purchase_price=details.purchase_price,
    notes=details.notes,
    status=case when status='available' and details.condition='needs_repair' then 'maintenance' else status end,
    updated_at=clock_timestamp() where id=p_equipment_id;
  if equipment_row.registration_status in ('pending_write','write_failed') then
    update public.equipment_tags set activation_status=case when details.condition='needs_repair' then 'maintenance' else activation_status end
      where equipment_id=p_equipment_id and is_active;
  end if;
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id,details)
    values(equipment_row.organization_id,p_equipment_id,'updated',auth.uid(),jsonb_build_object('before',old_details,'after',private.equipment_details(p_details)));
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.replace_equipment_tag_impl(p_equipment_id uuid, p_expected_tag_id uuid, p_physical_uid text, p_technology text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment; old_tag public.equipment_tags; existing_tag public.equipment_tags;
        uid_value text; new_tag_id uuid;
begin
  uid_value := private.normalize_tag_uid(p_physical_uid);
  if uid_value is null or length(uid_value)<6 or p_technology is null or p_technology not in ('mifare','iso15693') then raise exception 'GL_INVALID_IDENTITY'; end if;
  select * into equipment_row from public.equipment where id=p_equipment_id;
  perform private.require_equipment_member(equipment_row.organization_id,true);
  -- Same global order as registration: target UID, then equipment, then tags.
  perform pg_advisory_xact_lock(hashtextextended('gearlink:tag:' || uid_value,0));
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  select * into old_tag from public.equipment_tags where equipment_id=p_equipment_id and is_active for update;
  if not found or equipment_row.gearlink_id is null then raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT'; end if;
  -- An exact retry with the old tag ID resumes the already-created replacement.
  if old_tag.physical_uid=uid_value and equipment_row.registration_status in ('pending_write','write_failed')
     and exists(select 1 from public.equipment_events where equipment_id=p_equipment_id and event_type='tag_replaced'
       and details->>'previous_tag_id'=p_expected_tag_id::text and details->>'pending_tag_id'=old_tag.id::text) then
    return private.equipment_snapshot(p_equipment_id);
  end if;
  if old_tag.id is distinct from p_expected_tag_id then raise exception 'GL_STALE_TAG'; end if;
  if equipment_row.registration_status is distinct from 'active' or equipment_row.status not in ('available','maintenance')
     or exists(select 1 from public.equipment_assignments where equipment_id=p_equipment_id and returned_at is null) then
    raise exception 'GL_RETURN_BEFORE_TAG_REPLACEMENT';
  end if;
  if exists(select 1 from public.equipment_tags where physical_uid=uid_value and is_active) then raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT'; end if;
  -- Historical UIDs from another organization must not be claimed through replacement.
  if exists(select 1 from public.equipment_tags where physical_uid=uid_value and organization_id<>equipment_row.organization_id) then raise exception 'GL_TAG_UNAVAILABLE_OR_CONFLICT'; end if;
  update public.equipment_tags set is_active=false,disabled_at=now() where id=old_tag.id;
  insert into public.equipment_tags(organization_id,equipment_id,uid,technology,activation_status)
    values(equipment_row.organization_id,p_equipment_id,uid_value,p_technology,equipment_row.status) returning id into new_tag_id;
  update public.equipment set registration_status='pending_write',status='pending_registration',updated_at=clock_timestamp() where id=p_equipment_id;
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id,details)
    values(equipment_row.organization_id,p_equipment_id,'tag_replaced',auth.uid(),jsonb_build_object('previous_tag_id',old_tag.id,'pending_tag_id',new_tag_id));
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.retire_equipment_impl(p_equipment_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment;
begin
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  perform private.require_equipment_member(equipment_row.organization_id,true);
  if equipment_row.status='retired' then return private.equipment_snapshot(p_equipment_id); end if;
  if exists(select 1 from public.equipment_assignments where equipment_id=p_equipment_id and returned_at is null) then raise exception 'GL_RETURN_BEFORE_RETIREMENT'; end if;
  update public.equipment set status='retired',registration_status=case when gearlink_id is null then null else 'retired' end,updated_at=clock_timestamp() where id=p_equipment_id;
  update public.equipment_tags set is_active=false,disabled_at=now() where equipment_id=p_equipment_id and is_active;
  insert into public.equipment_events(organization_id,equipment_id,event_type,actor_id) values(equipment_row.organization_id,p_equipment_id,'retired',auth.uid());
  return private.equipment_snapshot(p_equipment_id);
end;
$$;

create function private.equipment_assignment_operation_impl(
  p_operation text, p_equipment_id uuid, p_athlete_id uuid,
  p_expected_assignment_id uuid, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare equipment_row public.equipment; active_row public.equipment_assignments;
        args jsonb; receipt jsonb; new_assignment uuid; event_time timestamptz;
begin
  if p_operation is null or p_operation not in ('assign','return','transfer') then raise exception 'GL_INVALID_OPERATION'; end if;
  if p_operation='return' then
    select equipment_id into p_equipment_id from public.equipment_assignments where id=p_expected_assignment_id;
  end if;
  select * into equipment_row from public.equipment where id=p_equipment_id;
  perform private.require_equipment_member(equipment_row.organization_id);
  args := jsonb_build_object('equipment_id',p_equipment_id,'athlete_id',p_athlete_id,'expected_assignment_id',p_expected_assignment_id);
  receipt := private.replay_equipment_operation(p_request_id,equipment_row.organization_id,p_operation,args);
  if receipt is not null then return receipt; end if;
  -- Every lifecycle operation acquires equipment before assignment rows.
  select * into equipment_row from public.equipment where id=p_equipment_id for update;
  select * into active_row from public.equipment_assignments where equipment_id=p_equipment_id and returned_at is null for update;
  if p_operation='assign' then
    if active_row.id is not null or equipment_row.status <> 'available' then raise exception 'GL_EQUIPMENT_UNAVAILABLE'; end if;
  else
    if p_expected_assignment_id is null or active_row.id is distinct from p_expected_assignment_id then raise exception 'GL_STALE_ASSIGNMENT'; end if;
  end if;
  if p_operation in ('assign','transfer') then
    if equipment_row.condition not in ('new','good','fair') or equipment_row.status='retired'
       or (equipment_row.gearlink_id is not null and (
         equipment_row.registration_status is distinct from 'active'
         or not exists(select 1 from public.equipment_tags where equipment_id=p_equipment_id and is_active and write_verified_at is not null)
       )) then raise exception 'GL_EQUIPMENT_UNAVAILABLE'; end if;
    perform 1 from public.athletes where id=p_athlete_id and organization_id=equipment_row.organization_id and active for share;
    if not found then raise exception 'GL_ATHLETE_UNAVAILABLE'; end if;
    if p_operation='transfer' and active_row.athlete_id=p_athlete_id then raise exception 'GL_ALREADY_ASSIGNED_TO_ATHLETE'; end if;
  end if;
  event_time := clock_timestamp();
  if p_operation in ('return','transfer') then
    update public.equipment_assignments set returned_at=event_time,returned_by=auth.uid() where id=active_row.id;
  end if;
  if p_operation in ('assign','transfer') then
    insert into public.equipment_assignments(organization_id,equipment_id,athlete_id,checked_out_by,checked_out_at)
      values(equipment_row.organization_id,p_equipment_id,p_athlete_id,auth.uid(),event_time) returning id into new_assignment;
    update public.equipment set status='checked_out',updated_at=event_time where id=p_equipment_id;
  else
    update public.equipment set status=case when condition in ('needs_repair','retired') then 'maintenance' else 'available' end,
      updated_at=event_time where id=p_equipment_id;
  end if;
  insert into public.equipment_events(organization_id,equipment_id,athlete_id,assignment_id,event_type,actor_id,details)
    values(equipment_row.organization_id,p_equipment_id,
      case when p_operation='return' then active_row.athlete_id else p_athlete_id end,
      coalesce(new_assignment,active_row.id),
      case when p_operation='assign' then 'checkout' else p_operation end,auth.uid(),
      jsonb_build_object('request_id',p_request_id,'previous_assignment_id',active_row.id));
  receipt := jsonb_build_object('operation',p_operation,'equipment_id',p_equipment_id,
    'assignment_id',coalesce(new_assignment,active_row.id),'previous_assignment_id',active_row.id,'request_id',p_request_id);
  insert into private.equipment_operations(request_id,organization_id,actor_id,operation,arguments,result)
    values(p_request_id,equipment_row.organization_id,auth.uid(),p_operation,args,receipt);
  return receipt;
end;
$$;

-- Public functions are invokers; narrowly scoped private implementations own
-- privileged writes and always authorize the caller. No direct table writes.
create function public.begin_equipment_registration(p_organization_id uuid,p_equipment_id uuid,p_gearlink_id text,p_physical_uid text,p_technology text,p_details jsonb)
returns jsonb language sql security invoker set search_path='' as $$
  select private.begin_equipment_registration_impl(p_organization_id,p_equipment_id,p_gearlink_id,p_physical_uid,p_technology,p_details)
$$;
create function public.lookup_equipment_tag(p_organization_id uuid,p_physical_uid text,p_gearlink_id text default null)
returns jsonb language sql security invoker set search_path='' as $$
  select private.lookup_equipment_tag_impl(p_organization_id,p_physical_uid,p_gearlink_id)
$$;
create function public.confirm_equipment_registration(p_equipment_id uuid,p_tag_id uuid,p_physical_uid text,p_gearlink_id text)
returns jsonb language sql security invoker set search_path='' as $$
  select private.confirm_equipment_registration_impl(p_equipment_id,p_tag_id,p_physical_uid,p_gearlink_id)
$$;
create function public.record_equipment_write_failure(p_equipment_id uuid,p_tag_id uuid,p_physical_uid text,p_gearlink_id text)
returns jsonb language sql security invoker set search_path='' as $$
  select private.record_equipment_write_failure_impl(p_equipment_id,p_tag_id,p_physical_uid,p_gearlink_id)
$$;
create function public.update_equipment_details(p_equipment_id uuid,p_expected_updated_at timestamptz,p_details jsonb)
returns jsonb language sql security invoker set search_path='' as $$
  select private.update_equipment_details_impl(p_equipment_id,p_expected_updated_at,p_details)
$$;
create function public.replace_equipment_tag(p_equipment_id uuid,p_expected_tag_id uuid,p_physical_uid text,p_technology text)
returns jsonb language sql security invoker set search_path='' as $$
  select private.replace_equipment_tag_impl(p_equipment_id,p_expected_tag_id,p_physical_uid,p_technology)
$$;
create function public.retire_equipment(p_equipment_id uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.retire_equipment_impl(p_equipment_id) $$;
create function public.assign_equipment(p_equipment_id uuid,p_athlete_id uuid,p_request_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select private.equipment_assignment_operation_impl('assign',p_equipment_id,p_athlete_id,null,p_request_id)
$$;
create function public.return_equipment_checked(p_assignment_id uuid,p_request_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select private.equipment_assignment_operation_impl('return',null,null,p_assignment_id,p_request_id)
$$;
create function public.transfer_equipment(p_equipment_id uuid,p_athlete_id uuid,p_expected_assignment_id uuid,p_request_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select private.equipment_assignment_operation_impl('transfer',p_equipment_id,p_athlete_id,p_expected_assignment_id,p_request_id)
$$;
-- Preserve old RPC signatures, now going through the same lifecycle checks.
create or replace function public.checkout_equipment(target_equipment uuid,target_athlete uuid)
returns uuid language sql security invoker set search_path='' as $$
  select (private.equipment_assignment_operation_impl('assign',target_equipment,target_athlete,null,gen_random_uuid())->>'assignment_id')::uuid
$$;
create or replace function public.return_equipment(target_assignment uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
  perform private.equipment_assignment_operation_impl('return',null,null,target_assignment,target_assignment);
end;
$$;

-- Explicit ACLs for the newly exposed operations and their internal entrypoints.
do $$
declare routine record;
begin
  for routine in
    select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='private' and p.proname in (
      'begin_equipment_registration_impl','lookup_equipment_tag_impl','confirm_equipment_registration_impl',
      'record_equipment_write_failure_impl','update_equipment_details_impl','replace_equipment_tag_impl',
      'retire_equipment_impl','equipment_assignment_operation_impl'
    )) or (n.nspname='public' and p.proname in (
      'begin_equipment_registration','lookup_equipment_tag','confirm_equipment_registration',
      'record_equipment_write_failure','update_equipment_details','replace_equipment_tag','retire_equipment',
      'assign_equipment','return_equipment_checked','transfer_equipment','checkout_equipment','return_equipment'
    ))
  loop
    execute format('revoke all on function %s from public, anon, authenticated',routine.signature);
    execute format('grant execute on function %s to authenticated',routine.signature);
  end loop;
end;
$$;

revoke insert,update,delete,truncate,references,trigger on public.equipment,public.equipment_tags,public.equipment_assignments,public.equipment_events from anon,authenticated;
revoke all on public.equipment,public.equipment_tags,public.equipment_assignments,public.equipment_events from public;
grant select on public.equipment,public.equipment_tags,public.equipment_assignments,public.equipment_events to authenticated;
drop policy "staff manage equipment" on public.equipment;
drop policy "staff manage tags" on public.equipment_tags;
drop policy "staff manage assignments" on public.equipment_assignments;
drop policy "staff record events" on public.equipment_events;
create policy "members read equipment" on public.equipment for select to authenticated using (private.is_org_member(organization_id));
create policy "members read tags" on public.equipment_tags for select to authenticated using (private.is_org_member(organization_id));
create policy "members read assignments" on public.equipment_assignments for select to authenticated using (private.is_org_member(organization_id));

comment on column public.equipment.registration_status is 'NULL = legacy record without GearLink NFC registration; active requires client read-back confirmation. Separate from inventory status.';
comment on column public.equipment.original_tag_uid is 'Immutable full UID at first registration. Stable GearLink ID suffix refers to this UID even after tag replacement.';
comment on column public.equipment_tags.physical_uid is 'Canonical full hexadecimal UID; original uid column retained for compatibility.';
comment on function public.confirm_equipment_registration(uuid,uuid,text,text) is 'Call only after matching full UID and successful NDEF read-back. Server enforces authorization/state/identity, not physical NFC attestation.';
notify pgrst, 'reload schema';
commit;
