-- Pros cannot read public.jobs until they are booked.
-- This view runs as the owner and returns the open listing only:
-- details, photos, schedule, price, and an approximate pin. No street.
-- Apply after 20261030150000_pro_profile_bio.sql.
-- photo_names must be the storage object path, such as {user id}/{file}.jpg.

create or replace view public.pro_open_jobs
with (security_invoker = false)
as
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
where l.status in ('open', 'posted', 'awaitingAcceptance');

revoke all on public.pro_open_jobs from public, anon;
grant select on public.pro_open_jobs to authenticated;

-- Copy any photo paths and details that exist on the job onto the listing.
update public.job_listings l
set photo_names = j.photo_names,
    details = j.details,
    offered_price_cents = j.offered_price_cents,
    status = j.status,
    estimated_minutes = j.estimated_minutes
from public.jobs j
where l.id = j.id
  and j.status in ('open', 'posted', 'awaitingAcceptance');
