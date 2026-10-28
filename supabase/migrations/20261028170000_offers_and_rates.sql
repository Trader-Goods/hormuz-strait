-- Offer price, flat 5% fee, and street redaction.
-- Apply after 20261028000000_contractor.sql.
-- Fee math for a live project is in accept_listing / accept_offer, not in the app.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('customer', 'pro', 'admin'));

alter table public.pro_profiles add column if not exists service_types text[] not null default '{}';
alter table public.pro_profiles add column if not exists identity_verified boolean not null default false;
alter table public.pro_profiles add column if not exists payouts_ready boolean not null default false;
alter table public.pro_profiles add column if not exists stripe_account_id text not null default '';

alter table public.jobs add column if not exists service_type text not null default '';
alter table public.jobs add column if not exists offered_price_cents integer not null default 0;
alter table public.jobs add column if not exists allows_multiple boolean not null default false;
alter table public.jobs add column if not exists estimate jsonb;
alter table public.jobs add column if not exists estimated_minutes integer not null default 0;
alter table public.jobs add column if not exists listed_until timestamptz;

alter table public.jobs drop constraint if exists jobs_status_check;
alter table public.jobs add constraint jobs_status_check check (status in (
    'draft', 'posted', 'awaitingAcceptance', 'awaitingPayment', 'booked', 'inProgress',
    'awaitingReview', 'disputed', 'approved', 'payoutProcessing', 'completed', 'canceled',
    'open', 'cancelled'
));

alter table public.bookings drop constraint if exists bookings_job_id_key;

drop trigger if exists quotes_limit on public.quotes;
drop function if exists public.limit_quotes();

create table if not exists public.notices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    title text not null,
    body text not null,
    job_id uuid references public.jobs (id) on delete cascade,
    read boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.audit_log (
    id uuid primary key default gen_random_uuid(),
    actor_id uuid references public.profiles (id),
    job_id uuid references public.jobs (id) on delete cascade,
    action text not null,
    detail text not null default '',
    created_at timestamptz not null default now()
);

create table if not exists public.pricing_rates (
    id text primary key,
    card jsonb not null,
    updated_at timestamptz not null default now()
);

insert into public.pricing_rates (id, card)
values (
    'default',
    '{
      "disclaimer": "Default regional rates are editable configuration. They are not a survey of local prices, and photos are not used to measure the job.",
      "regions": [{
        "id": "default",
        "name": "US default",
        "zipPrefixes": [],
        "services": {
          "mowing": {"smallCents": 5500, "mediumCents": 8500, "largeCents": 13000, "smallMinutes": 45, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1500, "obstacleMinutes": 15},
          "edging": {"smallCents": 3500, "mediumCents": 5000, "largeCents": 7500, "smallMinutes": 30, "mediumMinutes": 40, "largeMinutes": 55, "obstacleCents": 1000, "obstacleMinutes": 10},
          "trimming": {"smallCents": 4500, "mediumCents": 7000, "largeCents": 11000, "smallMinutes": 40, "mediumMinutes": 55, "largeMinutes": 80, "obstacleCents": 2000, "obstacleMinutes": 20},
          "leafCleanup": {"smallCents": 6000, "mediumCents": 9500, "largeCents": 15000, "smallMinutes": 50, "mediumMinutes": 75, "largeMinutes": 110, "obstacleCents": 2000, "obstacleMinutes": 20},
          "landscaping": {"smallCents": 12000, "mediumCents": 20000, "largeCents": 35000, "smallMinutes": 90, "mediumMinutes": 150, "largeMinutes": 240, "obstacleCents": 4000, "obstacleMinutes": 30},
          "yardOther": {"smallCents": 5000, "mediumCents": 8000, "largeCents": 12000, "smallMinutes": 45, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1500, "obstacleMinutes": 15},
          "moving": {"smallCents": 18000, "mediumCents": 32000, "largeCents": 48000, "smallMinutes": 120, "mediumMinutes": 210, "largeMinutes": 300, "obstacleCents": 5000, "obstacleMinutes": 30}
        }
      }]
    }'::jsonb
)
on conflict (id) do nothing;

