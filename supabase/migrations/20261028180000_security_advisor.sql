-- Security advisor fixes for Contractor Pros.
-- job_board no longer runs as the view owner. Open jobs are read from job_listings,
-- which has no street column. The jobs table still hides unbooked rows behind RLS.
-- Apply in the Supabase SQL editor after 20261028170000_offers_and_rates.sql.

create table if not exists public.job_listings (
    id uuid primary key references public.jobs (id) on delete cascade,
    customer_id uuid not null,
    category text not null,
    city text not null default '',
    state text not null default '',
    zip text not null,
    latitude double precision,
    longitude double precision,
    scheduled_on date not null,
    details jsonb not null default '{}'::jsonb,
    status text not null,
    photo_names text[] not null default '{}',
    created_at timestamptz not null default now(),
    service_type text not null default '',
    offered_price_cents integer not null default 0,
    allows_multiple boolean not null default false,
    estimate jsonb,
    estimated_minutes integer not null default 0,
    listed_until timestamptz
);

alter table public.job_listings enable row level security;

drop policy if exists "read listed or involved jobs" on public.job_listings;
create policy "read listed or involved jobs" on public.job_listings
    for select to authenticated
    using (
        status in ('open', 'posted', 'awaitingAcceptance')
        or customer_id = auth.uid()
        or exists (
            select 1 from public.bookings b
            where b.job_id = job_listings.id
              and (b.pro_id = auth.uid() or b.customer_id = auth.uid())
        )
    );

create or replace function public.miles_between(
    lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision
) returns double precision
language sql
immutable
set search_path = public
as $$
    select 3958.8 * 2 * atan2(sqrt(a), sqrt(greatest(0, 1 - a)))
    from (
        select power(sin(radians(lat2 - lat1) / 2), 2)
            + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2) as a
    ) t;
$$;

create or replace function public.approx_latitude(lat double precision, job_id uuid)
returns double precision
language sql
immutable
set search_path = public
as $$
    select case
        when lat is null then null
        else lat + ((0.25 * 1609.344) / 111320.0) * cos((get_byte(uuid_send(job_id), 0)::float8 / 255.0) * 2 * pi())
    end;
$$;

create or replace function public.approx_longitude(lat double precision, lon double precision, job_id uuid)
returns double precision
language sql
immutable
set search_path = public
as $$
    select case
        when lat is null or lon is null then null
        else lon + ((0.25 * 1609.344) / (111320.0 * greatest(0.2, cos(radians(lat)))))
            * sin((get_byte(uuid_send(job_id), 0)::float8 / 255.0) * 2 * pi())
    end;
$$;

