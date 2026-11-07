-- ตัวอย่างคำถามที่เจ้าของร้านถามได้ทันทีหลังข้อมูลอยู่ในฐานข้อมูล
SET search_path = shop;

-- Q1 ยอดขายและกำไรขั้นต้นรายเดือน แยกปลีก/ส่ง (กำไรขั้นต้น = ยอดขาย − ต้นทุนมาตรฐานปัจจุบัน)
SELECT to_char(month,'YYYY-MM') AS เดือน, customer_type AS ประเภท, invoices AS จำนวนบิล,
       sales AS ยอดขาย, gross_profit AS กำไรขั้นต้น, gross_margin_pct AS "กำไรขั้นต้น %"
FROM v_sales_monthly ORDER BY month, customer_type;

-- Q2 สินค้า 10 อันดับแรกตามกำไรขั้นต้น (ไม่นับสินค้า UNMAPPED)
SELECT sku, product_name, SUM(quantity) AS จำนวนขาย, SUM(line_total) AS ยอดขาย, SUM(gross_profit) AS กำไรขั้นต้น
FROM v_sales_detail WHERE sku <> 'UNMAPPED' GROUP BY 1,2 ORDER BY 5 DESC LIMIT 10;

-- Q3 สินค้าที่ถึงจุดสั่งซื้อ พร้อมผู้จำหน่าย
SELECT l.sku, l.product_name, l.stock_qty AS คงเหลือ, l.reorder_point AS จุดสั่งซื้อ, s.supplier_name AS ผู้จำหน่าย
FROM v_low_stock l JOIN products p USING (sku) JOIN suppliers s USING (supplier_id)
WHERE p.is_active ORDER BY s.supplier_name, l.sku;

-- Q4 ลูกหนี้ค้างชำระ แบ่งตามอายุหนี้ ณ 31 ต.ค. 2569
SELECT * FROM ar_aging(DATE '2026-10-31') ORDER BY d61_plus DESC NULLS LAST, balance DESC LIMIT 15;

-- Q5 เงินจมในสต็อก: สินค้าที่ไม่ขายเลย 90 วัน แต่ยังมีของ (มูลค่าที่ราคาทุน)
SELECT s.sku, s.product_name, s.stock_qty AS คงเหลือ, p.cost_price AS ทุน, s.stock_qty * p.cost_price AS มูลค่าทุนที่จมอยู่
FROM v_stock_on_hand s JOIN products p USING (product_id)
WHERE s.stock_qty > 0 AND s.sku <> 'UNMAPPED' AND NOT EXISTS (
  SELECT 1 FROM sales_order_lines l JOIN sales_orders o USING (sales_order_id)
  WHERE l.product_id = s.product_id AND o.status='completed' AND o.order_date > DATE '2026-10-31' - 90)
ORDER BY 5 DESC;

-- Q6 ลูกค้า 10 อันดับตามยอดซื้อ
SELECT customer_name AS ลูกค้า, customer_type AS ประเภท, COUNT(DISTINCT invoice_no) AS บิล, SUM(line_total) AS ยอดซื้อ
FROM v_sales_detail WHERE customer_code <> 'WALKIN' GROUP BY 1,2 ORDER BY 4 DESC LIMIT 10;

-- Q7 ราคาขายต่ำกว่าทุน (ตรวจว่าพิมพ์ราคาผิดหรือไม่)
SELECT invoice_no, order_date, customer_name, product_name, unit_price AS ราคาขาย, cost_price AS ทุน, quantity
FROM v_sales_detail WHERE unit_price < cost_price AND sku <> 'UNMAPPED' ORDER BY order_date;

-- Q8 ยอดขายตามวันในสัปดาห์ (ไว้จัดคนหน้าร้าน/จัดของ)
SELECT to_char(order_date,'ID') AS วันที่_1จันทร์_7อาทิตย์, COUNT(DISTINCT invoice_no) AS บิล, SUM(line_total) AS ยอดขาย
FROM v_sales_detail GROUP BY 1 ORDER BY 1;

-- Q9 สต็อกในระบบ vs ยอดนับจริง พร้อมมูลค่าส่วนต่าง (ที่ราคาทุน)
SELECT p.sku, p.product_name, s.stock_qty AS ระบบ, c.counted_qty AS นับได้, c.counted_qty - s.stock_qty AS ส่วนต่าง,
       (c.counted_qty - s.stock_qty) * p.cost_price AS มูลค่าส่วนต่าง
FROM stock_counts c JOIN v_stock_on_hand s USING (product_id) JOIN products p USING (product_id)
WHERE c.counted_qty <> s.stock_qty ORDER BY ABS((c.counted_qty - s.stock_qty) * p.cost_price) DESC LIMIT 15;

-- Q10 ผู้จำหน่าย: ยอดสั่งซื้อรวม และเวลาส่งของเฉลี่ย (เฉพาะวันที่รับของจริง ไม่ใช่ค่าประมาณ)
SELECT s.supplier_name AS ผู้จำหน่าย, COUNT(DISTINCT o.purchase_order_id) AS ใบสั่งซื้อ, SUM(l.line_total) AS ยอดสั่งซื้อ,
       ROUND(AVG(o.received_date - o.order_date) FILTER (WHERE NOT o.received_date_is_estimated), 1) AS ส่งของเฉลี่ย_วัน
FROM purchase_orders o JOIN suppliers s USING (supplier_id) JOIN purchase_order_lines l USING (purchase_order_id)
GROUP BY 1 ORDER BY 3 DESC LIMIT 10;
