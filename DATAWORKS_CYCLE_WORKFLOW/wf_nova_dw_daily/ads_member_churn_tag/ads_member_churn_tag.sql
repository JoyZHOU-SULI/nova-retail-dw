--MaxCompute SQL
-- Daily member churn tags for the Members team.
-- Grain: one row per member per business date; business key (dt, member_id).
-- Caliber: only order_status = 'paid' counts as a purchase; tiers 30 / 60 days.

CREATE TABLE IF NOT EXISTS ads_member_churn_tag (
  member_id             BIGINT COMMENT 'Member ID',
  last_order_date       DATETIME COMMENT 'Date of the most recent paid order; NULL when the member has no paid order in retained history',
  days_since_last_order BIGINT COMMENT 'Days from the business date to last_order_date; NULL when there is no paid order',
  churn_tag             STRING COMMENT 'Churn tier: active (<=30d), at_risk (31-60d), churned (>60d), never_purchased (no paid order)'
)
COMMENT 'Daily member churn tags (Members team)'
PARTITIONED BY (dt STRING COMMENT 'Business date yyyyMMdd')
LIFECYCLE 365;

-- Empty-day guard. Without odps.sql.udf.strict.mode an illegal cast returns NULL instead of
-- failing, so the node would overwrite a good partition with zero rows. The sentinel string is
-- uncastable by construction, which aborts the run before the INSERT when the roster is empty.
set odps.sql.udf.strict.mode=true;

SELECT CAST(CASE WHEN roster_cnt > 0 THEN '1'
                 ELSE CONCAT('CHURN_GUARD_ABORT_EMPTY_ROSTER_', CAST(roster_cnt AS STRING))
            END AS BIGINT) AS churn_guard_ok
FROM (
  SELECT COUNT(*) AS roster_cnt
  FROM nova_dw.ods_member
  WHERE ds = '${bizdate}'
) guard;

INSERT OVERWRITE TABLE ads_member_churn_tag PARTITION (dt = '${bizdate}')
SELECT
  m.member_id,
  o.last_order_date,
  CASE WHEN o.last_order_date IS NULL THEN CAST(NULL AS BIGINT)
       ELSE DATEDIFF(TO_DATE('${bizdate}', 'yyyymmdd'), o.last_order_date, 'dd')
  END AS days_since_last_order,
  CASE WHEN o.last_order_date IS NULL THEN 'never_purchased'
       WHEN DATEDIFF(TO_DATE('${bizdate}', 'yyyymmdd'), o.last_order_date, 'dd') <= 30 THEN 'active'
       WHEN DATEDIFF(TO_DATE('${bizdate}', 'yyyymmdd'), o.last_order_date, 'dd') <= 60 THEN 'at_risk'
       ELSE 'churned'
  END AS churn_tag
FROM nova_dw.ods_member m
LEFT JOIN (
  -- No lower bound on dt: members silent longer than any fixed window must stay visible.
  SELECT member_id,
         TO_DATE(MAX(dt), 'yyyymmdd') AS last_order_date
  FROM nova_dw.dwd_order_detail
  WHERE dt <= '${bizdate}'
    AND order_status = 'paid'
  GROUP BY member_id
) o
  ON o.member_id = m.member_id
WHERE m.ds = '${bizdate}';