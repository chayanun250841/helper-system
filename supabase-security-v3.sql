-- Helper System Security v3
-- PREPARED ONLY. DO NOT RUN until Supabase Auth has exactly one intended owner user.
-- This migration intentionally locks TASK data first. Storage locking is a later migration
-- because existing attachment object paths were created before per-user ownership prefixes.

begin;

-- 1) Require exactly one Auth user before assigning existing records.
do $$
declare
  user_count integer;
begin
  select count(*) into user_count from auth.users;
  if user_count <> 1 then
    raise exception 'Expected exactly one auth.users row before migration; found %', user_count;
  end if;
end $$;

-- 2) Add ownership to existing tasks.
alter table public.tasks
  add column if not exists owner_id uuid references auth.users(id) on delete cascade;

update public.tasks
set owner_id = (select id from auth.users limit 1)
where owner_id is null;

alter table public.tasks
  alter column owner_id set not null;

create index if not exists idx_tasks_owner_id on public.tasks(owner_id);

-- 3) Replace public task policies with authenticated owner-only policies.
alter table public.tasks enable row level security;

drop policy if exists "Public read" on public.tasks;
drop policy if exists "Public insert" on public.tasks;
drop policy if exists "Public update" on public.tasks;
drop policy if exists "Public delete" on public.tasks;

drop policy if exists "Owner read" on public.tasks;
drop policy if exists "Owner insert" on public.tasks;
drop policy if exists "Owner update" on public.tasks;
drop policy if exists "Owner delete" on public.tasks;

create policy "Owner read"
  on public.tasks
  for select
  to authenticated
  using (owner_id = auth.uid());

create policy "Owner insert"
  on public.tasks
  for insert
  to authenticated
  with check (owner_id = auth.uid());

create policy "Owner update"
  on public.tasks
  for update
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "Owner delete"
  on public.tasks
  for delete
  to authenticated
  using (owner_id = auth.uid());

commit;

-- IMPORTANT:
-- Do not lock storage.objects yet. Existing attachment URLs are public and their paths are not
-- namespaced by auth.uid(). First ship authenticated frontend support, migrate existing objects
-- into an owner-prefixed path, update task.image_urls, then run a separate storage policy migration.