create or replace function public.miles_between(
    lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision
) returns double precision
language sql
immutable
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
as $$
    select case
        when lat is null or lon is null then null
        else lon + ((0.25 * 1609.344) / (111320.0 * greatest(0.2, cos(radians(lat)))))
            * sin((get_byte(uuid_send(job_id), 0)::float8 / 255.0) * 2 * pi())
    end;
$$;

create or replace function public.address_unlocked(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.jobs j
        where j.id = p_job_id and j.customer_id = auth.uid()
    ) or exists (
        select 1 from public.bookings b
        where b.job_id = p_job_id
          and b.pro_id = auth.uid()
          and b.paid_in_app
          and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
    );
$$;

drop view if exists public.job_board;
create view public.job_board
with (security_invoker = false)
as
select
    j.id,
    j.customer_id,
    j.category,
    case when public.address_unlocked(j.id) then j.street else '' end as street,
    j.city,
    j.state,
    j.zip,
    case when public.address_unlocked(j.id) then j.latitude else public.approx_latitude(j.latitude, j.id) end as latitude,
    case when public.address_unlocked(j.id) then j.longitude else public.approx_longitude(j.latitude, j.longitude, j.id) end as longitude,
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
where j.customer_id = auth.uid()
   or j.status in ('open', 'posted', 'awaitingAcceptance')
   or exists (
        select 1 from public.bookings b
        where b.job_id = j.id and (b.pro_id = auth.uid() or b.customer_id = auth.uid())
   );

grant select on public.job_board to authenticated;

create or replace function public.assign_job(
    p_job_id uuid,
    p_pro_id uuid,
    p_price integer,
    p_quote_id uuid
) returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
    pro public.pro_profiles%rowtype;
    profile public.profiles%rowtype;
    fee integer;
    payout integer;
    result public.bookings%rowtype;
    miles double precision;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    if p_price is null or p_price <= 0 then
        raise exception 'invalid price';
    end if;
    select * into profile from public.profiles where id = p_pro_id;
    if not found or profile.role <> 'pro' or profile.phone_verified is not true then
        raise exception 'not verified';
    end if;
    select * into pro from public.pro_profiles where id = p_pro_id;
    if not found or pro.identity_verified is not true or pro.payouts_ready is not true then
        raise exception 'not ready';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found then
        raise exception 'missing';
    end if;
    if j.status not in ('open', 'posted', 'awaitingAcceptance') then
        raise exception 'closed';
    end if;
    if coalesce(array_length(pro.service_types, 1), 0) > 0 then
        if not (j.service_type = any(pro.service_types) or (j.service_type = '' and j.category = any(pro.categories))) then
            raise exception 'outside area';
        end if;
    elsif not (j.category = any(pro.categories)) then
        raise exception 'outside area';
    end if;
    if pro.latitude is not null and pro.longitude is not null and j.latitude is not null and j.longitude is not null then
        miles := public.miles_between(pro.latitude, pro.longitude, j.latitude, j.longitude);
        if miles > greatest(pro.radius_miles, 1) then
            raise exception 'outside area';
        end if;
    end if;
    if exists (
        select 1 from public.bookings b
        where b.job_id = j.id and b.pro_id = p_pro_id and coalesce(b.charge->>'status', '') <> 'failed'
    ) then
        raise exception 'already booked';
    end if;
    if j.allows_multiple is not true and exists (
        select 1 from public.bookings b
        where b.job_id = j.id and coalesce(b.charge->>'status', '') <> 'failed'
    ) then
        raise exception 'taken';
    end if;

    update public.jobs set status = 'awaitingPayment' where id = j.id;
    fee := p_price * 5 / 100;
    payout := p_price - fee;
    if j.allows_multiple is not true then
        update public.quotes set status = 'declined'
        where job_id = j.id and id <> p_quote_id;
    end if;
    insert into public.bookings (
        job_id, quote_id, pro_id, customer_id, price_cents, fee_cents, fee_percent,
        paid_in_app, charge, recurrence
    ) values (
        j.id, p_quote_id, p_pro_id, j.customer_id, p_price, fee, 5, true,
        jsonb_build_object(
            'amountCents', p_price,
            'applicationFeeCents', fee,
            'proPayoutCents', payout,
            'processingCents', 0,
            'currency', 'usd',
            'status', 'authorized',
            'connectedAccountID', coalesce(pro.stripe_account_id, '')
        ),
        ''
    )
    returning * into result;

    update public.jobs
    set status = case when j.allows_multiple then 'awaitingAcceptance' else 'booked' end
    where id = j.id;

    insert into public.notices (user_id, title, body, job_id)
    values
        (j.customer_id, 'Job accepted', 'A contractor accepted. The price is authorized, not captured. The street is now available to that contractor.', j.id),
        (p_pro_id, 'You are booked', 'The street address is available on this job. The customer has not been charged yet.', j.id);
    insert into public.audit_log (actor_id, job_id, action, detail)
    values (auth.uid(), j.id, 'booked', 'Authorized ' || p_price || ' cents. Fee ' || fee || ' cents. Status authorized, not captured.');
    return result;
