-- =====================================================================
-- Hack Heroes — Classroom layer schema
-- Project: Hack Heroes (OWASP)
-- License: GNU AGPLv3
-- ---------------------------------------------------------------------
-- HOW TO USE
--   1. Create a Supabase project.
--   2. Authentication -> Providers -> enable "Anonymous sign-ins".
--   3. Open the SQL Editor, paste this whole file, and run it.
--   4. Put your project URL + anon (public) key in config/supabase.json.
--
-- The anon key is PUBLIC by design. All access control is enforced by
-- the Row Level Security (RLS) policies below.
-- =====================================================================


-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- Teachers: 1:1 with auth.users for teacher (email+password) accounts.
create table if not exists public.teachers (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now()
);

-- Classes: each owned by a teacher, joinable by a human-friendly code.
create table if not exists public.classes (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null references public.teachers(id) on delete cascade,
  name        text not null,
  join_code   text not null unique,             -- e.g. "BRAVE-FOX-42"
  created_at  timestamptz not null default now()
);
create index if not exists classes_teacher_idx on public.classes (teacher_id);
-- Winner prize (revealed on the leaderboard when someone finishes all
-- challenges). Added via ALTER so existing databases pick it up too.
alter table public.classes add column if not exists prize text;

create index if not exists classes_code_idx    on public.classes (join_code);

-- Students: one row per anonymous auth user per class. No PII, no password.
create table if not exists public.students (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes(id) on delete cascade,
  auth_uid    uuid not null references auth.users(id) on delete cascade,
  nickname    text not null,
  created_at  timestamptz not null default now(),
  unique (class_id, auth_uid)                    -- one identity per class
);
create index if not exists students_class_idx on public.students (class_id);
create index if not exists students_uid_idx    on public.students (auth_uid);
-- Student avatar (an emoji chosen at join time). Added via ALTER so existing
-- databases pick it up too.
alter table public.students add column if not exists avatar text;


-- Assignments: which challenge ids a class must complete.
create table if not exists public.assignments (
  id            uuid primary key default gen_random_uuid(),
  class_id      uuid not null references public.classes(id) on delete cascade,
  challenge_id  text not null,                   -- matches challenges.json ids
  sort_order    int  not null default 0,
  due_at        timestamptz,
  created_at    timestamptz not null default now(),
  unique (class_id, challenge_id)
);
create index if not exists assignments_class_idx on public.assignments (class_id);

-- Progress: one row per student per challenge (upserted). class_id is
-- denormalized so the realtime leaderboard can filter on a single column.
create table if not exists public.progress (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students(id) on delete cascade,
  class_id      uuid not null references public.classes(id) on delete cascade,
  challenge_id  text not null,
  started_at    timestamptz not null default now(),
  hints_used    int  not null default 0,
  completed     boolean not null default false,
  completed_at  timestamptz,
  updated_at    timestamptz not null default now(),
  unique (student_id, challenge_id)
);
create index if not exists progress_class_idx   on public.progress (class_id);
create index if not exists progress_student_idx on public.progress (student_id);


