--MaxCompute SQL
-- Node: dws_member_campaign_daily -- daily member campaign response (Marketing team).
-- Target project nova_dw is TWO-TIER (threeTierModel=false): no schema level, so the target table is
--   written unqualified and every source is read as nova_dw.<table>. Only single-line "--" comments.
--
-- Grain: exactly ONE row per (dt, member_id) over the FULL registered-member roster, so members with
--   zero orders on the business date still get a row (marketing needs response / penetration rates).
-- Sources: nova_dw.dwd_order_detail -> dt-partitioned (yyyyMMdd), ORDER-LINE grain (one order_id spans
--   several rows); nova_dw.dim_member and nova_dw.dim_item -> NON-partitioned, therefore read with no
--   partition predicate at all (requirement 5).
-- Caliber (governed semantic model, never substituted):
--   gmv_incl_refund = order_status IN ('paid','refunded') lines, SUM(pay_amt_incl_tax)  -- incl. tax
--   gmv_excl_refund = order_status = 'paid' lines,              SUM(pay_amt_incl_tax)  -- incl. tax
--   refund_amt      = gmv_incl_refund - gmv_excl_refund; refunds are attributed to the ORDER DATE (the
--   fact dt partition), no refund date exists; pay_amt_excl_tax / pay_amt are never used.
-- Order counts are always COUNT(DISTINCT order_id): on order-line grain COUNT(order_id) / COUNT(*)
--   would count lines, not orders.
-- Join-key uniqueness of dim_member.member_id and dim_item.item_id could NOT be profiled, so each
--   dimension is pre-collapsed with GROUP BY <key> + MAX(<attr>) before it touches the fact: a
--   duplicate dimension row can then never fan out a fact row or inflate a SUM, and the roster itself
--   cannot break the (dt, member_id) grain. MAX() over an already-grouped key is deterministic.

set odps.sql.decimal.odps2=true;
set odps.sql.udf.strict.mode=true;

CREATE TABLE IF NOT EXISTS dws_member_campaign_daily (
  member_id          BIGINT         COMMENT 'Member ID; business key together with dt',
  city               STRING         COMMENT 'Member residence city from dim_member (campaign teams are organised by city)',
  level              STRING         COMMENT 'Membership tier V1-V5 from dim_member',
  order_cnt          BIGINT         COMMENT 'Distinct orders placed on this date, all statuses incl. pending',
  paid_order_cnt     BIGINT         COMMENT 'Distinct orders with order_status = paid',
  refunded_order_cnt BIGINT         COMMENT 'Distinct orders with order_status = refunded',
  gmv_incl_refund    DECIMAL(38,18) COMMENT 'GMV incl. refunds (paid+refunded, incl. tax) - governed caliber',
  gmv_excl_refund    DECIMAL(38,18) COMMENT 'GMV excl. refunds (paid only, incl. tax) - governed caliber',
  refund_amt         DECIMAL(38,18) COMMENT 'Refunded incl-tax amount on this date = gmv_incl_refund - gmv_excl_refund',
  top_category       STRING         COMMENT 'Single best-selling category for the member on this date; NULL when no paid/refunded order',
  top_categories     STRING         COMMENT 'Top 3 categories as a pipe-joined string, ordered best first, NULL-padded-free'
)
COMMENT 'Daily member campaign response; one row per member per business date (Marketing team)'
PARTITIONED BY (dt STRING COMMENT 'Business date yyyyMMdd')
LIFECYCLE 365;

-- Fail-closed empty-partition guard (project convention). Without odps.sql.udf.strict.mode an illegal
-- cast returns NULL instead of failing, so an empty dt = '${bizdate}' partition would silently
-- OVERWRITE a good partition with zero rows. The sentinel string is uncastable by construction, so the
-- run aborts here, before the INSERT, whenever the day's fact partition is empty.
SELECT CAST(CASE WHEN metric_cnt > 0 THEN '1'
                 ELSE CONCAT('DWS_MEMBER_CAMPAIGN_ABORT_EMPTY_', CAST(metric_cnt AS STRING))
            END AS BIGINT) AS guard_ok
FROM (
  SELECT COUNT(*) AS metric_cnt
  FROM nova_dw.dwd_order_detail
  WHERE dt = '${bizdate}'
) guard;

