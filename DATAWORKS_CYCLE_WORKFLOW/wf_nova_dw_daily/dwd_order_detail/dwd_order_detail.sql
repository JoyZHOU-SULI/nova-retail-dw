--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-13 09:59:41
--********************************************************************--
INSERT OVERWRITE TABLE dwd_order_detail PARTITION (dt = '${bizdate}')
SELECT
  o.order_id, o.member_id, o.store_id, o.item_id, o.quantity,
  ROUND(o.pay_amt / 1.13, 2)                              AS pay_amt_excl_tax,
  o.pay_amt                                               AS pay_amt_incl_tax,
  CASE WHEN o.order_status = 'refunded' THEN 1 ELSE 0 END AS is_refunded,
  o.order_status
FROM nova_dw.nova_orders_sales_order o;

-- SELECT * FROM table_not_exists;