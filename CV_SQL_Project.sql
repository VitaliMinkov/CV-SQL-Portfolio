-- 1. Calculate monthly metrics by region:
-- number of orders,
-- number of customers,
-- revenue,
-- profit and profit margin.
-- Additionally, calculate revenue change MoM (month-over-month)
-- and YoY (year-over-year, compared to the same month las-- 1. Calculate monthly metrics by region:
-- number of orders,
-- number of customers,
-- revenue,
-- profit and profit margin.
-- Additionally, calculate revenue change MoM (month-over-month)
-- and YoY (year-over-year, compared to the same month last year).
-- Protect against division by zero.

with monthly_CTE as
(select to_char((date_trunc('month', order_date)::date),'Month YYYY') as month_label,
       (date_trunc('month', order_date)::date) as month,
       region,
       count(order_id) as orders_cnt,
       count(customer_id) as customer_cnt,
       round(sum(sales),2) as sales,
       round(SUM(profit),2) as profit
       from orders
group by month, region
order by month)
select month,
       month_label,
       region,
       orders_cnt,
       customer_cnt,
       sales,
       profit,
       round(profit/(Nullif(sales,0)),2) as margin,
       sales-lag(sales) over (partition by region order by month) as sales_mom,
       sales-lag(sales,12) over (partition by region order by month) as sales_yoy
from monthly_CTE
order by month, region;

-- 2) Daily Active Users + New Users
-- For the last 90 days, calculate daily metrics:
-- DAU = number of unique customers who placed an order on that day
-- New customers = number of customers whose first-ever order occurred on that day

WITH period_cte as (
    SELECT
        (CURRENT_DATE - INTERVAL '90 days') as start_date,
        CURRENT_DATE AS end_date
),
     order_days_cte as (
         SELECT DISTINCT
             order_date as day
FROM orders
    JOIN period_cte p
on order_date BETWEEN p.start_date AND p.end_date
WHERE order_date IS NOT NULL
    ),
    dau_cte as (
SELECT
    order_date as day,
    COUNT(DISTINCT customer_id) as dau
FROM orders
    JOIN period_cte p
ON order_date BETWEEN p.start_date AND p.end_date
WHERE order_date IS NOT NULL
GROUP BY 1
    ),
    first_order_cte as (
SELECT
    customer_id,
    MIN(order_date) as first_day
FROM orders
WHERE order_date IS NOT NULL
GROUP BY customer_id
    ),
    new_customers as (
SELECT
    first_day as day,
    count(*) as new_customers
FROM first_order_cte
    JOIN period_cte p
ON first_day BETWEEN p.start_date AND p.end_date
GROUP BY first_day
    )
SELECT
    od.day,
    COALESCE(d.dau, 0) as dau,
    COALESCE(n.new_customers, 0) as new_customers
FROM order_days_cte od
         LEFT JOIN dau_cte d
                   ON d.day = od.day
         LEFT JOIN new_customers n
                   ON n.day = od.day
ORDER BY od.day;

-- 3) Top-3 products by profit margin in each region

with margin_cte as
         (select region,
                 product_id,
                 product_name,
                 sum(profit) as profit,
                 sum(sales) as sales,
                 round((sum(profit)/nullif(SUM(sales),0)),5) as margin
          from orders
          group by region, product_id,product_name)
select region,
       product_id,
       product_name,
       margin,
       profit,
       sales from
    (select region,
            product_id,
            product_name,
            profit,
            sales,
            margin,
            dense_rank() over (partition by region order by margin DESC, profit desc, sales desc) as rnk
     from margin_cte) as sub
where rnk<=3;

-- 4) Measure the impact of discounts on profitability and return rate
-- Bucket orders by discount level (0%, 0–10%, 10–30%, 30%+)
-- and for each category calculate:
-- average sales/profit,
-- profit margin, and return rate.

with bucket_returns_cte as
         (select o.*,
                 case
                     when discount is null then 'unknown'
                     when discount = 0 then '0%'
                     when discount > 0 and discount <= 0.1 then '0-10%'
                     when discount > 0.1 and discount <= 0.3 then '10-30%'
                     else '30+%'
                     end as bucket,
                 (r.order_id is not null) as is_returned
          from orders o
                   left join returns r
                             on o.order_id=r.order_id)
select category,
       bucket,
       round(avg(sales),3) as avg_sales,
       round(avg(profit),3) as avg_profit,
       round((sum(profit)/nullif(sum(sales),0)),3) as margin,
       round(avg(case when is_returned then 1 else 0 end),3) as return_rate
from bucket_returns_cte
group by category, bucket

-- 5) Shipping delays and average delivery time by ship mode
-- Calculate the average delivery time by region and ship_mode.
-- Include only valid dates and return only groups with at least 50 rows.

SELECT
    region,
    ship_mode,
    COUNT(*) asrows_cnt,
    ROUND(AVG(ship_days), 2) as avg_ship_days
FROM (
         SELECT
             region,
             ship_mode,
             ship_date - order_date as ship_days
         FROM orders
         WHERE ship_date IS NOT NULL
           AND order_date IS NOT NULL
           AND ship_date >= order_date
     ) as ship
GROUP BY region, ship_mode
HAVING COUNT(*) >= 50
ORDER BY avg_ship_days;

-- 6) Return rate by manager and category
-- Show performance metrics by regional manager:
-- sales, profit, return_rate, and the share of sales from returned orders.
-- Exclude categories with fewer than 100 orders.

