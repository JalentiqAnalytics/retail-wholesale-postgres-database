-- ตัวอย่าง: บันทึกบิลขายใหม่ 1 ใบ (ลูกค้าหน้าร้าน จ่ายเงินสด 2 รายการ)
-- รันทั้งก้อนใน BEGIN ... COMMIT เพื่อให้ "ครบทั้งใบ หรือไม่เข้าเลย"
SET search_path = shop;
BEGIN;
INSERT INTO sales_orders (sales_order_id, invoice_no, order_date, customer_id, payment_method, due_date, status)
SELECT COALESCE(MAX(sales_order_id),0)+1, 'IV6911-0001', DATE '2026-11-02',
       (SELECT customer_id FROM customers WHERE customer_code='WALKIN'), 'cash', NULL, 'completed'
FROM sales_orders;

INSERT INTO sales_order_lines (sales_order_id, line_no, product_id, quantity, unit_price, discount)
SELECT o.sales_order_id, v.line_no, p.product_id, v.qty, p.retail_price, 0
FROM sales_orders o
JOIN (VALUES (1,'EL-001',3), (2,'CL-001',2)) AS v(line_no, sku, qty) ON true
JOIN products p ON p.sku = v.sku
WHERE o.invoice_no = 'IV6911-0001';

-- ตรวจก่อนยืนยัน
SELECT invoice_no, sku, quantity, unit_price, line_total FROM v_sales_detail WHERE invoice_no='IV6911-0001';
COMMIT;   -- ถ้าผิดให้พิมพ์ ROLLBACK; แทน
