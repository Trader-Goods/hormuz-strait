-- Customers can read nearby prices without seeing who posted the job or the street.
-- Apply after 20261028190000_pro_phone.sql.

grant select on public.job_board to authenticated;
grant select on public.job_listings to authenticated;
revoke all on public.job_board from public, anon;
revoke all on public.job_listings from public, anon;

create table if not exists public.public_prices (
    id uuid primary key references public.jobs (id) on delete cascade,
    category text not null,
    service_type text not null default '',
    city text not null default '',
    state text not null default '',
    zip text not null,
    latitude double precision,
    longitude double precision,
    offered_price_cents integer not null default 0,
    estimated_minutes integer not null default 0,
    status text not null,
    scheduled_on date not null,
    created_at timestamptz not null default now()
);

alter table public.public_prices enable row level security;

drop policy if exists "authenticated read public prices" on public.public_prices;
create policy "authenticated read public prices" on public.public_prices
    for select to authenticated
    using (
        offered_price_cents > 0
        and status in ('open', 'posted', 'awaitingAcceptance', 'booked', 'completed', 'approved')
    );

revoke all on public.public_prices from public, anon;
grant select on public.public_prices to authenticated;

create or replace function public.sync_public_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.public_prices (
        id, category, service_type, city, state, zip, latitude, longitude,
        offered_price_cents, estimated_minutes, status, scheduled_on, created_at
    ) values (
        new.id, new.category, new.service_type, new.city, new.state, new.zip,
        public.approx_latitude(new.latitude, new.id),
        public.approx_longitude(new.latitude, new.longitude, new.id),
        new.offered_price_cents, new.estimated_minutes, new.status, new.scheduled_on, new.created_at
    )
    on conflict (id) do update set
        category = excluded.category,
        service_type = excluded.service_type,
        city = excluded.city,
        state = excluded.state,
        zip = excluded.zip,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        offered_price_cents = excluded.offered_price_cents,
        estimated_minutes = excluded.estimated_minutes,
        status = excluded.status,
        scheduled_on = excluded.scheduled_on;
    return new;
end;
$$;

drop trigger if exists jobs_sync_public_price on public.jobs;
create trigger jobs_sync_public_price
    after insert or update on public.jobs
    for each row execute function public.sync_public_price();

insert into public.public_prices (
    id, category, service_type, city, state, zip, latitude, longitude,
    offered_price_cents, estimated_minutes, status, scheduled_on, created_at
)
select
    j.id, j.category, j.service_type, j.city, j.state, j.zip,
    public.approx_latitude(j.latitude, j.id),
    public.approx_longitude(j.latitude, j.longitude, j.id),
    j.offered_price_cents, j.estimated_minutes, j.status, j.scheduled_on, j.created_at
from public.jobs j
on conflict (id) do nothing;

revoke all on function public.sync_public_price() from public, anon, authenticated;

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
  and status in ('open', 'posted', 'awaitingAcceptance', 'booked', 'completed', 'approved');

revoke all on public.price_board from public, anon;
grant select on public.price_board to authenticated;
