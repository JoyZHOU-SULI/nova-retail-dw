--MaxCompute SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-16 17:17:55
--********************************************************************--
-- dim_store（列名/分区列以 DESC ods_store 实际结果为准）
INSERT OVERWRITE TABLE dim_store
SELECT store_id, store_name, city, region, channel,
       CAST(open_date AS DATETIME)
FROM ods_store
WHERE ds = MAX_PT('ods_store');

-- dim_member
INSERT OVERWRITE TABLE dim_member
SELECT member_id, member_name, phone, city,
       CAST(register_date AS DATETIME), level
FROM ods_member
WHERE ds = MAX_PT('ods_member');

-- dim_item
INSERT OVERWRITE TABLE dim_item
SELECT item_id, item_name, category, unit_price, cost_price
FROM ods_item
WHERE ds = MAX_PT('ods_item');