-- Northwest Ohio local prices for ZIP prefixes 435 and 436, after 20261103183000_confirm_and_finish.sql.
-- Mowing, leaf cleanup, and hedge trimming below are the local amounts. They are not multiplied
-- by the 0.75 factor. Edging and moving stay on that factor.

update public.pricing_rates
set card = jsonb_set(
        card,
        '{regions}',
        (
            select jsonb_agg(
                case
                    when region->>'id' = 'nwOhio' then jsonb_set(
                        region,
                        '{services}',
                        '{
                          "mowing": {"smallCents": 4800, "mediumCents": 6500, "largeCents": 10000, "smallMinutes": 45, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1000, "obstacleMinutes": 15},
                          "leafCleanup": {"smallCents": 3500, "mediumCents": 5000, "largeCents": 7500, "smallMinutes": 40, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1000, "obstacleMinutes": 15},
                          "hedgeTrim": {"smallCents": 4000, "mediumCents": 5500, "largeCents": 8000, "smallMinutes": 40, "mediumMinutes": 60, "largeMinutes": 90, "obstacleCents": 1000, "obstacleMinutes": 15}
                        }'::jsonb
                    )
                    else region
                end
                order by ord
            )
            from jsonb_array_elements(card->'regions') with ordinality as rows(region, ord)
        )
    ),
    updated_at = now()
where id = 'default';