create or replace function public.address_unlocked(p_job_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if auth.uid() is null or p_job_id is null then
        return false;
    end if;
    return exists (
        select 1 from public.jobs j
        where j.id = p_job_id and j.customer_id = auth.uid()
    ) or exists (
        select 1 from public.bookings b
        where b.job_id = p_job_id
          and b.pro_id = auth.uid()
          and b.paid_in_app
          and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
    );
end;
$$;

create or replace function public.sync_job_listing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.job_listings (
        id, customer_id, category, city, state, zip, latitude, longitude, scheduled_on,
        details, status, photo_names, created_at, service_type, offered_price_cents,
        allows_multiple, estimate, estimated_minutes, listed_until
    ) values (
        new.id, new.customer_id, new.category, new.city, new.state, new.zip,
        public.approx_latitude(new.latitude, new.id),
        public.approx_longitude(new.latitude, new.longitude, new.id),
        new.scheduled_on, new.details, new.status, new.photo_names, new.created_at,
        new.service_type, new.offered_price_cents, new.allows_multiple, new.estimate,
        new.estimated_minutes, new.listed_until
    )
    on conflict (id) do update set
        customer_id = excluded.customer_id,
        category = excluded.category,
        city = excluded.city,
        state = excluded.state,
        zip = excluded.zip,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        scheduled_on = excluded.scheduled_on,
        details = excluded.details,
        status = excluded.status,
        photo_names = excluded.photo_names,
        service_type = excluded.service_type,
        offered_price_cents = excluded.offered_price_cents,
        allows_multiple = excluded.allows_multiple,
        estimate = excluded.estimate,
        estimated_minutes = excluded.estimated_minutes,
        listed_until = excluded.listed_until;
    return new;
end;
$$;

drop trigger if exists jobs_sync_listing on public.jobs;
create trigger jobs_sync_listing
    after insert or update on public.jobs
    for each row execute function public.sync_job_listing();

insert into public.job_listings (
    id, customer_id, category, city, state, zip, latitude, longitude, scheduled_on,
    details, status, photo_names, created_at, service_type, offered_price_cents,
    allows_multiple, estimate, estimated_minutes, listed_until
)
select
    j.id, j.customer_id, j.category, j.city, j.state, j.zip,
    public.approx_latitude(j.latitude, j.id),
    public.approx_longitude(j.latitude, j.longitude, j.id),
    j.scheduled_on, j.details, j.status, j.photo_names, j.created_at,
    j.service_type, j.offered_price_cents, j.allows_multiple, j.estimate,
    j.estimated_minutes, j.listed_until
from public.jobs j
on conflict (id) do nothing;

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
where not exists (
    select 1 from public.jobs j where j.id = l.id
);

revoke all on public.job_board from public, anon;
revoke all on public.job_listings from public, anon;
grant select on public.job_board to authenticated;
grant select on public.job_listings to authenticated;

revoke all on function public.accept_listing(uuid) from public, anon;
revoke all on function public.accept_offer(uuid) from public, anon;
revoke all on function public.address_unlocked(uuid) from public, anon;
grant execute on function public.accept_listing(uuid) to authenticated;
grant execute on function public.accept_offer(uuid) to authenticated;
grant execute on function public.address_unlocked(uuid) to authenticated;

revoke all on function public.assign_job(uuid, uuid, integer, uuid) from public, anon, authenticated;
revoke all on function public.miles_between(double precision, double precision, double precision, double precision) from public, anon, authenticated;
revoke all on function public.approx_latitude(double precision, uuid) from public, anon, authenticated;
revoke all on function public.approx_longitude(double precision, double precision, uuid) from public, anon, authenticated;
revoke all on function public.sync_job_listing() from public, anon, authenticated;

-- job-photos is a private bucket.
-- Customer uploads go in {auth.uid}/{file}.jpg.
-- Completion photos go in completions/{job_id}/{file}.jpg and only the assigned contractor can upload them.

drop policy if exists "job owner uploads photos" on storage.objects;
create policy "job owner uploads photos" on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'job-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "job owner reads own photos" on storage.objects;
create policy "job owner reads own photos" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'job-photos'
        and (
            owner = auth.uid()
            or (storage.foldername(name))[1] = auth.uid()::text
        )
    );

drop policy if exists "contractors read posted job photos" on storage.objects;
create policy "contractors read posted job photos" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'job-photos'
        and exists (
            select 1 from public.job_listings l
            where name = any(l.photo_names)
              and l.status in ('open', 'posted', 'awaitingAcceptance')
        )
    );

drop policy if exists "assigned contractor uploads completion photos" on storage.objects;
create policy "assigned contractor uploads completion photos" on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'job-photos'
        and (storage.foldername(name))[1] = 'completions'
        and exists (
            select 1 from public.bookings b
            where b.pro_id = auth.uid()
              and (storage.foldername(name))[2] = b.job_id::text
        )
    );

drop policy if exists "booking parties read completion photos" on storage.objects;
create policy "booking parties read completion photos" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'job-photos'
        and (storage.foldername(name))[1] = 'completions'
        and exists (
            select 1 from public.bookings b
            where (storage.foldername(name))[2] = b.job_id::text
              and (b.pro_id = auth.uid() or b.customer_id = auth.uid())
        )
    );

drop policy if exists "owner deletes own photos" on storage.objects;
create policy "owner deletes own photos" on storage.objects
    for delete to authenticated
    using (
        bucket_id = 'job-photos'
        and owner = auth.uid()
    );
