--MaxCompute SQL
-- Store performance report for the Operations team.
-- Grain: two coexisting grains in one partition, separated by `grain`:
--   grain='store'  -> one row per store per business date
--   grain='region' -> one rolled-up row per region per business date (store_id/store_name/channel are NULL)
-- Sources: ads_store_daily_sales (metrics, produced by wf_nova_dw_daily/ads_store_daily)
--          dim_store (attributes, produced by wf_nova_dw_daily/dim_load; non-partitioned full refresh).
-- Caliber: gmv_incl_refund = paid + refunded, incl. tax; gmv_excl_refund = paid only, incl. tax.
--          avg_order_value = gmv_excl_refund / order_cnt (net-of-refunds caliber).
-- Attributes come from dim_store only, so a store row and its region rollup can never disagree
-- because ads_store_daily_sales carries a stale denormalized region.
-- Downstream must filter on `grain`: summing a whole partition double-counts every store.

CREATE TABLE IF NOT EXISTS ads_store_perf_report (
  grain           STRING        COMMENT 'Row grain: store (per store) or region (region rollup)',
  store_id        BIGINT        COMMENT 'Store ID; NULL on region rollup rows',
  store_name      STRING        COMMENT 'Store name from dim_store; NULL on region rollup rows',
  region          STRING        COMMENT 'Region from dim_store, always populated; rollup key for grain=region',
  channel         STRING        COMMENT 'Sales channel offline/online from dim_store; NULL on region rollup rows',
  order_cnt       BIGINT        COMMENT 'Order count',
  gmv_incl_refund DECIMAL(38,18) COMMENT 'GMV incl. refunds (paid+refunded, incl. tax)',
  gmv_excl_refund DECIMAL(38,18) COMMENT 'GMV excl. refunds (paid only, incl. tax)',
  avg_order_value DECIMAL(38,6) COMMENT 'Average order value = gmv_excl_refund / order_cnt; NULL when order_cnt is 0'
)
COMMENT 'Daily store performance report with region rollup (Operations team)'
PARTITIONED BY (dt STRING COMMENT 'Business date yyyyMMdd')
LIFECYCLE 365;

-- Empty-day guard (same mechanism as ads_member_churn_tag). Without odps.sql.udf.strict.mode an
-- illegal cast returns NULL instead of failing, so the node would overwrite a good partition with
-- zero rows. The sentinel string is uncastable by construction, which aborts the run before the
-- INSERT when the metric partition is empty.
set odps.sql.udf.strict.mode=true;

SELECT CAST(CASE WHEN metric_cnt > 0 THEN '1'
                 ELSE CONCAT('STORE_PERF_GUARD_ABORT_EMPTY_METRIC_', CAST(metric_cnt AS STRING))
            END AS BIGINT) AS store_perf_guard_ok
FROM (
  SELECT COUNT(*) AS metric_cnt
  FROM nova_dw.ads_store_daily_sales
  WHERE dt = '${bizdate}'
) guard;

INSERT OVERWRITE TABLE ads_store_perf_report PARTITION (dt = '${bizdate}')
SELECT
  CASE WHEN GROUPING(base.store_id) = 1 THEN 'region' ELSE 'store' END AS grain,
  CASE WHEN GROUPING(base.store_id) = 1 THEN CAST(NULL AS BIGINT) ELSE base.store_id END AS store_id,
  -- dim_store is unique on store_id, so MAX only satisfies the aggregate rule; it picks no winner.
  CASE WHEN GROUPING(base.store_id) = 1 THEN CAST(NULL AS STRING) ELSE MAX(base.store_name) END AS store_name,
  base.region,
  CASE WHEN GROUPING(base.store_id) = 1 THEN CAST(NULL AS STRING) ELSE MAX(base.channel) END AS channel,
  SUM(base.order_cnt) AS order_cnt,
  SUM(base.gmv_incl_refund) AS gmv_incl_refund,
  SUM(base.gmv_excl_refund) AS gmv_excl_refund,
  CASE WHEN SUM(base.order_cnt) > 0
       THEN CAST(ROUND(SUM(base.gmv_excl_refund) / SUM(base.order_cnt), 6) AS DECIMAL(38,6))
       ELSE CAST(NULL AS DECIMAL(38,6))
  END AS avg_order_value
FROM (
  SELECT
    m.store_id,
    COALESCE(d.store_name, m.store_name) AS store_name,
    -- A store absent from dim_store, or one with no region either side, must not fall into a
    -- NULL-labelled rollup bucket that downstream cannot tell from the store-grain NULL marker.
    COALESCE(d.region, m.region, 'Unknown') AS region,
    d.channel,
    m.order_cnt,
    m.gmv_incl_refund,
    m.gmv_excl_refund
  FROM (
    SELECT store_id, store_name, region, order_cnt, gmv_incl_refund, gmv_excl_refund
    FROM nova_dw.ads_store_daily_sales
    WHERE dt = '${bizdate}'
  ) m
  LEFT JOIN nova_dw.dim_store d
    ON d.store_id = m.store_id
) base
GROUP BY GROUPING SETS ((base.store_id, base.region), (base.region));