-- Roster drives the result; both aggregate branches are unique on member_id, so the LEFT JOINs keep
-- the one-row-per-(dt, member_id) guarantee. Count/amount columns are zero-filled with typed literals;
-- top_category / top_categories stay NULL for members without a ranked category.
INSERT OVERWRITE TABLE dws_member_campaign_daily PARTITION (dt = '${bizdate}')
SELECT
  m.member_id                                          AS member_id,
  m.city                                               AS city,
  m.level                                              AS level,
  COALESCE(a.order_cnt, CAST(0 AS BIGINT))             AS order_cnt,
  COALESCE(a.paid_order_cnt, CAST(0 AS BIGINT))        AS paid_order_cnt,
  COALESCE(a.refunded_order_cnt, CAST(0 AS BIGINT))    AS refunded_order_cnt,
  CAST(COALESCE(a.gmv_incl_refund, CAST(0 AS DECIMAL(38,18))) AS DECIMAL(38,18)) AS gmv_incl_refund,
  CAST(COALESCE(a.gmv_excl_refund, CAST(0 AS DECIMAL(38,18))) AS DECIMAL(38,18)) AS gmv_excl_refund,
  CAST(COALESCE(a.gmv_incl_refund, CAST(0 AS DECIMAL(38,18)))
     - COALESCE(a.gmv_excl_refund, CAST(0 AS DECIMAL(38,18))) AS DECIMAL(38,18)) AS refund_amt,
  t.top_category_1                                     AS top_category,
  -- Explicit CASE chain instead of an unordered string aggregation: MaxCompute CONCAT_WS returns NULL
  -- when ANY argument is NULL, and WM_CONCAT ordering is not rank-guaranteed. Ranks are contiguous
  -- (ROW_NUMBER), so each branch below has three / two / one non-NULL categories and CONCAT is never
  -- fed a NULL. No ranked category at all -> NULL, not '' and not the literal 'NULL'.
  CASE WHEN t.top_category_3 IS NOT NULL THEN CONCAT(t.top_category_1, '|', t.top_category_2, '|', t.top_category_3)
       WHEN t.top_category_2 IS NOT NULL THEN CONCAT(t.top_category_1, '|', t.top_category_2)
       WHEN t.top_category_1 IS NOT NULL THEN t.top_category_1
       ELSE CAST(NULL AS STRING)
  END                                                  AS top_categories
FROM (
  -- Full member roster, collapsed to one row per member_id (uniqueness is not profiled).
  SELECT
    member_id,
    MAX(city)  AS city,
    MAX(level) AS level
  FROM nova_dw.dim_member
  GROUP BY member_id
) m
LEFT JOIN (
  -- Per-member day metrics; the dt predicate gives partition pruning.
  SELECT
    member_id,
    COUNT(DISTINCT order_id)                                              AS order_cnt,
    COUNT(DISTINCT CASE WHEN order_status = 'paid' THEN order_id END)      AS paid_order_cnt,
    COUNT(DISTINCT CASE WHEN order_status = 'refunded' THEN order_id END)  AS refunded_order_cnt,
    SUM(CASE WHEN order_status IN ('paid','refunded') THEN pay_amt_incl_tax
             ELSE CAST(0 AS DECIMAL(38,18)) END)                          AS gmv_incl_refund,
    SUM(CASE WHEN order_status = 'paid' THEN pay_amt_incl_tax
             ELSE CAST(0 AS DECIMAL(38,18)) END)                          AS gmv_excl_refund
  FROM nova_dw.dwd_order_detail
  WHERE dt = '${bizdate}'
  GROUP BY member_id
) a
  ON a.member_id = m.member_id
LEFT JOIN (
  -- Top 3 categories per member, pivoted from a deterministic rank (requirement 3).
  SELECT
    member_id,
    MAX(CASE WHEN rn = 1 THEN category END) AS top_category_1,
    MAX(CASE WHEN rn = 2 THEN category END) AS top_category_2,
    MAX(CASE WHEN rn = 3 THEN category END) AS top_category_3
  FROM (
    SELECT
      member_id,
      category,
      -- cat_gmv DESC, category ASC is a total order: category is unique per member after the GROUP BY,
      -- so ROW_NUMBER needs no arbitrary tie-breaking and reruns are reproducible.
      ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY cat_gmv DESC, category ASC) AS rn
    FROM (
      SELECT
        f.member_id AS member_id,
        i.category  AS category,
        SUM(f.pay_amt_incl_tax) AS cat_gmv
      FROM (
        -- Ranking population: paid + refunded order lines only, same governed incl-tax caliber.
        SELECT member_id, item_id, pay_amt_incl_tax
        FROM nova_dw.dwd_order_detail
        WHERE dt = '${bizdate}'
          AND order_status IN ('paid','refunded')
      ) f
      JOIN (
        -- Fan-out-immune item dimension: unique per item_id by construction, so a duplicate item row
        -- cannot double a member's category GMV. Non-partitioned -> no partition predicate here.
        SELECT item_id, MAX(category) AS category
        FROM nova_dw.dim_item
        GROUP BY item_id
      ) i
        ON i.item_id = f.item_id
      WHERE i.category IS NOT NULL
      GROUP BY f.member_id, i.category
    ) g
  ) r
  WHERE r.rn <= 3
  GROUP BY member_id
) t
  ON t.member_id = m.member_id;