end;
$$;

create or replace function public.accept_listing(p_job_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
    quote_id uuid;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found then
        raise exception 'missing';
    end if;
    insert into public.quotes (job_id, pro_id, price_cents, message, status)
    values (j.id, auth.uid(), j.offered_price_cents, 'Accepted the offered price.', 'accepted')
    on conflict (job_id, pro_id) do update
        set price_cents = excluded.price_cents, message = excluded.message, status = 'accepted'
    returning id into quote_id;
    return public.assign_job(j.id, auth.uid(), j.offered_price_cents, quote_id);
end;
$$;

create or replace function public.accept_offer(p_offer_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
    q public.quotes%rowtype;
    j public.jobs%rowtype;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into q from public.quotes where id = p_offer_id for update;
    if not found or q.status <> 'sent' then
        raise exception 'closed';
    end if;
    select * into j from public.jobs where id = q.job_id for update;
    if j.customer_id <> auth.uid() then
        raise exception 'wrong account';
    end if;
    update public.quotes set status = 'accepted' where id = q.id;
    return public.assign_job(q.job_id, q.pro_id, q.price_cents, q.id);
end;
$$;

revoke all on function public.assign_job(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.accept_listing(uuid) to authenticated;
grant execute on function public.accept_offer(uuid) to authenticated;
grant execute on function public.address_unlocked(uuid) to authenticated;

alter table public.notices enable row level security;
alter table public.audit_log enable row level security;
alter table public.pricing_rates enable row level security;

drop policy if exists "read own notices" on public.notices;
create policy "read own notices" on public.notices
    for select to authenticated
    using (user_id = auth.uid());

drop policy if exists "read related audit" on public.audit_log;
create policy "read related audit" on public.audit_log
    for select to authenticated
    using (
        actor_id = auth.uid()
        or exists (
            select 1 from public.jobs j
            where j.id = audit_log.job_id and j.customer_id = auth.uid()
        )
        or exists (
            select 1 from public.bookings b
            where b.job_id = audit_log.job_id and b.pro_id = auth.uid()
        )
    );

drop policy if exists "read rate card" on public.pricing_rates;
create policy "read rate card" on public.pricing_rates
    for select to authenticated
    using (true);

drop policy if exists "customers read own jobs" on public.jobs;
drop policy if exists "read jobs you own or are booked on" on public.jobs;
create policy "read jobs you own or are booked on" on public.jobs
    for select to authenticated
    using (
        customer_id = auth.uid()
        or exists (
            select 1 from public.bookings b
            where b.job_id = jobs.id
              and b.pro_id = auth.uid()
              and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
        )
    );
