-- Contractors must store a US phone number in E.164.
-- Customers may leave phone null.
-- The number is not readable through a normal profile select. profile_card
-- returns it only to the account owner or to someone on an authorized booking.
-- Apply after 20261028180000_security_advisor.sql.
-- If this fails because a contractor row already exists, set that row's phone first.

alter table public.profiles add column if not exists phone text;

alter table public.profiles drop constraint if exists profiles_phone_e164_check;
alter table public.profiles add constraint profiles_phone_e164_check
    check (phone is null or phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$');

alter table public.profiles drop constraint if exists profiles_pro_phone_required;
alter table public.profiles add constraint profiles_pro_phone_required
    check (role is distinct from 'pro' or phone is not null);

revoke select (phone) on public.profiles from public, anon, authenticated;

create or replace function public.profile_card(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    viewer uuid := auth.uid();
    p public.profiles%rowtype;
    show_phone boolean := false;
begin
    if viewer is null or p_id is null then
        return null;
    end if;
    select * into p from public.profiles where id = p_id;
    if not found then
        return null;
    end if;
    if p.id <> viewer and p.role <> 'pro' and not exists (
        select 1 from public.bookings b
        where (b.customer_id = viewer and b.pro_id = p.id)
           or (b.pro_id = viewer and b.customer_id = p.id)
    ) then
        return null;
    end if;
    show_phone := p.id = viewer or exists (
        select 1 from public.bookings b
        where b.paid_in_app
          and coalesce(b.charge->>'status', '') in ('authorized', 'captured')
          and (
              (b.customer_id = viewer and b.pro_id = p.id)
              or (b.pro_id = viewer and b.customer_id = p.id)
          )
    );
    return jsonb_build_object(
        'id', p.id,
        'role', p.role,
        'email', p.email,
        'display_name', p.display_name,
        'zip', p.zip,
        'phone_verified', p.phone_verified,
        'phone', case when show_phone then p.phone else null end
    );
end;
$$;

revoke all on function public.profile_card(uuid) from public, anon;
grant execute on function public.profile_card(uuid) to authenticated;
