# Security migration runbook

Status: prepared, not applied.

## Why this is staged

The current production Helper System works without login. Turning on owner-only RLS before the frontend can authenticate would make all task reads/writes fail immediately.

Existing attachments also use legacy public paths, so Storage must not be locked until those files are migrated.

## Safe order

1. Enable Supabase Auth for the owner's account.
2. Confirm there is exactly one intended user in `auth.users`.
3. Add an authentication screen/session check to the Helper frontend.
4. Test authenticated reads/writes against a staging copy or temporary table.
5. Run `supabase-security-v3.sql`.
6. Verify task CRUD as the owner and verify anonymous task access is denied.
7. Migrate attachment objects to owner-prefixed paths.
8. Update task `image_urls`.
9. Apply owner-only Storage RLS in a separate migration.
10. Only after that enable Agent/iPhone remote mutation commands.

## Rollback principle

Take a Supabase backup/export before applying the migration. Do not combine task RLS and attachment migration into one irreversible operation.
