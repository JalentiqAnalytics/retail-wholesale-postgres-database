-- =====================================================================
-- Retail/Wholesale Shop Database  (PostgreSQL 16)
-- ร้านสมมติ: ค้าปลีก-ค้าส่งของใช้ในบ้านและวัสดุก่อสร้าง
-- ข้อมูลทั้งหมดเป็นข้อมูลสมมติ (synthetic) เพื่อใช้เป็นตัวอย่างผลงาน
-- =====================================================================
DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path = shop;

-- ---------- หมวดสินค้า ----------
CREATE TABLE product_categories (
  category_id    smallint PRIMARY KEY,
  category_name  text NOT NULL UNIQUE
);
COMMENT ON TABLE product_categories IS 'หมวดสินค้า';

-- ---------- ผู้จำหน่าย ----------
CREATE TABLE suppliers (
  supplier_id    smallint PRIMARY KEY,
  supplier_code  text NOT NULL UNIQUE,
  supplier_name  text NOT NULL UNIQUE,
  phone          text,
  credit_days    smallint NOT NULL DEFAULT 0 CHECK (credit_days BETWEEN 0 AND 180)
);
COMMENT ON TABLE suppliers IS 'ผู้จำหน่าย/ซัพพลายเออร์ที่ร้านสั่งซื้อสินค้า';

-- ---------- สินค้า ----------
CREATE TABLE products (
  product_id       integer PRIMARY KEY,
  sku              text NOT NULL UNIQUE,
  product_name     text NOT NULL UNIQUE,
  category_id      smallint NOT NULL REFERENCES product_categories,
  supplier_id      smallint NOT NULL REFERENCES suppliers,
  unit             text NOT NULL,
  cost_price       numeric(12,2) NOT NULL CHECK (cost_price >= 0),
  retail_price     numeric(12,2) NOT NULL CHECK (retail_price >= 0),
  wholesale_price  numeric(12,2) NOT NULL CHECK (wholesale_price >= 0),
  reorder_point    integer NOT NULL DEFAULT 0 CHECK (reorder_point >= 0),
  is_active        boolean NOT NULL DEFAULT true,
  CONSTRAINT price_order CHECK (retail_price >= wholesale_price AND wholesale_price >= cost_price)
);
CREATE INDEX ix_products_category ON products(category_id);
CREATE INDEX ix_products_supplier ON products(supplier_id);
COMMENT ON COLUMN products.cost_price IS 'ต้นทุนมาตรฐานปัจจุบัน (ยังไม่เก็บประวัติราคา)';
COMMENT ON COLUMN products.reorder_point IS 'เมื่อสต็อกเหลือเท่านี้หรือน้อยกว่า ควรสั่งซื้อ';

-- ---------- ลูกค้า ----------
CREATE TABLE customers (
  customer_id    integer PRIMARY KEY,
  customer_code  text NOT NULL UNIQUE,
  customer_name  text NOT NULL UNIQUE,
  customer_type  text NOT NULL CHECK (customer_type IN ('retail','wholesale')),
  phone          text,
  credit_days    smallint NOT NULL DEFAULT 0 CHECK (credit_days BETWEEN 0 AND 180),
  credit_limit   numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  CONSTRAINT credit_only_wholesale CHECK (customer_type = 'wholesale' OR credit_days = 0)
);
COMMENT ON TABLE customers IS 'ลูกค้า (รหัส WALKIN = ลูกค้าหน้าร้านที่ไม่ระบุชื่อ)';

-- ---------- ใบขาย ----------
CREATE TABLE sales_orders (
  sales_order_id  integer PRIMARY KEY,
  invoice_no      text NOT NULL UNIQUE CHECK (invoice_no ~ '^IV[0-9]{4}-[0-9]{4}$'),
  order_date      date NOT NULL,
  customer_id     integer NOT NULL REFERENCES customers,
  payment_method  text NOT NULL CHECK (payment_method IN ('cash','transfer','credit')),
  due_date        date,
  status          text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed','cancelled')),
  CONSTRAINT due_date_rule CHECK (
    (payment_method = 'credit' AND due_date IS NOT NULL AND due_date >= order_date)
    OR (payment_method <> 'credit' AND due_date IS NULL))
);
CREATE INDEX ix_sales_orders_date ON sales_orders(order_date);
CREATE INDEX ix_sales_orders_customer ON sales_orders(customer_id, order_date);