with managers_cte as
         (select o.region,
                 p.manager,
                 o.category,
                 o.order_id,
                 sum(sales) as total_sales,
                 sum(profit) as total_profit
          from orders o
                   join people p on p.region=o.region
          group by 1,2,3,4),
     return_cte as
         (select m.*,
                 case when r.order_id is not null then 1 else 0 end as returned
          from managers_cte m
                   LEFT JOIN returns r ON r.order_id=m.order_id)
select region,
       manager,
       category,
       count(*) as orders_cnt,
       round(sum(total_sales),2) as sales,
       round(sum(total_profit),2) as profit,
       round(avg(returned),2) as return_rate,
       round(sum(case when returned=1 then total_sales else 0 end)/nullif(sum(total_sales),0),2) as return_sales_share
from return_cte
group by region, manager, category
having count(*)>100
order by return_rate DESC, profit ASC;

select region,count(*)
from people
group by region
having count(*)>1;

-- 7) RFM customer segmentation
-- For each customer, calculate:
-- days since the last order,
-- number of orders,
-- total sales.
-- Assign each customer to a segment (loyal/active/stable/at_risk)
-- based on RFM scores from 1 to 5.

with customer_kpi_cte as
         (select customer_name,
                 max(order_date) as last_order_date,
                 (current_date-max(order_date)) as recency_days,
                 count(order_id) as frequency,
                 sum(sales) as monetary
          from orders
          group by customer_name),
     scores_cte as
         (select *,
                 ntile(5) over (order by recency_days DESC) as r_score,
              ntile(5) over (order by frequency ASC) as f_score,
              ntile(5) over (order by monetary Asc) as m_score
          from customer_kpi_cte)
select customer_name,
       recency_days,
       frequency,
       monetary,
       r_score,
       f_score,
       m_score,
       case
           WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'loyal'
           WHEN r_score >= 3 AND f_score >= 3 and m_score >= 3  THEN 'active'
           WHEN r_score >= 2 AND f_score >= 2 and m_score >= 2 THEN 'stable'
           ELSE 'at risk'
           END as rfm_segment
from scores_Cte
order by r_score, f_score, m_score ASC


-- 8) Pareto 80/20 analysis by customers
-- Validate the Pareto principle:
-- rank customers by total sales,
-- calculate cumulative revenue share,
-- and return customers who together account for the first 80% of total revenue.


    with sales_cte as
(select customer_name,
       total_sales,
       sum(total_sales) over (order by total_sales desc) as cum_sales
from (
        select customer_name,
                 sum(sales) as total_sales
        from orders
        group by customer_name) sub1),
total_sales_cte as
(select sum(total_sales) as sales_all from sales_cte)
select customer_name,
       total_sales,
       cum_sales,
       cum_sales/(select sales_all from total_sales_cte) as cum_share
from sales_cte sc
group by 1,2,3
having cum_sales/(select sales_all from total_sales_cte) <=0.80
order by total_sales desc;

with sales_cte as
         (select customer_name,
                 total_sales,
                 sum(total_sales) over (order by total_sales desc) as cum_sales,
              sum(total_sales) over () as sales_all
          from (
                   select customer_name,
                          sum(sales) as total_sales
                   from orders
                   group by customer_name) sub1)
select customer_name,
       total_sales,
       cum_sales,
       round(cum_sales/sales_all,2) as cum_share
from sales_cte sc
where cum_sales/sales_all <=0.80
order by total_sales desc;

-- 9) Loss-making orders vs customer's average margin
-- List loss-making orders (profit < 0)
-- and show the customer's average margin across all of their orders.

SELECT
    o.order_id,
    o.customer_name,
    o.sales,
    o.profit,
    (
        SELECT
            SUM(o2.profit) / NULLIF(SUM(o2.sales), 0)
        FROM orders o2
        WHERE o2.customer_name = o.customer_name
    ) as customer_avg_margin
FROM orders o
WHERE o.profit < 0
ORDER BY o.profit ASC;

-- 10) Customers who purchased both Technology and Office Supplies
-- Find customers who bought products from both categories (Technology and Office Supplies) in the last 12 months.
-- For these customers, show the date of their first order within this period.

WITH last_year_CTE as (
    SELECT customer_id,customer_name, category, order_id, order_date
    FROM orders
    WHERE order_date >= (CURRENT_DATE - INTERVAL '365 days')
),
     buyers_a_cte as (
         SELECT DISTINCT customer_id, customer_name
         FROM last_year_cte
         WHERE category = 'Technology'
     ),
     buyers_b_cte as (
         SELECT DISTINCT customer_id
         FROM last_year_cte
         WHERE category = 'Office Supplies'
     )
SELECT
    a.customer_name,
    MIN(f.order_date) as first_seen_date
FROM buyers_a_cte a
         JOIN last_year_cte f on f.customer_id = a.customer_id
WHERE EXISTS
          (SELECT 1 FROM buyers_b_cte b
           WHERE b.customer_id = a.customer_id)
GROUP BY a.customer_name
ORDER BY first_seen_date;
t year).
-- Protect against division by zero.


with monthly_CTE as
(select to_char((date_trunc('month', order_date)::date),'Month YYYY') as month_label,
       (date_trunc('month', order_date)::date) as month,
       region,
       count(order_id) as orders_cnt,
       count(customer_id) as customer_cnt,
       round(sum(sales),2) as sales,
       round(SUM(profit),2) as profit
       from orders
group by month, region
order by month)
select month,
       month_label,
       region,
       orders_cnt,
       customer_cnt,
       sales,
       profit,
       round(profit/(Nullif(sales,0)),2) as margin,
       sales-lag(sales) over (partition by region order by month) as sales_mom,
       sales-lag(sales,12) over (partition by region order by month) as sales_yoy
from monthly_CTE
order by month, region;