-- =====================================================================
-- 2. HELPER FUNCTIONS (security definer so policies don't recurse)
-- =====================================================================

create or replace function public.is_student_of_class(c_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.students s
    where s.class_id = c_id and s.auth_uid = auth.uid()
  );
$$;

create or replace function public.owns_class(c_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.classes c
    where c.id = c_id and c.teacher_id = auth.uid()
  );
$$;


-- =====================================================================
-- 3. JOIN-BY-CODE RPC
-- Students never read the classes table directly; they call this RPC,
-- which looks up the class by code and idempotently creates/updates
-- their student row for the current auth.uid().
-- =====================================================================

drop function if exists public.join_class(text, text);

create or replace function public.join_class(p_code text, p_nickname text, p_avatar text default null)
returns table (student_id uuid, class_id uuid, class_name text, avatar text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_class   public.classes;
  v_student public.students;
  v_nick    text;
  v_avatar  text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to join a class.';
  end if;

  v_nick := nullif(left(trim(coalesce(p_nickname, '')), 24), '');
  if v_nick is null then
    raise exception 'Please choose a nickname.';
  end if;

  v_avatar := nullif(left(trim(coalesce(p_avatar, '')), 8), '');

  select * into v_class
    from public.classes
   where join_code = upper(trim(p_code));

  if not found then
    raise exception 'That class code was not found.';
  end if;

  -- Idempotent: reuse existing membership for this device/identity.
  select * into v_student
    from public.students s
   where s.class_id = v_class.id and s.auth_uid = auth.uid();

  if not found then
    insert into public.students (class_id, auth_uid, nickname, avatar)
    values (v_class.id, auth.uid(), v_nick, v_avatar)
    returning * into v_student;
  else
    update public.students
       set nickname = v_nick,
           avatar   = coalesce(v_avatar, students.avatar)
     where id = v_student.id
    returning * into v_student;
  end if;

  return query select v_student.id, v_class.id, v_class.name, v_student.avatar;
end;
$$;

grant execute on function public.join_class(text, text, text) to authenticated, anon;


-- =====================================================================
-- 4. ROW LEVEL SECURITY
-- =====================================================================

alter table public.teachers    enable row level security;
alter table public.classes     enable row level security;
alter table public.students    enable row level security;
alter table public.assignments enable row level security;
alter table public.progress    enable row level security;

-- ---- teachers --------------------------------------------------------
drop policy if exists teacher_self on public.teachers;
create policy teacher_self on public.teachers
  for all
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---- classes ---------------------------------------------------------
drop policy if exists class_owner_all on public.classes;
create policy class_owner_all on public.classes
  for all
  using (teacher_id = auth.uid())
  with check (teacher_id = auth.uid());

drop policy if exists class_student_read on public.classes;
create policy class_student_read on public.classes
  for select
  using (public.is_student_of_class(id));

-- ---- students --------------------------------------------------------
-- Teacher can read students in their own classes.
drop policy if exists student_teacher_read on public.students;
create policy student_teacher_read on public.students
  for select
  using (public.owns_class(class_id));

-- A student can read their own row AND peers in the same class
-- (peers needed so the live leaderboard shows everyone).
drop policy if exists student_class_read on public.students;
create policy student_class_read on public.students
  for select
  using (public.is_student_of_class(class_id));

-- A student may update only their own row (e.g. nickname).
drop policy if exists student_self_write on public.students;
create policy student_self_write on public.students
  for update
  using (auth_uid = auth.uid())
  with check (auth_uid = auth.uid());
-- INSERT into students happens only via join_class() (security definer).

-- ---- assignments -----------------------------------------------------
drop policy if exists assign_owner_all on public.assignments;
create policy assign_owner_all on public.assignments
  for all
  using (public.owns_class(class_id))
  with check (public.owns_class(class_id));

drop policy if exists assign_student_read on public.assignments;
create policy assign_student_read on public.assignments
  for select
  using (public.is_student_of_class(class_id));

-- ---- progress --------------------------------------------------------
-- Teacher reads all progress in their own classes.
drop policy if exists progress_teacher_read on public.progress;
create policy progress_teacher_read on public.progress
  for select
  using (public.owns_class(class_id));

-- Students read all progress in their class (so they see the leaderboard).
drop policy if exists progress_student_read on public.progress;
create policy progress_student_read on public.progress
  for select
  using (public.is_student_of_class(class_id));

-- Students may insert progress only for themselves, in their own class.
drop policy if exists progress_student_insert on public.progress;
create policy progress_student_insert on public.progress
  for insert
  with check (
    public.is_student_of_class(class_id)
    and student_id in (
      select id from public.students where auth_uid = auth.uid()
    )
  );

-- Students may update only their own progress rows.
drop policy if exists progress_student_update on public.progress;
create policy progress_student_update on public.progress
  for update
  using (
    student_id in (
      select id from public.students where auth_uid = auth.uid()
    )
  )
  with check (
    student_id in (
      select id from public.students where auth_uid = auth.uid()
    )
  );


-- =====================================================================
-- 5. REALTIME
-- The dashboard subscribes to progress (and students) changes filtered
-- by class_id. RLS is enforced on realtime, so each session only
-- receives rows it is allowed to read.
-- =====================================================================

do $$
begin
  begin
    alter publication supabase_realtime add table public.progress;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.students;
  exception when duplicate_object then null;
  end;
end $$;
