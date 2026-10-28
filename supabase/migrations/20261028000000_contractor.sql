-- Contractor marketplace for Richland County, Ohio.
-- Apply in the Supabase SQL editor, or with the Supabase CLI:
--   supabase db push
-- Then create a private storage bucket named job-photos.
-- In Authentication, turn off "Confirm email" until the app handles confirmation.
-- Put the project URL and anon key in Info.plist as SUPABASE_URL and SUPABASE_ANON_KEY.
-- Leave those keys empty to keep the on-device demo used by TestFlight.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    role text not null check (role in ('customer', 'pro')),
    email text not null,
    display_name text not null,
    zip text not null,
    phone_verified boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.pro_profiles (
    id uuid primary key references public.profiles (id) on delete cascade,
    business_name text not null,
    categories text[] not null default '{}',
    service_zips text[] not null default '{}',
    rating double precision not null default 0,
    review_count integer not null default 0
);

create table if not exists public.jobs (
    id uuid primary key default gen_random_uuid(),
    customer_id uuid not null references public.profiles (id) on delete cascade,
    category text not null check (category in ('lawn', 'moving')),
    street text not null,
    zip text not null,
    scheduled_on date not null,
    details jsonb not null default '{}'::jsonb,
    status text not null default 'open' check (status in ('open', 'booked', 'completed', 'cancelled')),
    photo_names text[] not null default '{}',
    created_at timestamptz not null default now()
);

create table if not exists public.quotes (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.jobs (id) on delete cascade,
    pro_id uuid not null references public.profiles (id) on delete cascade,
    price_cents integer not null check (price_cents > 0),
    message text not null default '',
    status text not null default 'sent' check (status in ('sent', 'accepted', 'declined')),
    created_at timestamptz not null default now(),
    unique (job_id, pro_id)
);

create table if not exists public.bookings (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null unique references public.jobs (id) on delete cascade,
    quote_id uuid not null unique references public.quotes (id) on delete cascade,
    pro_id uuid not null references public.profiles (id),
    customer_id uuid not null references public.profiles (id),
    price_cents integer not null,
    fee_cents integer not null,
    created_at timestamptz not null default now()
);

create table if not exists public.messages (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.jobs (id) on delete cascade,
    pro_id uuid not null references public.profiles (id),
    sender_id uuid not null references public.profiles (id),
    body text not null,
    created_at timestamptz not null default now()
);

create table if not exists public.reviews (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null unique references public.jobs (id) on delete cascade,
    pro_id uuid not null references public.profiles (id),
    customer_id uuid not null references public.profiles (id),
    rating integer not null check (rating between 1 and 5),
    body text not null default '',
    created_at timestamptz not null default now()
);

create or replace function public.limit_quotes()
returns trigger
language plpgsql
as $$
begin
    if (select count(*) from public.quotes where job_id = new.job_id) >= 3 then
        raise exception 'This job already has 3 quotes';
    end if;
    return new;
end;
$$;

drop trigger if exists quotes_limit on public.quotes;
create trigger quotes_limit
    before insert on public.quotes
    for each row execute function public.limit_quotes();

alter table public.profiles enable row level security;
alter table public.pro_profiles enable row level security;
alter table public.jobs enable row level security;
alter table public.quotes enable row level security;
alter table public.bookings enable row level security;
alter table public.messages enable row level security;
alter table public.reviews enable row level security;

create policy "read own profile or pros" on public.profiles
    for select to authenticated
    using (id = auth.uid() or role = 'pro');

create policy "insert own profile" on public.profiles
    for insert to authenticated
    with check (id = auth.uid());

create policy "update own profile" on public.profiles
    for update to authenticated
    using (id = auth.uid());

create policy "read pro profiles" on public.pro_profiles
    for select to authenticated
    using (true);

create policy "write own pro profile" on public.pro_profiles
    for all to authenticated
    using (id = auth.uid())
    with check (id = auth.uid());

create policy "customers read own jobs" on public.jobs
    for select to authenticated
    using (
        customer_id = auth.uid()
        or exists (
            select 1 from public.quotes q
            where q.job_id = jobs.id and q.pro_id = auth.uid()
        )
        or (
            status = 'open'
            and (select count(*) from public.quotes q where q.job_id = jobs.id) < 3
        )
    );

create policy "customers insert jobs" on public.jobs
    for insert to authenticated
    with check (customer_id = auth.uid());

create policy "customers update own jobs" on public.jobs
    for update to authenticated
    using (customer_id = auth.uid());

create policy "read quotes on involved jobs" on public.quotes
    for select to authenticated
    using (
        pro_id = auth.uid()
        or exists (
            select 1 from public.jobs j
            where j.id = quotes.job_id and j.customer_id = auth.uid()
        )
    );

create policy "pros insert quotes" on public.quotes
    for insert to authenticated
    with check (pro_id = auth.uid());

create policy "update quotes on involved jobs" on public.quotes
    for update to authenticated
    using (
        pro_id = auth.uid()
        or exists (
            select 1 from public.jobs j
            where j.id = quotes.job_id and j.customer_id = auth.uid()
        )
    );

create policy "read own bookings" on public.bookings
    for select to authenticated
    using (customer_id = auth.uid() or pro_id = auth.uid());

create policy "customers insert bookings" on public.bookings
    for insert to authenticated
    with check (customer_id = auth.uid());

create policy "read own messages" on public.messages
    for select to authenticated
    using (
        sender_id = auth.uid()
        or pro_id = auth.uid()
        or exists (
            select 1 from public.jobs j
            where j.id = messages.job_id and j.customer_id = auth.uid()
        )
    );

create policy "send messages" on public.messages
    for insert to authenticated
    with check (sender_id = auth.uid());

create policy "read reviews" on public.reviews
    for select to authenticated
    using (true);

create policy "customers insert reviews" on public.reviews
    for insert to authenticated
    with check (customer_id = auth.uid());
