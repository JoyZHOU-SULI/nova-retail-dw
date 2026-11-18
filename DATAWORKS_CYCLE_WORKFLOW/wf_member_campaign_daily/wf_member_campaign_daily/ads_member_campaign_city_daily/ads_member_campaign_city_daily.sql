--MaxCompute SQL
-- Node: ads_member_campaign_city_daily -- member campaign review by city team (Marketing team).
-- Target project nova_dw is TWO-TIER (threeTierModel=false): the target is written unqualified and every
--   source is read as nova_dw.<table>. Only single-line "--" comments, no DROP TABLE.
-- Grain: ONE ROW PER CITY PER BUSINESS DATE; only the static partition dt = '${bizdate}' is written.
--
-- Sources and why each is used:
--   nova_dw.dws_member_campaign_daily (member grain, dt-pruned) -> every member / order / GMV metric.
--     Rolled up with SUM/COUNT straight from the member table so the city review ties out to it exactly;
--     the order-line fact is NOT re-aggregated for these columns.
--   nova_dw.dwd_order_detail + dim_item + dim_member -> the city category ranking only. A per-member
--     top-category string cannot be re-ranked into a city answer, so this is the single measure rebuilt
--     from the fact, restricted to 'paid'/'refunded' lines and ranked by the governed gmv_incl_refund
--     caliber (SUM of pay_amt_incl_tax on those lines).
--
-- Governed GMV caliber (authoritative, never substituted):
--   gmv_incl_refund = paid + refunded, incl. tax; gmv_excl_refund = paid only, incl. tax;
--   refund_amt = gmv_incl_refund - gmv_excl_refund. Refunds are attributed to the ORDER DATE, i.e. the
--   fact partition dt = '${bizdate}'. pay_amt_excl_tax and pay_amt are never used.
--
-- Fan-out immunity: dim_item.item_id and dim_member.member_id are only documented as primary keys and
--   their uniqueness was never profiled, so each dimension is pre-collapsed (GROUP BY key + MAX(attr))
--   and is unique on its join key by construction before it touches the fact. No raw dimension is ever
--   joined onto the fact and then summed, so a duplicated dimension row cannot inflate city category GMV.
--
-- City key: NULL or blank city becomes 'Unknown' through one identical expression on both sides, so no
--   member GMV silently disappears from the city review and the two sides always agree on the join key.
--
-- registered_member_cnt uses COUNT(*) because the upstream grain is already one row per member; order
--   counts are never taken from the order-line fact here.
-- Determinism: no group string concatenation and no arbitrary tie-breaking. Ranking is
--   ROW_NUMBER() OVER (PARTITION BY city ORDER BY cat_gmv_incl_refund DESC, category ASC), pivoted back
--   with MAX(CASE WHEN rn = k THEN category END), which has one non-NULL input per rank.

set odps.sql.decimal.odps2=true;
set odps.sql.udf.strict.mode=true;

CREATE TABLE IF NOT EXISTS ads_member_campaign_city_daily (
  city                           STRING         COMMENT 'Campaign city team (member residence city)',
  registered_member_cnt          BIGINT         COMMENT 'Members on the roster for this city on this date',
  active_member_cnt              BIGINT         COMMENT 'Members with at least one order placed (order_cnt > 0)',
  paying_member_cnt              BIGINT         COMMENT 'Members with at least one paid order (paid_order_cnt > 0)',
  order_cnt                      BIGINT         COMMENT 'Orders placed in the city (sum of member order_cnt)',
  paid_order_cnt                 BIGINT         COMMENT 'Paid orders in the city',
  refunded_order_cnt             BIGINT         COMMENT 'Refunded orders in the city',
  gmv_incl_refund                DECIMAL(38,18) COMMENT 'GMV incl. refunds (paid+refunded, incl. tax) - governed caliber',
  gmv_excl_refund                DECIMAL(38,18) COMMENT 'GMV excl. refunds (paid only, incl. tax) - governed caliber',
  refund_amt                     DECIMAL(38,18) COMMENT 'Refunded incl-tax amount = gmv_incl_refund - gmv_excl_refund',
  refund_rate                    DECIMAL(38,6)  COMMENT 'refund_amt / gmv_incl_refund; NULL when gmv_incl_refund is 0 or NULL',
  avg_gmv_excl_refund_per_member DECIMAL(38,6)  COMMENT 'gmv_excl_refund / active member count; NULL when there is no active member',
  top_category                   STRING         COMMENT 'Best-selling category in the city on this date',
  top_categories                 STRING         COMMENT 'Top 3 city categories, pipe-joined, best first'
)
COMMENT 'Daily member campaign metrics by city team (marketing city review)'
PARTITIONED BY (dt STRING COMMENT 'Business date yyyyMMdd')
LIFECYCLE 365;

