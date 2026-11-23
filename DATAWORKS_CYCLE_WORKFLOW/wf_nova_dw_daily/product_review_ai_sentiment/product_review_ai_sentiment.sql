--Serverless Spark SQL
--********************************************************************--
--author: dataworks_demo2
--create time: 2026-11-23 20:44:17
--Serverless Spark SQL任务只能运行在独享资源组上
--********************************************************************--
CREATE TABLE product_reviews (
  review_id INT,
  review_text STRING
);

INSERT INTO product_reviews VALUES
  (1, 'The noise-canceling on these headphones is outstanding. I wear them on every flight and they block out the engine hum completely. Best purchase I have made this year.'),
  (2, 'Battery dies after barely three hours and the left earcup started rattling within a week. Customer service kept me on hold for 40 minutes and never resolved it. Total waste of money.'),
  (3, 'The package arrived on Tuesday. It contains a pair of headphones, a charging cable, and a user manual.'),

SELECT
  review_id,
  review_text,
  ai_sentiment(review_text) AS sentiment
FROM product_reviews;