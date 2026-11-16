--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-13 10:07:34
--********************************************************************--
-- ---------- Conformed dimensions ----------
CREATE TABLE IF NOT EXISTS dim_store (
  store_id   BIGINT      COMMENT 'Store ID, primary key. FK target of dwd_order_detail.store_id',
  store_name STRING      COMMENT 'Store name',
  city       STRING      COMMENT 'City where the store operates',
  region     STRING      COMMENT 'Region for geographic drill-down (e.g. East/Central/South/West)',
  channel    STRING      COMMENT 'Sales channel: offline or online',
  open_date  DATETIME    COMMENT 'Store opening date'
) COMMENT 'Store conformed dimension. One row per store.'
LIFECYCLE 1095;

DROP TABLE IF EXISTS dim_member;
CREATE TABLE IF NOT EXISTS dim_member (
  member_id     BIGINT   COMMENT 'Member ID, primary key. FK target of dwd_order_detail.member_id',
  member_name   STRING   COMMENT 'Member display name',
  phone         STRING   COMMENT 'Member contact phone (plaintext; masked at query time by dynamic data-masking policy)',
  city          STRING   COMMENT 'City of residence',
  register_date DATETIME COMMENT 'Member registration date',
  level         STRING   COMMENT 'Membership tier: V1-V5'
) COMMENT 'Member conformed dimension. One row per member.'
LIFECYCLE 1095;

DROP TABLE IF EXISTS dim_item;
CREATE TABLE IF NOT EXISTS dim_item (
  item_id    BIGINT         COMMENT 'Item ID, primary key. FK target of dwd_order_detail.item_id',
  item_name  STRING         COMMENT 'Item display name',
  category   STRING         COMMENT 'Item category',
  unit_price DECIMAL(38,18) COMMENT 'Retail price per unit',
  cost_price DECIMAL(38,18) COMMENT 'Cost price per unit'
) COMMENT 'Item conformed dimension. One row per item.'
LIFECYCLE 1095;

-- ---------- DWD fact ----------
CREATE TABLE IF NOT EXISTS dwd_order_detail (
  order_id     BIGINT COMMENT 'Order ID',
  member_id    BIGINT COMMENT 'Member ID (FK dim_member)',
  store_id     BIGINT COMMENT 'Store ID (FK dim_store)',
  item_id      BIGINT COMMENT 'Item ID (FK dim_item)',
  quantity     BIGINT,
  pay_amt_excl_tax DECIMAL(38,18) COMMENT 'Payment amount excl. tax',
  pay_amt_incl_tax DECIMAL(38,18) COMMENT 'Payment amount incl. tax (metric field)',
  is_refunded  BIGINT COMMENT 'Refund flag 0/1',
  order_status STRING
) COMMENT 'Order detail fact table (for baseline alert demo)'
PARTITIONED BY (dt STRING COMMENT 'Business date yyyyMMdd') LIFECYCLE 365;

-- ---------- DWS summary ----------
CREATE TABLE IF NOT EXISTS dws_member_summary (
  member_id    BIGINT COMMENT 'Member ID',
  city         STRING,
  level        STRING,
  order_cnt_90d   BIGINT COMMENT 'Order count, last 90 days',
  pay_amt_90d     DECIMAL(38,18) COMMENT 'Paid amount incl. tax incl. refunds, last 90 days',
  refund_cnt_90d  BIGINT,
  last_order_date DATETIME
) COMMENT 'Member summary (source for churn tag demo)'
PARTITIONED BY (dt STRING COMMENT 'Business date') LIFECYCLE 365;

-- ---------- ADS ----------
CREATE TABLE IF NOT EXISTS ads_store_daily_sales (
  store_id    BIGINT,
  store_name  STRING,
  region      STRING,
  gmv_incl_refund DECIMAL(38,18) COMMENT 'GMV incl. refunds (paid+refunded, incl. tax)',
  gmv_excl_refund DECIMAL(38,18) COMMENT 'GMV excl. refunds (paid only, incl. tax)',
  order_cnt   BIGINT
) COMMENT 'Store daily sales (parallel metric fields for definition contrast demo)'
PARTITIONED BY (dt STRING COMMENT 'Business date') LIFECYCLE 365;

CREATE TABLE IF NOT EXISTS ads_member_profile (
  member_id BIGINT,
  rfm_tier  STRING COMMENT 'High-Value/Loyal/Promising/At-Risk',
  lifecycle STRING COMMENT 'new/growing/mature/churning',
  city STRING, level STRING,
  last_order_date DATETIME
) COMMENT 'Member profile (source for marketing domain data product)'
PARTITIONED BY (dt STRING COMMENT 'Business date') LIFECYCLE 365;