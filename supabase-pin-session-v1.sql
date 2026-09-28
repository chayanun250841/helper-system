-- Helper System PIN session v1
-- Server-validates the 6-digit PIN and issues a random 30-day session token.
-- Browser requests carry that token in x-helper-session; RLS checks it.

begin;

create extension if not exists pgcrypto;

create table if not exists public.helper_pin_config (
  singleton boolean primary key default true check (singleton),
  pin_hash bytea not null,
  owner_id uuid references auth.users(id) on delete set null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.helper_pin_sessions (
  token_hash bytea primary key,
  owner_id uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);

create index if not exists idx_helper_pin_sessions_expires
  on public.helper_pin_sessions(expires_at)
  where revoked_at is null;

-- Transitional seed: same SHA-256 value already shipped in the old browser-only PIN build.
-- Rotate the PIN after this migration is live.
insert into public.helper_pin_config(singleton,pin_hash,owner_id)
values (
  true,
  decode('5dd77994727fcccb37fe1285fd477e573f679aea327c91bf5eca252e2ba535eb','hex'),
  coalesce(
    (select owner_id from public.automation_jobs where owner_id is not null limit 1),
    (select owner_id from public.tasks where owner_id is not null limit 1),
    (select id from auth.users order by created_at asc limit 1)
  )
)
on conflict (singleton) do update
set owner_id = coalesce(public.helper_pin_config.owner_id,excluded.owner_id),
    updated_at = now();

revoke all on public.helper_pin_config from anon, authenticated;
revoke all on public.helper_pin_sessions from anon, authenticated;
alter table public.helper_pin_config enable row level security;
alter table public.helper_pin_sessions enable row level security;

create or replace function public.helper_owner_id()
returns uuid
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select owner_id from public.helper_pin_config where singleton = true
$$;

create or replace function public.helper_session_valid()
returns boolean
language plpgsql
security definer
stable
set search_path = pg_catalog, public, extensions
as $$
declare
  headers_text text;
  token text;
begin
  headers_text := current_setting('request.headers', true);
  if headers_text is null or headers_text = '' then return false; end if;
  token := coalesce((headers_text::jsonb)->>'x-helper-session','');
  if token = '' then return false; end if;

  return exists(
    select 1
    from public.helper_pin_sessions s
    where s.token_hash = digest(convert_to(token,'UTF8'),'sha256')
      and s.revoked_at is null
      and s.expires_at > now()
  );
exception when others then
  return false;
end;
$$;

create or replace function public.helper_check_session(p_token text)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public, extensions
as $$
  select exists(
    select 1
    from public.helper_pin_sessions s
    where s.token_hash = digest(convert_to(coalesce(p_token,''),'UTF8'),'sha256')
      and s.revoked_at is null
      and s.expires_at > now()
  )
$$;

create or replace function public.helper_unlock(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  cfg public.helper_pin_config%rowtype;
  token text;
  expiry timestamptz;
  next_fail integer;
begin
  if p_pin is null or p_pin !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok',false,'message','PIN ไม่ถูกต้อง');
  end if;

  select * into cfg from public.helper_pin_config where singleton = true for update;
  if not found then
    return jsonb_build_object('ok',false,'message','PIN ยังไม่ได้ตั้งค่า');
  end if;

  if cfg.locked_until is not null and cfg.locked_until > now() then
    return jsonb_build_object('ok',false,'message','ลอง PIN ผิดหลายครั้ง กรุณารอสักครู่');
  end if;

  if digest(convert_to(p_pin,'UTF8'),'sha256') <> cfg.pin_hash then
    next_fail := coalesce(cfg.failed_attempts,0) + 1;
    update public.helper_pin_config
       set failed_attempts = case when next_fail >= 5 then 0 else next_fail end,
           locked_until = case when next_fail >= 5 then now() + interval '5 minutes' else null end,
           updated_at = now()
     where singleton = true;
    return jsonb_build_object('ok',false,'message','PIN ไม่ถูกต้อง');
  end if;

  update public.helper_pin_config
     set failed_attempts = 0, locked_until = null, updated_at = now()
   where singleton = true;

  delete from public.helper_pin_sessions
   where expires_at <= now() or revoked_at is not null;

  token := encode(gen_random_bytes(32),'hex');
  expiry := now() + interval '30 days';

  insert into public.helper_pin_sessions(token_hash,owner_id,expires_at)
  values (
    digest(convert_to(token,'UTF8'),'sha256'),
    cfg.owner_id,
    expiry
  );

  return jsonb_build_object('ok',true,'token',token,'expires_at',expiry);
end;
$$;

create or replace function public.helper_lock(p_token text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
begin
  update public.helper_pin_sessions
     set revoked_at = now()
   where token_hash = digest(convert_to(coalesce(p_token,''),'UTF8'),'sha256')
     and revoked_at is null;
  return found;
end;
$$;

create or replace function public.helper_change_pin(p_token text,p_new_pin text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
begin
  if not public.helper_check_session(p_token) then
    raise exception 'helper session expired' using errcode='42501';
  end if;
  if p_new_pin is null or p_new_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN must be exactly 6 digits' using errcode='22023';
  end if;

  update public.helper_pin_config
     set pin_hash = digest(convert_to(p_new_pin,'UTF8'),'sha256'),
         failed_attempts = 0,
         locked_until = null,
         updated_at = now()
   where singleton = true;

  update public.helper_pin_sessions
     set revoked_at = now()
   where token_hash <> digest(convert_to(p_token,'UTF8'),'sha256')
     and revoked_at is null;

  return true;
end;
$$;

create or replace function public.helper_task_upsert(p_token text,p_task jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner uuid;
  row_out public.tasks%rowtype;
begin
  if not public.helper_check_session(p_token) then
    raise exception 'helper session expired' using errcode='42501';
  end if;
  owner := public.helper_owner_id();
  if owner is null then
    raise exception 'helper owner is not configured' using errcode='42501';
  end if;

  insert into public.tasks(
    id,owner_id,work_group,doc_no,title,due_date,start_date,priority,task_status,
    meeting_link,file_link,image_urls,checklist,details,space,status
  )
  values(
    p_task->>'id',
    owner,
    coalesce(p_task->>'work_group',''),
    coalesce(p_task->>'doc_no',''),
    coalesce(p_task->>'title',''),
    nullif(p_task->>'due_date','')::date,
    nullif(p_task->>'start_date','')::date,
    coalesce(nullif(p_task->>'priority',''),'med'),
    coalesce(nullif(p_task->>'task_status',''),'กำลังดำเนินการ'),
    coalesce(p_task->>'meeting_link',''),
    coalesce(p_task->>'file_link',''),
    coalesce(p_task->>'image_urls',''),
    coalesce(p_task->>'checklist',''),
    coalesce(p_task->>'details',''),
    coalesce(nullif(p_task->>'space',''),'work'),
    coalesce(nullif(p_task->>'status',''),'active')
  )
  on conflict(id) do update set
    owner_id=owner,
    work_group=excluded.work_group,
    doc_no=excluded.doc_no,
    title=excluded.title,
    due_date=excluded.due_date,
    start_date=excluded.start_date,
    priority=excluded.priority,
    task_status=excluded.task_status,
    meeting_link=excluded.meeting_link,
    file_link=excluded.file_link,
    image_urls=excluded.image_urls,
    checklist=excluded.checklist,
    details=excluded.details,
    space=excluded.space,
    status=excluded.status
  where public.tasks.owner_id=owner
  returning * into row_out;

  if row_out.id is null then
    raise exception 'task is not owned by Helper owner' using errcode='42501';
  end if;
  return to_jsonb(row_out)-'owner_id';
end;
$$;

create or replace function public.helper_task_set_status(
  p_token text,p_id text,p_status text,p_image_urls text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner uuid;
begin
  if not public.helper_check_session(p_token) then
    raise exception 'helper session expired' using errcode='42501';
  end if;
  owner := public.helper_owner_id();
  update public.tasks
     set status=p_status,
         image_urls=case when p_image_urls is null then image_urls else p_image_urls end
   where id=p_id and owner_id=owner;
  return found;
end;
$$;

create or replace function public.helper_task_delete(p_token text,p_id text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner uuid;
begin
  if not public.helper_check_session(p_token) then
    raise exception 'helper session expired' using errcode='42501';
  end if;
  owner := public.helper_owner_id();
  delete from public.tasks where id=p_id and owner_id=owner;
  return found;
end;
$$;

create or replace function public.helper_manual_job_request(
  p_token text,p_request_id uuid,p_requested_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner uuid;
  result jsonb;
begin
  if not public.helper_check_session(p_token) then
    raise exception 'helper session expired' using errcode='42501';
  end if;
  owner := public.helper_owner_id();
  update public.automation_jobs
     set manual_request_id=p_request_id,
         manual_requested_at=p_requested_at,
         updated_at=now()
   where owner_id=owner
     and workflow_key='morning-document-registry'
     and enabled=true
  returning jsonb_build_object(
    'id',id,
    'manual_request_id',manual_request_id,
    'manual_requested_at',manual_requested_at
  ) into result;
  return result;
end;
$$;

revoke all on function public.helper_owner_id() from public;
revoke all on function public.helper_session_valid() from public;
revoke all on function public.helper_check_session(text) from public;
revoke all on function public.helper_unlock(text) from public;
revoke all on function public.helper_lock(text) from public;
revoke all on function public.helper_change_pin(text,text) from public;
revoke all on function public.helper_task_upsert(text,jsonb) from public;
revoke all on function public.helper_task_set_status(text,text,text,text) from public;
revoke all on function public.helper_task_delete(text,text) from public;
revoke all on function public.helper_manual_job_request(text,uuid,timestamptz) from public;

grant execute on function public.helper_owner_id() to anon, authenticated;
grant execute on function public.helper_session_valid() to anon, authenticated;
grant execute on function public.helper_check_session(text) to anon, authenticated;
grant execute on function public.helper_unlock(text) to anon, authenticated;
grant execute on function public.helper_lock(text) to anon, authenticated;
grant execute on function public.helper_change_pin(text,text) to anon, authenticated;
grant execute on function public.helper_task_upsert(text,jsonb) to anon, authenticated;
grant execute on function public.helper_task_set_status(text,text,text,text) to anon, authenticated;
grant execute on function public.helper_task_delete(text,text) to anon, authenticated;
grant execute on function public.helper_manual_job_request(text,uuid,timestamptz) to anon, authenticated;

-- tasks: PIN session gets the same CRUD scope as the owner UI.
alter table public.tasks alter column owner_id set default public.helper_owner_id();
grant select,insert,update,delete on public.tasks to anon;

drop policy if exists "Helper PIN read" on public.tasks;
drop policy if exists "Helper PIN insert" on public.tasks;
drop policy if exists "Helper PIN update" on public.tasks;
drop policy if exists "Helper PIN delete" on public.tasks;

create policy "Helper PIN read" on public.tasks for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN insert" on public.tasks for insert to anon
  with check (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN update" on public.tasks for update to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id())
  with check (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN delete" on public.tasks for delete to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());

-- Automation center: browser reads status and may only update the existing manual-request job.
alter table public.agent_status enable row level security;
alter table public.agent_runs enable row level security;
alter table public.human_gates enable row level security;
alter table public.notifications enable row level security;
alter table public.automation_jobs enable row level security;
grant select on public.agent_status,public.agent_runs,public.human_gates,public.notifications to anon;
grant select,update on public.automation_jobs to anon;

drop policy if exists "Helper PIN read" on public.agent_status;
drop policy if exists "Helper PIN read" on public.agent_runs;
drop policy if exists "Helper PIN read" on public.human_gates;
drop policy if exists "Helper PIN read" on public.notifications;
drop policy if exists "Helper PIN read" on public.automation_jobs;
drop policy if exists "Helper PIN update" on public.automation_jobs;

create policy "Helper PIN read" on public.agent_status for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN read" on public.agent_runs for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN read" on public.human_gates for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN read" on public.notifications for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN read" on public.automation_jobs for select to anon
  using (public.helper_session_valid() and owner_id = public.helper_owner_id());
create policy "Helper PIN update" on public.automation_jobs for update to anon
  using (
    public.helper_session_valid()
    and owner_id = public.helper_owner_id()
    and workflow_key = 'morning-document-registry'
  )
  with check (
    public.helper_session_valid()
    and owner_id = public.helper_owner_id()
    and workflow_key = 'morning-document-registry'
  );

-- Saraban mirror: read-only through a valid Helper PIN session.
alter table public.saraban_registry enable row level security;
alter table public.saraban_registry_files enable row level security;
alter table public.saraban_registry_pages enable row level security;
grant select on public.saraban_registry,public.saraban_registry_files,public.saraban_registry_pages to anon;

drop policy if exists "Helper PIN read" on public.saraban_registry;
drop policy if exists "Helper PIN read" on public.saraban_registry_files;
drop policy if exists "Helper PIN read" on public.saraban_registry_pages;

create policy "Helper PIN read" on public.saraban_registry for select to anon
  using (public.helper_session_valid());
create policy "Helper PIN read" on public.saraban_registry_files for select to anon
  using (public.helper_session_valid());
create policy "Helper PIN read" on public.saraban_registry_pages for select to anon
  using (public.helper_session_valid());

commit;

-- Legacy attachment URLs remain public for now so existing previews/uploads keep working.
-- Do not treat attachment URLs as confidential until Storage is migrated separately.
