-- Helper System Automation Control Plane v1
-- PREPARED ONLY. Apply after Supabase Auth + supabase-security-v3.sql.
-- All rows are owner-scoped and invisible to anonymous users.

begin;

create extension if not exists pgcrypto;

create table if not exists public.automation_jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  workflow_key text not null,
  enabled boolean not null default true,
  schedule_kind text not null default 'cron',
  schedule_expr text,
  schedule_timezone text not null default 'Asia/Bangkok',
  next_run_at timestamptz,
  missed_run_policy text not null default 'run_once',
  approval_policy jsonb not null default '{}'::jsonb,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, workflow_key),
  constraint automation_jobs_schedule_kind_check
    check (schedule_kind in ('cron','once','manual','event')),
  constraint automation_jobs_missed_run_policy_check
    check (missed_run_policy in ('skip','run_once','catch_up'))
);

create table if not exists public.agent_runs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  automation_job_id uuid references public.automation_jobs(id) on delete set null,
  agent_id text not null default 'AgentChayanun',
  state text not null default 'SCHEDULED',
  current_step text,
  progress integer not null default 0,
  started_at timestamptz,
  heartbeat_at timestamptz,
  completed_at timestamptz,
  result_summary text,
  result_data jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  retry_count integer not null default 0,
  external_run_id text,
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agent_runs_progress_check check (progress between 0 and 100),
  constraint agent_runs_state_check check (state in (
    'SCHEDULED','STARTING','RUNNING','WAITING_FOR_HUMAN',
    'RETRYING','RECOVERING','NEEDS_USER','COMPLETED','FAILED','CANCELLED'
  ))
);

create unique index if not exists idx_agent_runs_owner_idempotency
  on public.agent_runs(owner_id, idempotency_key)
  where idempotency_key is not null;

create table if not exists public.human_gates (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  run_id uuid not null references public.agent_runs(id) on delete cascade,
  gate_type text not null,
  state text not null default 'WAITING',
  message text,
  action_url text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  satisfied_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint human_gates_state_check
    check (state in ('WAITING','SATISFIED','EXPIRED','CANCELLED'))
);

create table if not exists public.agent_status (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  agent_id text not null,
  online boolean not null default false,
  version text,
  last_seen_at timestamptz,
  current_run_id uuid references public.agent_runs(id) on delete set null,
  current_activity text,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key(owner_id, agent_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  severity text not null default 'info',
  title text not null,
  body text,
  run_id uuid references public.agent_runs(id) on delete cascade,
  action_url text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint notifications_severity_check
    check (severity in ('info','success','warning','error','action'))
);

create index if not exists idx_automation_jobs_owner_next_run
  on public.automation_jobs(owner_id, enabled, next_run_at);
create index if not exists idx_agent_runs_owner_state
  on public.agent_runs(owner_id, state, created_at desc);
create index if not exists idx_human_gates_owner_state
  on public.human_gates(owner_id, state, created_at desc);
create index if not exists idx_notifications_owner_created
  on public.notifications(owner_id, created_at desc);

-- updated_at trigger helper already exists in the original setup; make it idempotent here.
create or replace function public.update_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists automation_jobs_updated_at on public.automation_jobs;
create trigger automation_jobs_updated_at
  before update on public.automation_jobs
  for each row execute function public.update_updated_at();

drop trigger if exists agent_runs_updated_at on public.agent_runs;
create trigger agent_runs_updated_at
  before update on public.agent_runs
  for each row execute function public.update_updated_at();

drop trigger if exists human_gates_updated_at on public.human_gates;
create trigger human_gates_updated_at
  before update on public.human_gates
  for each row execute function public.update_updated_at();

drop trigger if exists agent_status_updated_at on public.agent_status;
create trigger agent_status_updated_at
  before update on public.agent_status
  for each row execute function public.update_updated_at();

-- Owner-only RLS.
alter table public.automation_jobs enable row level security;
alter table public.agent_runs enable row level security;
alter table public.human_gates enable row level security;
alter table public.agent_status enable row level security;
alter table public.notifications enable row level security;

revoke all on public.automation_jobs from anon;
revoke all on public.agent_runs from anon;
revoke all on public.human_gates from anon;
revoke all on public.agent_status from anon;
revoke all on public.notifications from anon;

grant select, insert, update, delete on public.automation_jobs to authenticated;
grant select, insert, update, delete on public.agent_runs to authenticated;
grant select, insert, update, delete on public.human_gates to authenticated;
grant select, insert, update, delete on public.agent_status to authenticated;
grant select, insert, update, delete on public.notifications to authenticated;

do $$
declare
  tbl text;
begin
  foreach tbl in array array['automation_jobs','agent_runs','human_gates','agent_status','notifications']
  loop
    execute format('drop policy if exists "Owner read" on public.%I', tbl);
    execute format('drop policy if exists "Owner insert" on public.%I', tbl);
    execute format('drop policy if exists "Owner update" on public.%I', tbl);
    execute format('drop policy if exists "Owner delete" on public.%I', tbl);

    execute format(
      'create policy "Owner read" on public.%I for select to authenticated using (owner_id = auth.uid())',
      tbl
    );
    execute format(
      'create policy "Owner insert" on public.%I for insert to authenticated with check (owner_id = auth.uid())',
      tbl
    );
    execute format(
      'create policy "Owner update" on public.%I for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid())',
      tbl
    );
    execute format(
      'create policy "Owner delete" on public.%I for delete to authenticated using (owner_id = auth.uid())',
      tbl
    );
  end loop;
end $$;

commit;

-- Optional seed after authentication (run while logged in or replace auth.uid() explicitly):
-- insert into public.automation_jobs
--   (owner_id, name, workflow_key, schedule_kind, schedule_expr, schedule_timezone, missed_run_policy)
-- values
--   (auth.uid(), 'ตรวจสารบรรณประจำวัน', 'morning-document-registry', 'cron', '30 7 * * 1-5', 'Asia/Bangkok', 'run_once');
