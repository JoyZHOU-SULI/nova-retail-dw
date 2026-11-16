--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-13 10:00:15
--********************************************************************--
INSERT OVERWRITE TABLE dws_member_summary PARTITION (dt = '${bizdate}')
SELECT
  m.member_id, m.city, m.level,
  COUNT(o.order_id)     AS order_cnt_90d,
  SUM(o.pay_amt_incl_tax) AS pay_amt_90d,
  SUM(CASE WHEN o.order_status = 'refunded' THEN 1 ELSE 0 END) AS refund_cnt_90d,
  TO_DATE(MAX(o.dt), 'yyyymmdd') AS last_order_date
FROM nova_dw.ods_member m
LEFT JOIN nova_dw.dwd_order_detail o
  ON o.member_id = m.member_id
 AND o.dt >= REPLACE(SUBSTR(CAST(DATEADD(TO_DATE(CONCAT(SUBSTR('${bizdate}',1,4),'-',
              SUBSTR('${bizdate}',5,2),'-',SUBSTR('${bizdate}',7,2)),'yyyy-mm-dd'),
              -90, 'dd') AS STRING),1,10),'-','')
 AND o.dt <= '${bizdate}'
WHERE m.ds = '${bizdate}'
GROUP BY m.member_id, m.city, m.level;