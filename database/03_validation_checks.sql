-- ตรวจคุณภาพข้อมูลหลังนำเข้า: ทุกข้อควรได้ 0 แถว ยกเว้นข้อที่ระบุว่า "รายการที่ต้องให้ร้านยืนยัน"
SET search_path = shop;
CREATE OR REPLACE VIEW v_data_checks AS
SELECT check_name, severity, rows_found, meaning FROM (
 SELECT 'C01 บิลที่ไม่มีรายการสินค้า' AS check_name, 'ต้องเป็น 0' AS severity,
        (SELECT count(*) FROM sales_orders o WHERE NOT EXISTS (SELECT 1 FROM sales_order_lines l WHERE l.sales_order_id=o.sales_order_id)) AS rows_found,
        'บิลที่มีหัวบิลแต่ไม่มีสินค้า' AS meaning
 UNION ALL SELECT 'C02 ใบสั่งซื้อที่ไม่มีรายการ', 'ต้องเป็น 0',
        (SELECT count(*) FROM purchase_orders o WHERE NOT EXISTS (SELECT 1 FROM purchase_order_lines l WHERE l.purchase_order_id=o.purchase_order_id)), 'PO ว่าง'
 UNION ALL SELECT 'C03 สินค้าที่สต็อกติดลบ', 'ต้องเป็น 0',
        (SELECT count(*) FROM v_stock_on_hand WHERE stock_qty < 0 AND sku <> 'UNMAPPED'), 'ขายมากกว่าที่รับเข้า/ยกมา'
 UNION ALL SELECT 'C04 บิลเครดิตที่รับชำระเกินยอดบิล', 'ต้องเป็น 0',
        (SELECT count(*) FROM v_invoice_balance WHERE balance < -0.005), 'รับเงินเกินยอดบิล'
 UNION ALL SELECT 'C05 การรับชำระก่อนวันที่ขาย', 'ต้องเป็น 0',
        (SELECT count(*) FROM customer_payments p JOIN sales_orders o USING (sales_order_id) WHERE p.paid_date < o.order_date), 'วันที่รับเงินผิด'
 UNION ALL SELECT 'C06 บิลเครดิตของลูกค้าที่ไม่มีเครดิต', 'ต้องเป็น 0',
        (SELECT count(*) FROM sales_orders o JOIN customers c USING (customer_id) WHERE o.payment_method='credit' AND c.credit_days=0), 'ขายเชื่อให้คนที่ไม่มีเครดิต'
 UNION ALL SELECT 'C07 ขายเกินวงเงินเครดิต (ยอดค้างปัจจุบัน)', 'รายการที่ต้องให้ร้านยืนยัน',
        (SELECT count(*) FROM (SELECT customer_id, SUM(balance) b FROM v_invoice_balance WHERE payment_method='credit' GROUP BY 1) x
                              JOIN customers c USING (customer_id) WHERE x.b > c.credit_limit AND c.credit_limit > 0), 'ยอดค้างชำระมากกว่าวงเงิน'
 UNION ALL SELECT 'C08 ราคาขายต่ำกว่าทุน', 'รายการที่ต้องให้ร้านยืนยัน',
        (SELECT count(*) FROM sales_order_lines l JOIN products p USING (product_id) JOIN sales_orders o USING (sales_order_id)
          WHERE l.unit_price < p.cost_price AND p.sku <> 'UNMAPPED' AND o.status='completed'), 'อาจพิมพ์ราคาผิด'
 UNION ALL SELECT 'C09 รายการสินค้าที่ระบุไม่ได้ (UNMAPPED)', 'รายการที่ต้องให้ร้านยืนยัน',
        (SELECT count(*) FROM sales_order_lines l JOIN products p USING (product_id) WHERE p.sku='UNMAPPED'), 'ต้องให้ร้านบอกว่าเป็นสินค้าอะไร'
 UNION ALL SELECT 'C10 ใบสั่งซื้อที่วันที่รับของเป็นค่าประมาณ', 'รายการที่ต้องให้ร้านยืนยัน',
        (SELECT count(*) FROM purchase_orders WHERE received_date_is_estimated), 'ไม่มีวันที่รับของในไฟล์เดิม'
 UNION ALL SELECT 'C11 สต็อกในระบบไม่ตรงกับยอดนับจริง', 'รายการที่ต้องให้ร้านยืนยัน',
        (SELECT count(*) FROM stock_counts c JOIN v_stock_on_hand s USING (product_id) WHERE c.counted_qty <> s.stock_qty), 'ของหาย/นับผิด/บันทึกขายผิด'
 UNION ALL SELECT 'C12 สินค้าไม่เคลื่อนไหว 90 วัน แต่ยังมีสต็อก', 'ข้อมูลเพื่อตัดสินใจ',
        (SELECT count(*) FROM v_stock_on_hand s WHERE s.stock_qty > 0 AND s.sku <> 'UNMAPPED' AND NOT EXISTS (
            SELECT 1 FROM sales_order_lines l JOIN sales_orders o USING (sales_order_id) WHERE l.product_id=s.product_id AND o.status='completed' AND o.order_date > DATE '2026-10-31' - 90)), 'เงินจมในสต็อก'
) t ORDER BY check_name;
