-- Anonymous visitors can see open job pins only.
-- Apply after 20261103190000_nw_ohio_leaf_and_hedge.sql.
-- Does not change row security on public.jobs. Anon still cannot select that table.
-- Pins use the same quarter-mile offset already stored on public.public_prices.

create index if not exists public_prices_open_geo
    on public.public_prices (latitude, longitude)
    where offered_price_cents > 0
      and status in ('open', 'posted', 'awaitingAcceptance');

create or replace function public.public_open_jobs(
    min_lat double precision,
    min_lng double precision,
    max_lat double precision,
    max_lng double precision,
    row_limit integer default 80
)
returns table (
    id uuid,
    category text,
    service_type text,
    city text,
    state text,
    zip text,
    latitude double precision,
    longitude double precision,
    offered_price_cents integer,
    timing text,
    scheduled_on date,
    created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select
        p.id,
        p.category,
        p.service_type,
        p.city,
        p.state,
        p.zip,
        p.latitude,
        p.longitude,
        p.offered_price_cents,
        j.timing,
        p.scheduled_on,
        p.created_at
    from public.public_prices p
    left join public.jobs j on j.id = p.id
    where p.offered_price_cents > 0
      and p.status in ('open', 'posted', 'awaitingAcceptance')
      and p.latitude is not null
      and p.longitude is not null
      and p.latitude between least(min_lat, max_lat) and greatest(min_lat, max_lat)
      and p.longitude between least(min_lng, max_lng) and greatest(min_lng, max_lng)
    order by p.created_at desc
    limit least(greatest(coalesce(row_limit, 80), 1), 100);
$$;

revoke all on function public.public_open_jobs(double precision, double precision, double precision, double precision, integer) from public;
grant execute on function public.public_open_jobs(double precision, double precision, double precision, double precision, integer) to anon, authenticated;
