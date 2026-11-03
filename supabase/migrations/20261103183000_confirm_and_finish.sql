-- When the customer needs the work, how a pro is booked, and how a job is finished.
-- Apply after 20261030233000_pro_open_jobs.sql.
-- Posting does not charge a card. A pro's acceptance waits for the customer to confirm.
-- Confirming records a hold and does not capture a card. This build does not send a payout.

alter table public.jobs add column if not exists timing text;
alter table public.jobs drop constraint if exists jobs_timing_check;
alter table public.jobs add constraint jobs_timing_check
    check (timing is null or timing in ('asap', 'thisWeek', 'flexible'));

alter table public.jobs add column if not exists confirm_by timestamptz;
alter table public.jobs add column if not exists started_at timestamptz;
alter table public.jobs add column if not exists marked_done_at timestamptz;
alter table public.jobs add column if not exists approved_at timestamptz;
alter table public.jobs add column if not exists completion_note text not null default '';
alter table public.jobs add column if not exists completion_photos text[] not null default '{}';

alter table public.job_listings add column if not exists timing text;

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
        allows_multiple, estimate, estimated_minutes, listed_until, timing
    ) values (
        new.id, new.customer_id, new.category, new.city, new.state, new.zip,
        public.approx_latitude(new.latitude, new.id),
        public.approx_longitude(new.latitude, new.longitude, new.id),
        new.scheduled_on, new.details, new.status, new.photo_names, new.created_at,
        new.service_type, new.offered_price_cents, new.allows_multiple, new.estimate,
        new.estimated_minutes, new.listed_until, new.timing
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
        listed_until = excluded.listed_until,
        timing = excluded.timing;
    return new;
end;
$$;

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
    l.listed_until,
    l.timing
from public.job_listings l
where l.status in ('open', 'posted', 'awaitingAcceptance');

revoke all on public.pro_open_jobs from public, anon;
grant select on public.pro_open_jobs to authenticated;

-- Accepting no longer books the job. The customer confirms before anyone is booked.
create or replace function public.assign_job(p_job_id uuid, p_pro_id uuid, p_price integer, p_quote_id uuid)
returns public.bookings
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
        where b.job_id = j.id and b.pro_id = p_pro_id
          and coalesce(b.charge->>'status', '') not in ('failed', 'canceled')
    ) then
        raise exception 'already booked';
    end if;
    if j.allows_multiple is not true and exists (
        select 1 from public.bookings b
        where b.job_id = j.id
          and coalesce(b.charge->>'status', '') not in ('failed', 'canceled')
    ) then
        raise exception 'taken';
    end if;

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
        j.id, p_quote_id, p_pro_id, j.customer_id, p_price, fee, 5, false,
        jsonb_build_object(
            'amountCents', p_price,
            'applicationFeeCents', fee,
            'proPayoutCents', payout,
            'processingCents', 0,
            'currency', 'usd',
            'status', 'pending',
            'connectedAccountID', coalesce(pro.stripe_account_id, '')
        ),
        ''
    )
    returning * into result;

    if j.allows_multiple is true then
        update public.jobs set status = 'awaitingAcceptance' where id = j.id;
    else
        update public.jobs
        set status = 'awaitingPayment',
            confirm_by = now() + interval '24 hours'
        where id = j.id;
    end if;

    insert into public.notices (user_id, title, body, job_id)
    values
        (j.customer_id, 'Pro accepted', 'A pro accepted your job. Confirm & pay to book them.', j.id),
        (p_pro_id, 'Waiting for the customer', 'The customer has 24 hours to confirm. You are not booked yet.', j.id);
    insert into public.audit_log (actor_id, job_id, action, detail)
    values (auth.uid(), j.id, 'accepted', 'Waiting for the customer to confirm. No card yet.');
    return result;
end;
$$;

