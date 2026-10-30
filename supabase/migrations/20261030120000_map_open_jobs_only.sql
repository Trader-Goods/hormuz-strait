-- The map shows only jobs that are still open for offers.
-- Apply after 20261028200000_customer_price_map.sql.

delete from public.public_prices
where status not in ('open', 'posted', 'awaitingAcceptance');

drop policy if exists "authenticated read public prices" on public.public_prices;
create policy "authenticated read public prices" on public.public_prices
    for select to authenticated
    using (
        offered_price_cents > 0
        and status in ('open', 'posted', 'awaitingAcceptance')
    );

drop view if exists public.price_board;
create view public.price_board
with (security_invoker = true)
as
select
    id,
    category,
    service_type,
    city,
    state,
    zip,
    latitude,
    longitude,
    offered_price_cents,
    estimated_minutes,
    status,
    scheduled_on,
    created_at
from public.public_prices
where offered_price_cents > 0
  and status in ('open', 'posted', 'awaitingAcceptance');

revoke all on public.price_board from public, anon;
grant select on public.price_board to authenticated;

drop view if exists public.job_board;
create view public.job_board
with (security_invoker = true)
as
select
    j.id,
    j.customer_id,
    j.category,
    j.street,
    j.city,
    j.state,
    j.zip,
    j.latitude,
    j.longitude,
    j.scheduled_on,
    j.details,
    j.status,
    j.photo_names,
    j.created_at,
    j.service_type,
    j.offered_price_cents,
    j.allows_multiple,
    j.estimate,
    j.estimated_minutes,
    j.listed_until
from public.jobs j
where j.status in ('open', 'posted', 'awaitingAcceptance')
union all
select
    l.id,
    l.customer_id,
    l.category,
    ''::text as street,
    l.city,
    l.state,
    l.zip,
    l.latitude,
    l.longitude,
    l.scheduled_on,
    l.details,
    l.status,
    l.photo_names,
    l.created_at,
    l.service_type,
    l.offered_price_cents,
    l.allows_multiple,
    l.estimate,
    l.estimated_minutes,
    l.listed_until
from public.job_listings l
where l.status in ('open', 'posted', 'awaitingAcceptance')
  and not exists (
    select 1 from public.jobs j where j.id = l.id
  );

revoke all on public.job_board from public, anon;
grant select on public.job_board to authenticated;
