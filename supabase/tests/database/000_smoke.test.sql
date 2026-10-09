-- Smoke test so `supabase test db` has something to run until the M2/M3 RLS suites land.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);

select has_schema('public', 'public schema exists');

select * from finish();
rollback;
