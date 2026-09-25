-- Helper manual Saraban refresh button v1
begin;

alter table public.automation_jobs
  add column if not exists manual_requested_at timestamptz,
  add column if not exists manual_request_id uuid;

create index if not exists idx_automation_jobs_owner_manual_request
  on public.automation_jobs(owner_id, manual_request_id)
  where manual_request_id is not null;

drop function if exists public.bridge_list_due_jobs(text,text);

create function public.bridge_list_due_jobs(
  p_token text,
  p_agent_id text
)
returns table(
  id uuid,
  name text,
  workflow_key text,
  enabled boolean,
  next_run_at timestamptz,
  schedule_kind text,
  schedule_expr text,
  config jsonb,
  manual_requested_at timestamptz,
  manual_request_id uuid
)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_owner uuid;
begin
  select c.owner_id
    into v_owner
  from public.helper_bridge_credentials c
  where c.agent_id = p_agent_id
    and c.active
    and c.token_hash = digest(convert_to(p_token, 'UTF8'), 'sha256')
  limit 1;

  if v_owner is null then
    raise exception 'invalid bridge credential' using errcode='42501';
  end if;

  return query
    select j.id, j.name, j.workflow_key, j.enabled, j.next_run_at,
           j.schedule_kind, j.schedule_expr, j.config,
           j.manual_requested_at, j.manual_request_id
    from public.automation_jobs j
    where j.owner_id = v_owner
      and j.enabled
      and (
        j.manual_request_id is not null
        or j.next_run_at is null
        or j.next_run_at <= now()
      )
    order by
      case when j.manual_request_id is not null then 0 else 1 end,
      j.manual_requested_at asc nulls last,
      j.next_run_at asc nulls first;
end;
$$;

revoke all on function public.bridge_list_due_jobs(text,text) from public;
grant execute on function public.bridge_list_due_jobs(text,text) to anon, authenticated;

create or replace function public.bridge_finish_manual_request(
  p_token text,
  p_agent_id text,
  p_workflow_key text,
  p_manual_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_owner uuid;
begin
  v_owner := public.bridge_owner_for_token(p_token,p_agent_id);

  if p_workflow_key <> 'morning-document-registry' then
    raise exception 'workflow not allowed' using errcode='42501';
  end if;

  update public.automation_jobs
  set manual_requested_at = null,
      manual_request_id = null,
      updated_at = now()
  where owner_id = v_owner
    and workflow_key = p_workflow_key
    and manual_request_id = p_manual_request_id;

  return found;
end;
$$;

revoke all on function public.bridge_finish_manual_request(text,text,text,uuid) from public;
grant execute on function public.bridge_finish_manual_request(text,text,text,uuid) to anon, authenticated;

commit;