create or replace function public.confirm_and_pay(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
    updated integer;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found or j.customer_id <> auth.uid() then
        raise exception 'wrong account';
    end if;
    update public.bookings
    set paid_in_app = true,
        charge = jsonb_set(charge, '{status}', '"authorized"')
    where job_id = j.id
      and customer_id = auth.uid()
      and coalesce(charge->>'status', '') = 'pending';
    get diagnostics updated = row_count;
    if updated = 0 then
        raise exception 'closed';
    end if;
    if j.allows_multiple is not true then
        update public.jobs
        set status = 'booked', confirm_by = null
        where id = j.id;
    end if;
    insert into public.notices (user_id, title, body, job_id)
    select b.pro_id, 'You are booked', 'The customer confirmed. The street is available. The price is authorized, not captured.', j.id
    from public.bookings b
    where b.job_id = j.id and coalesce(b.charge->>'status', '') = 'authorized';
end;
$$;

create or replace function public.expire_unconfirmed_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    row record;
begin
    for row in
        select id from public.jobs
        where status = 'awaitingPayment'
          and confirm_by is not null
          and confirm_by <= now()
        for update
    loop
        update public.jobs
        set status = 'awaitingAcceptance', confirm_by = null
        where id = row.id;
        insert into public.notices (user_id, title, body, job_id)
        select b.pro_id, 'Acceptance expired', 'The customer did not confirm. This job is open again.', row.id
        from public.bookings b
        where b.job_id = row.id and coalesce(b.charge->>'status', '') = 'pending';
        update public.bookings
        set charge = jsonb_set(charge, '{status}', '"canceled"')
        where job_id = row.id and coalesce(charge->>'status', '') = 'pending';
    end loop;
end;
$$;

create or replace function public.start_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found or j.status <> 'booked' then
        raise exception 'closed';
    end if;
    if not exists (
        select 1 from public.bookings b
        where b.job_id = j.id and b.pro_id = auth.uid() and b.paid_in_app
          and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
    ) then
        raise exception 'wrong account';
    end if;
    update public.jobs set status = 'inProgress', started_at = now() where id = j.id;
end;
$$;

create or replace function public.mark_job_done(p_job_id uuid, p_note text, p_photos text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found or j.status <> 'inProgress' then
        raise exception 'closed';
    end if;
    if not exists (
        select 1 from public.bookings b
        where b.job_id = j.id and b.pro_id = auth.uid() and b.paid_in_app
          and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
    ) then
        raise exception 'wrong account';
    end if;
    update public.jobs
    set status = 'awaitingReview',
        marked_done_at = now(),
        completion_note = coalesce(p_note, ''),
        completion_photos = coalesce(p_photos, '{}')
    where id = j.id;
    insert into public.notices (user_id, title, body, job_id)
    values (j.customer_id, 'Job done', 'The contractor marked this job done. Approve it, or report a problem.', j.id);
end;
$$;

create or replace function public.approve_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found or j.customer_id <> auth.uid() or j.status <> 'awaitingReview' then
        raise exception 'wrong account';
    end if;
    update public.jobs
    set status = 'completed', approved_at = now()
    where id = j.id;
end;
$$;

create or replace function public.report_job_problem(p_job_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    j public.jobs%rowtype;
begin
    if auth.uid() is null or coalesce(trim(p_reason), '') = '' then
        raise exception 'invalid';
    end if;
    select * into j from public.jobs where id = p_job_id for update;
    if not found or j.customer_id <> auth.uid() or j.status <> 'awaitingReview' then
        raise exception 'wrong account';
    end if;
    update public.jobs
    set status = 'disputed',
        completion_note = case
            when completion_note = '' then trim(p_reason)
            else completion_note || E'\n' || trim(p_reason)
        end
    where id = j.id;
end;
$$;

create or replace function public.auto_approve_due_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.jobs
    set status = 'completed', approved_at = now()
    where status = 'awaitingReview'
      and marked_done_at is not null
      and marked_done_at <= now() - interval '48 hours';
end;
$$;

revoke all on function public.confirm_and_pay(uuid) from public, anon;
revoke all on function public.expire_unconfirmed_jobs() from public, anon;
revoke all on function public.start_job(uuid) from public, anon;
revoke all on function public.mark_job_done(uuid, text, text[]) from public, anon;
revoke all on function public.approve_job(uuid) from public, anon;
revoke all on function public.report_job_problem(uuid, text) from public, anon;
revoke all on function public.auto_approve_due_jobs() from public, anon;
grant execute on function public.confirm_and_pay(uuid) to authenticated;
grant execute on function public.expire_unconfirmed_jobs() to authenticated;
grant execute on function public.start_job(uuid) to authenticated;
grant execute on function public.mark_job_done(uuid, text, text[]) to authenticated;
grant execute on function public.approve_job(uuid) to authenticated;
grant execute on function public.report_job_problem(uuid, text) to authenticated;
grant execute on function public.auto_approve_due_jobs() to authenticated;

update public.pricing_rates
set card = '{
  "disclaimer": "Default regional rates are editable configuration. They are not a survey of local prices, and photos are not used to measure the job.",
  "regions": [
    {
      "id": "default",
      "name": "US default",
      "zipPrefixes": [],
      "factor": 1,
      "services": {
        "mowing": {"smallCents": 5500, "mediumCents": 7500, "largeCents": 11500, "smallMinutes": 45, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1500, "obstacleMinutes": 15},
        "edging": {"smallCents": 4000, "mediumCents": 5500, "largeCents": 7500, "smallMinutes": 30, "mediumMinutes": 40, "largeMinutes": 55, "obstacleCents": 1000, "obstacleMinutes": 10},
        "trimming": {"smallCents": 4500, "mediumCents": 6500, "largeCents": 9500, "smallMinutes": 40, "mediumMinutes": 55, "largeMinutes": 80, "obstacleCents": 1500, "obstacleMinutes": 15},
        "hedgeTrim": {"smallCents": 11000, "mediumCents": 18000, "largeCents": 28000, "smallMinutes": 60, "mediumMinutes": 90, "largeMinutes": 150, "obstacleCents": 2500, "obstacleMinutes": 20},
        "leafCleanup": {"smallCents": 16000, "mediumCents": 24000, "largeCents": 36000, "smallMinutes": 60, "mediumMinutes": 90, "largeMinutes": 140, "obstacleCents": 2500, "obstacleMinutes": 20},
        "mulching": {"smallCents": 16000, "mediumCents": 24000, "largeCents": 37000, "smallMinutes": 60, "mediumMinutes": 90, "largeMinutes": 150, "obstacleCents": 2000, "obstacleMinutes": 20},
        "gutters": {"smallCents": 12000, "mediumCents": 17500, "largeCents": 24000, "smallMinutes": 60, "mediumMinutes": 90, "largeMinutes": 120, "obstacleCents": 2500, "obstacleMinutes": 20},
        "junkRemoval": {"smallCents": 20000, "mediumCents": 33000, "largeCents": 50000, "smallMinutes": 60, "mediumMinutes": 120, "largeMinutes": 180, "obstacleCents": 4000, "obstacleMinutes": 30},
        "landscaping": {"smallCents": 16000, "mediumCents": 25000, "largeCents": 40000, "smallMinutes": 90, "mediumMinutes": 150, "largeMinutes": 240, "obstacleCents": 4000, "obstacleMinutes": 30},
        "yardOther": {"smallCents": 6000, "mediumCents": 10000, "largeCents": 16000, "smallMinutes": 45, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1500, "obstacleMinutes": 15},
        "moving": {"smallCents": 16000, "mediumCents": 26000, "largeCents": 40000, "smallMinutes": 120, "mediumMinutes": 180, "largeMinutes": 240, "obstacleCents": 4000, "obstacleMinutes": 30}
      }
    },
    {"id": "nwOhio", "name": "Northwest Ohio", "zipPrefixes": ["435", "436"], "factor": 0.75, "services": {}},
    {"id": "ohio", "name": "Ohio", "zipPrefixes": ["43", "44", "45"], "factor": 0.8, "services": {}}
  ]
}'::jsonb,
    updated_at = now()
where id = 'default';

do $$
begin
    perform cron.schedule(
        'contractor-expire-unconfirmed',
        '10 * * * *',
        'select public.expire_unconfirmed_jobs()'
    );
    perform cron.schedule(
        'contractor-auto-approve',
        '15 * * * *',
        'select public.auto_approve_due_jobs()'
    );
exception
    when undefined_table or undefined_function or insufficient_privilege then
        null;
end $$;
