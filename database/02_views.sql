SET search_path = shop;

-- สต็อกคงเหลือ = ยอดปรับ + รับของ(สถานะรับแล้ว) - ขาย(ไม่รวมบิลยกเลิก)
CREATE OR REPLACE VIEW v_stock_on_hand AS
SELECT p.product_id, p.sku, p.product_name, p.unit, p.reorder_point,
       COALESCE(a.q,0) AS adjusted_qty,
       COALESCE(r.q,0) AS received_qty,
       COALESCE(s.q,0) AS sold_qty,
       COALESCE(a.q,0) + COALESCE(r.q,0) - COALESCE(s.q,0) AS stock_qty
FROM products p
LEFT JOIN (SELECT product_id, SUM(quantity_change) q FROM stock_adjustments GROUP BY 1) a USING (product_id)
LEFT JOIN (SELECT l.product_id, SUM(l.quantity) q FROM purchase_order_lines l
           JOIN purchase_orders o USING (purchase_order_id) WHERE o.status='received' GROUP BY 1) r USING (product_id)
LEFT JOIN (SELECT l.product_id, SUM(l.quantity) q FROM sales_order_lines l
           JOIN sales_orders o USING (sales_order_id) WHERE o.status='completed' GROUP BY 1) s USING (product_id);

CREATE OR REPLACE VIEW v_low_stock AS
SELECT sku, product_name, stock_qty, reorder_point
FROM v_stock_on_hand WHERE stock_qty <= reorder_point ORDER BY stock_qty - reorder_point;

-- ยอดขายรายบรรทัด (แบนราบ ใช้ต่อ Power BI / Excel ได้ตรง)
CREATE OR REPLACE VIEW v_sales_detail AS
SELECT o.order_date, o.invoice_no, c.customer_code, c.customer_name, c.customer_type, o.payment_method,
       p.sku, p.product_name, pc.category_name, l.quantity, l.unit_price, l.discount, l.line_total,
       p.cost_price, l.quantity * p.cost_price AS cost_total, l.line_total - l.quantity * p.cost_price AS gross_profit
FROM sales_order_lines l
JOIN sales_orders o USING (sales_order_id)
JOIN customers c USING (customer_id)
JOIN products p USING (product_id)
JOIN product_categories pc USING (category_id)
WHERE o.status = 'completed';

CREATE OR REPLACE VIEW v_sales_monthly AS
SELECT date_trunc('month', order_date)::date AS month, customer_type,
       COUNT(DISTINCT invoice_no) AS invoices, SUM(line_total) AS sales, SUM(gross_profit) AS gross_profit,
       ROUND(100*SUM(gross_profit)/NULLIF(SUM(line_total),0),1) AS gross_margin_pct
FROM v_sales_detail GROUP BY 1,2 ORDER BY 1,2;

CREATE OR REPLACE VIEW v_invoice_balance AS
SELECT o.sales_order_id, o.invoice_no, o.order_date, o.due_date, o.customer_id, o.payment_method, o.status,
       t.total, CASE WHEN o.payment_method='credit' THEN COALESCE(p.paid,0) ELSE t.total END AS paid,
       t.total - CASE WHEN o.payment_method='credit' THEN COALESCE(p.paid,0) ELSE t.total END AS balance
FROM sales_orders o
JOIN (SELECT sales_order_id, SUM(line_total) total FROM sales_order_lines GROUP BY 1) t USING (sales_order_id)
LEFT JOIN (SELECT sales_order_id, SUM(amount) paid FROM customer_payments GROUP BY 1) p USING (sales_order_id)
WHERE o.status='completed';

-- ลูกหนี้ค้างชำระ ณ วันที่ที่ระบุ
CREATE OR REPLACE FUNCTION ar_aging(as_of date DEFAULT CURRENT_DATE)
RETURNS TABLE (customer_name text, invoices bigint, balance numeric, not_due numeric, d1_30 numeric, d31_60 numeric, d61_plus numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.customer_name, COUNT(*), SUM(b.balance),
    SUM(b.balance) FILTER (WHERE b.due_date >= as_of),
    SUM(b.balance) FILTER (WHERE as_of - b.due_date BETWEEN 1 AND 30),
    SUM(b.balance) FILTER (WHERE as_of - b.due_date BETWEEN 31 AND 60),
    SUM(b.balance) FILTER (WHERE as_of - b.due_date > 60)
  FROM v_invoice_balance b JOIN customers c USING (customer_id)
  WHERE b.balance > 0.005 AND b.payment_method='credit' AND b.order_date <= as_of
  GROUP BY c.customer_name ORDER BY 3 DESC;
$$;