-- Fail-closed empty-partition guard (project convention), against the table that drives the output grain.
-- Without odps.sql.udf.strict.mode an illegal cast returns NULL instead of failing, so an empty partition
-- would silently OVERWRITE a good one with zero rows. The sentinel string is uncastable by construction,
-- so the run aborts here, before the INSERT.
SELECT CAST(CASE WHEN metric_cnt > 0 THEN '1'
                 ELSE CONCAT('ADS_MEMBER_CAMPAIGN_CITY_ABORT_EMPTY_', CAST(metric_cnt AS STRING))
            END AS BIGINT) AS guard_ok
FROM (
  SELECT COUNT(*) AS metric_cnt
  FROM nova_dw.dws_member_campaign_daily
  WHERE dt = '${bizdate}'
) guard;

INSERT OVERWRITE TABLE ads_member_campaign_city_daily PARTITION (dt = '${bizdate}')
SELECT
  m.city,
  m.registered_member_cnt,
  m.active_member_cnt,
  m.paying_member_cnt,
  m.order_cnt,
  m.paid_order_cnt,
  m.refunded_order_cnt,
  m.gmv_incl_refund,
  m.gmv_excl_refund,
  -- refund_amt is rolled up from the member table, where it is already gmv_incl_refund - gmv_excl_refund;
  -- recomputing it here would break the tie-out to the member grain.
  m.refund_amt,
  -- NULL, never 0 and never a division by zero: a city with no incl-refund GMV has no refund rate.
  CASE WHEN m.gmv_incl_refund IS NULL OR m.gmv_incl_refund = 0
       THEN CAST(NULL AS DECIMAL(38,6))
       ELSE CAST(ROUND(m.refund_amt / m.gmv_incl_refund, 6) AS DECIMAL(38,6))
  END AS refund_rate,
  -- The BIGINT denominator is cast to DECIMAL so the ratio stays in the decimal type family instead of
  -- degrading to DOUBLE. NULL when the city has no active member.
  CASE WHEN m.active_member_cnt IS NULL OR m.active_member_cnt = 0
       THEN CAST(NULL AS DECIMAL(38,6))
       ELSE CAST(ROUND(m.gmv_excl_refund / CAST(m.active_member_cnt AS DECIMAL(38,18)), 6) AS DECIMAL(38,6))
  END AS avg_gmv_excl_refund_per_member,
  c.top_category,
  -- MaxCompute CONCAT returns NULL when ANY argument is NULL, so '' (never NULL) is the "rank absent"
  -- filler and the all-NULL case is handled by the outer branch: no ranked category gives NULL, not ''
  -- and not the text 'NULL'. ROW_NUMBER ranks are contiguous after WHERE rn <= 3, so a NULL rank 2 with
  -- a non-NULL rank 3 cannot occur and no dangling '|' is possible.
  CASE WHEN c.top_category IS NULL
       THEN CAST(NULL AS STRING)
       ELSE CONCAT(
              c.top_category,
              CASE WHEN c.category_rank_2 IS NULL THEN '' ELSE CONCAT('|', c.category_rank_2) END,
              CASE WHEN c.category_rank_3 IS NULL THEN '' ELSE CONCAT('|', c.category_rank_3) END
            )
  END AS top_categories