CREATE TABLE sales_order_lines (
  sales_order_id  integer NOT NULL REFERENCES sales_orders ON DELETE CASCADE,
  line_no         smallint NOT NULL CHECK (line_no > 0),
  product_id      integer NOT NULL REFERENCES products,
  quantity        integer NOT NULL CHECK (quantity > 0),
  unit_price      numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  discount        numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  line_total      numeric(14,2) GENERATED ALWAYS AS (quantity * unit_price - discount) STORED,
  PRIMARY KEY (sales_order_id, line_no),
  CONSTRAINT one_product_per_invoice UNIQUE (sales_order_id, product_id),
  CONSTRAINT discount_not_over_gross CHECK (discount <= quantity * unit_price)
);
CREATE INDEX ix_sol_product ON sales_order_lines(product_id);

-- ---------- การรับชำระหนี้ (เฉพาะบิลเครดิต) ----------
CREATE TABLE customer_payments (
  payment_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sales_order_id  integer NOT NULL REFERENCES sales_orders,
  paid_date       date NOT NULL,
  amount          numeric(14,2) NOT NULL CHECK (amount > 0),
  method          text NOT NULL CHECK (method IN ('cash','transfer'))
);
CREATE INDEX ix_pay_order ON customer_payments(sales_order_id);
COMMENT ON TABLE customer_payments IS 'บันทึกเฉพาะบิลเครดิต; บิลเงินสด/โอนถือว่ารับเงินครบในวันขาย';

-- ---------- ใบสั่งซื้อ ----------
CREATE TABLE purchase_orders (
  purchase_order_id  integer PRIMARY KEY,
  po_no              text NOT NULL UNIQUE CHECK (po_no ~ '^PO[0-9]{4}-[0-9]{3}$'),
  order_date         date NOT NULL,
  supplier_id        smallint NOT NULL REFERENCES suppliers,
  received_date      date,
  received_date_is_estimated boolean NOT NULL DEFAULT false,
  status             text NOT NULL CHECK (status IN ('ordered','received','cancelled')),
  CONSTRAINT receipt_rule CHECK (
    (status = 'received' AND received_date IS NOT NULL AND received_date >= order_date)
    OR (status <> 'received' AND received_date IS NULL))
);
CREATE INDEX ix_po_supplier ON purchase_orders(supplier_id, order_date);

CREATE TABLE purchase_order_lines (
  purchase_order_id  integer NOT NULL REFERENCES purchase_orders ON DELETE CASCADE,
  line_no            smallint NOT NULL CHECK (line_no > 0),
  product_id         integer NOT NULL REFERENCES products,
  quantity           integer NOT NULL CHECK (quantity > 0),
  unit_cost          numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
  line_total         numeric(14,2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,
  PRIMARY KEY (purchase_order_id, line_no),
  CONSTRAINT one_product_per_po UNIQUE (purchase_order_id, product_id)
);
CREATE INDEX ix_pol_product ON purchase_order_lines(product_id);

-- ---------- ปรับสต็อก (ยอดยกมา ของเสีย ของหาย แก้ตามการนับ) ----------
CREATE TABLE stock_adjustments (
  adjustment_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  adjust_date    date NOT NULL,
  product_id     integer NOT NULL REFERENCES products,
  quantity_change integer NOT NULL CHECK (quantity_change <> 0),
  reason         text NOT NULL CHECK (reason IN ('opening','damaged','lost','count_correction'))
);
CREATE INDEX ix_adj_product ON stock_adjustments(product_id, adjust_date);

-- ---------- ยอดนับสต็อกจริง ----------
CREATE TABLE stock_counts (
  count_date   date NOT NULL,
  product_id   integer NOT NULL REFERENCES products,
  counted_qty  integer NOT NULL CHECK (counted_qty >= 0),
  PRIMARY KEY (count_date, product_id)
);

-- ---------- บันทึกรายการที่ต้องให้เจ้าของร้านยืนยัน ----------
CREATE TABLE import_exceptions (
  exception_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_file   text NOT NULL,
  source_ref    text,
  issue_type    text NOT NULL,
  detail        text,
  action_taken  text NOT NULL
);
COMMENT ON TABLE import_exceptions IS 'ข้อมูลที่ระบบแก้เองไม่ได้/ไม่ควรเดา ต้องให้ร้านยืนยัน';
