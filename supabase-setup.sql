-- ═══════════════════════════════════════════════════
--  Supabase Setup v2 — ใช้ OR REPLACE / IF NOT EXISTS ทุกที่
--  รันได้ซ้ำโดยไม่ error
-- ═══════════════════════════════════════════════════

-- 1. สร้างตาราง tasks (ถ้ายังไม่มี)
CREATE TABLE IF NOT EXISTS public.tasks (
  id            TEXT PRIMARY KEY,
  work_group    TEXT,
  doc_no        TEXT,
  title         TEXT NOT NULL,
  due_date      DATE,
  start_date    DATE,
  priority      TEXT DEFAULT 'med',
  task_status   TEXT DEFAULT 'กำลังดำเนินการ',
  meeting_link  TEXT,
  file_link     TEXT,
  image_urls    TEXT,
  checklist     TEXT,
  details       TEXT,
  space         TEXT DEFAULT 'work',
  status        TEXT DEFAULT 'active',
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Function updated_at (OR REPLACE = ไม่ error ถ้ามีแล้ว)
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Trigger (DROP ก่อน แล้วสร้างใหม่ = ไม่ error ทุกกรณี)
DROP TRIGGER IF EXISTS tasks_updated_at ON public.tasks;
CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 4. Index
CREATE INDEX IF NOT EXISTS idx_tasks_status   ON public.tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON public.tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_tasks_space    ON public.tasks(space);

-- 5. Row Level Security
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read"   ON public.tasks;
DROP POLICY IF EXISTS "Public insert" ON public.tasks;
DROP POLICY IF EXISTS "Public update" ON public.tasks;
DROP POLICY IF EXISTS "Public delete" ON public.tasks;

CREATE POLICY "Public read"   ON public.tasks FOR SELECT USING (true);
CREATE POLICY "Public insert" ON public.tasks FOR INSERT WITH CHECK (true);
CREATE POLICY "Public update" ON public.tasks FOR UPDATE USING (true);
CREATE POLICY "Public delete" ON public.tasks FOR DELETE USING (true);

-- 6. Storage Bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('attachments', 'attachments', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 7. Storage RLS
DROP POLICY IF EXISTS "Public read attachments"   ON storage.objects;
DROP POLICY IF EXISTS "Public upload attachments" ON storage.objects;
DROP POLICY IF EXISTS "Public update attachments" ON storage.objects;
DROP POLICY IF EXISTS "Public delete attachments" ON storage.objects;

CREATE POLICY "Public read attachments"
  ON storage.objects FOR SELECT USING (bucket_id = 'attachments');
CREATE POLICY "Public upload attachments"
  ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'attachments');
CREATE POLICY "Public update attachments"
  ON storage.objects FOR UPDATE USING (bucket_id = 'attachments');
CREATE POLICY "Public delete attachments"
  ON storage.objects FOR DELETE USING (bucket_id = 'attachments');
