-- Pro profile bio and photo path. Apply after 20261030120000_map_open_jobs_only.sql.
-- The app still saves radius and services if this file has not been applied yet.

alter table public.pro_profiles
    add column if not exists bio text not null default '';

alter table public.pro_profiles
    add column if not exists avatar_path text not null default '';
