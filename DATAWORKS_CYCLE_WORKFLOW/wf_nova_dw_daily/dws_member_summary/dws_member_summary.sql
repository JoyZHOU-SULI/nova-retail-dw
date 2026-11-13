--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-13 10:00:15
--********************************************************************--
INSERT OVERWRITE TABLE dws_member_summary PARTITION (dt = '${bizdate}')
SELECT
  m.member_id, m.city, m.level,
  COUNT(o.order_id)  AS order_cnt_90d,
  SUM(o.pay_amt)     AS pay_amt_90d,
  SUM(CASE WHEN o.order_status = 'refunded' THEN 1 ELSE 0 END) AS refund_cnt_90d,
  CAST(MAX(o.order_date) AS DATETIME) AS last_order_date
FROM nova_dw.ods_member m
LEFT JOIN nova_dw.nova_orders_sales_order o
  ON o.member_id = m.member_id
WHERE m.ds = '${bizdate}'
GROUP BY m.member_id, m.city, m.level;