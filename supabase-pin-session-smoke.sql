-- Admin-only smoke helper for Helper PIN session.
-- Generates a random 10-minute test session without knowing the real PIN.
-- Revoke the returned token with public.helper_lock(token) after testing.
with tok as (
  select encode(extensions.gen_random_bytes(32),'hex') as token
), ins as (
  insert into public.helper_pin_sessions(token_hash,owner_id,expires_at,revoked_at)
  select extensions.digest(convert_to(token,'UTF8'),'sha256'),
         public.helper_owner_id(),
         now()+interval '10 minutes',
         null
  from tok
  returning token_hash
)
select tok.token, (select count(*) from ins) as inserted
from tok;
