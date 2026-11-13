--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-13 10:01:00
--********************************************************************--
INSERT OVERWRITE TABLE ads_store_daily_sales PARTITION (dt = '${bizdate}')
SELECT
  CAST(s.store_id AS BIGINT) AS store_id,
  s.store_name, s.region,
  SUM(CASE WHEN o.order_status IN ('paid','refunded') THEN o.pay_amt ELSE 0 END) AS gmv_incl_refund,
  SUM(CASE WHEN o.order_status = 'paid' THEN o.pay_amt ELSE 0 END)               AS gmv_excl_refund,
  COUNT(o.order_id) AS order_cnt
FROM nova_dw.ods_store s
LEFT JOIN nova_dw.nova_orders_sales_order o
  ON CAST(s.store_id AS BIGINT) = o.store_id
WHERE s.ds = '${bizdate}'
GROUP BY CAST(s.store_id AS BIGINT), s.store_name, s.region;