FROM (
  -- City rollup of the member-grain upstream; the dt predicate gives partition pruning. No other filter,
  -- because the roster for the date is the denominator of registered_member_cnt. The DECIMAL rollups
  -- carry an explicit landing type instead of relying on inferred numeric propagation.
  SELECT
    COALESCE(NULLIF(TRIM(city), ''), 'Unknown')          AS city,
    COUNT(*)                                             AS registered_member_cnt,
    SUM(CASE WHEN order_cnt > 0 THEN 1 ELSE 0 END)       AS active_member_cnt,
    SUM(CASE WHEN paid_order_cnt > 0 THEN 1 ELSE 0 END)  AS paying_member_cnt,
    SUM(order_cnt)                                       AS order_cnt,
    SUM(paid_order_cnt)                                  AS paid_order_cnt,
    SUM(refunded_order_cnt)                              AS refunded_order_cnt,
    CAST(SUM(gmv_incl_refund) AS DECIMAL(38,18))         AS gmv_incl_refund,
    CAST(SUM(gmv_excl_refund) AS DECIMAL(38,18))         AS gmv_excl_refund,
    CAST(SUM(refund_amt) AS DECIMAL(38,18))              AS refund_amt
  FROM nova_dw.dws_member_campaign_daily
  WHERE dt = '${bizdate}'
  GROUP BY COALESCE(NULLIF(TRIM(city), ''), 'Unknown')
) m
LEFT JOIN (
  -- Category ranking per city, pivoted out of the ROW_NUMBER ranks. MAX has exactly one non-NULL input per
  -- (city, rank), so it picks no winner and the result is deterministic. GROUP BY city gives one row per
  -- city, matching m, so this LEFT JOIN cannot fan out or break the one-row-per-city grain.
  SELECT
    city,
    MAX(CASE WHEN rn = 1 THEN category END) AS top_category,
    MAX(CASE WHEN rn = 2 THEN category END) AS category_rank_2,
    MAX(CASE WHEN rn = 3 THEN category END) AS category_rank_3
  FROM (
    SELECT
      city,
      category,
      -- cat_gmv_incl_refund DESC, category ASC is a total order: category is unique per city after the
      -- GROUP BY, so reruns are reproducible without arbitrary tie-breaking.
      ROW_NUMBER() OVER (PARTITION BY city ORDER BY cat_gmv_incl_refund DESC, category ASC) AS rn
    FROM (
      SELECT
        -- Same 'Unknown' fallback as the member rollup, so a line whose member is missing from
        -- dim_member or whose city is blank still lands in the city bucket the roster uses.
        COALESCE(NULLIF(TRIM(dm.city), ''), 'Unknown')      AS city,
        -- An item absent from dim_item keeps its GMV visible as 'Unknown' instead of being dropped from
        -- the ranking, which would otherwise inflate the relative share of known categories.
        COALESCE(NULLIF(TRIM(di.category), ''), 'Unknown')  AS category,
        -- Governed caliber only: pay_amt_incl_tax on paid + refunded lines. The zero filler is typed as
        -- DECIMAL(38,18) so the CASE cannot fall back to an INT/DOUBLE common type and degrade the SUM
        -- that the ranking ORDER BY depends on.
        SUM(CASE WHEN f.order_status IN ('paid', 'refunded') THEN f.pay_amt_incl_tax
                 ELSE CAST(0 AS DECIMAL(38,18)) END)        AS cat_gmv_incl_refund
      FROM (
        -- Order-line grain fact, partition-pruned to the business date. Only 'paid' and 'refunded' lines
        -- carry governed GMV; 'pending' lines are excluded. Order counts are never taken from here.
        SELECT member_id, item_id, order_status, pay_amt_incl_tax
        FROM nova_dw.dwd_order_detail
        WHERE dt = '${bizdate}'
          AND order_status IN ('paid', 'refunded')
      ) f
      LEFT JOIN (
        -- Fan-out-immune item dimension: unique on item_id by construction. Non-partitioned, so it
        -- carries no partition predicate.
        SELECT item_id, MAX(category) AS category
        FROM nova_dw.dim_item
        GROUP BY item_id
      ) di
        ON di.item_id = f.item_id
      LEFT JOIN (
        -- Fan-out-immune member dimension: unique on member_id by construction. NULLIF(TRIM(city),'') is
        -- applied before MAX so blanks never outrank a real city among duplicate member rows.
        -- Non-partitioned, so it carries no partition predicate.
        SELECT member_id, MAX(NULLIF(TRIM(city), '')) AS city
        FROM nova_dw.dim_member
        GROUP BY member_id
      ) dm
        ON dm.member_id = f.member_id
      GROUP BY
        COALESCE(NULLIF(TRIM(dm.city), ''), 'Unknown'),
        COALESCE(NULLIF(TRIM(di.category), ''), 'Unknown')
    ) city_cat
  ) city_cat_rank
  WHERE rn <= 3
  GROUP BY city
) c
  ON c.city = m.city;