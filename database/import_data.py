"""อ่านไฟล์ Excel เดิมของร้าน -> ทำความสะอาด -> นำเข้า PostgreSQL (schema shop)
ใช้เฉพาะไฟล์ใน before/ เท่านั้น (ไม่ดูข้อมูลเฉลย)"""
import sys, re, json, datetime as dt, difflib, statistics
from collections import defaultdict, Counter
import openpyxl, psycopg2
from psycopg2.extras import execute_values

SRC, DSN = sys.argv[1], sys.argv[2]
LOG = Counter(); EXC = []
def exc(src, ref, typ, detail, action): EXC.append((src, ref, typ, detail, action))

def parse_date(v):
    if v is None or v == '': return None
    if isinstance(v, dt.datetime): return v.date()
    if isinstance(v, dt.date): return v
    m = re.match(r'^\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\s*$', str(v))
    if not m: raise ValueError(f'วันที่อ่านไม่ได้: {v!r}')
    d, mo, y = int(m[1]), int(m[2]), int(m[3])
    if y < 100: y += 2500
    if y > 2400: y -= 543
    return dt.date(y, mo, d)
def parse_num(v, default=None):
    if v is None or v == '': return default
    if isinstance(v, (int, float)): return float(v)
    s = re.sub(r'[,\s฿]', '', str(v))
    return float(s)
def parse_qty(v):
    if isinstance(v, (int, float)): return int(v)
    m = re.match(r'^\s*(\d+)', str(v)); return int(m[1])
def squash(s): return re.sub(r'\s+', '', str(s)).lower()
PRE_C = ['คุณ','ร้าน','หจก.','หจก','บจก.','บริษัท','ห้างหุ้นส่วนจำกัด']
def cust_key(n):
    n = squash(n); ch = True
    while ch:
        ch = False
        for p in PRE_C:
            if n.startswith(p): n = n[len(p):]; ch = True
    return n
def sup_key(n):
    n = squash(n)
    for p in ['บริษัท','ห้างหุ้นส่วนจำกัด','ร้าน']:
        if n.startswith(p): n = n[len(p):]
    return n.replace('จำกัด','')
def find_header(ws, must):
    for r in range(1, 12):
        vals = [ws.cell(r, c).value for c in range(1, ws.max_column+1)]
        if any(v in must for v in vals): return r, vals
    raise ValueError('ไม่พบแถวหัวตาราง')
def colmap(vals, syn):
    out = {}
    for k, names in syn.items():
        for i, v in enumerate(vals):
            if v in names: out[k] = i
    miss = [k for k in syn if k not in out]
    assert not miss, f'หัวตารางหาย: {miss}'
    return out

# ---------------- 3 products & suppliers ----------------
wb = openpyxl.load_workbook(f'{SRC}/3_รายการสินค้าและผู้จำหน่าย.xlsx', data_only=True)
suppliers = []; skey = {}
for i, row in enumerate(wb['ผู้จำหน่าย'].iter_rows(min_row=2, values_only=True), 1):
    if not row[0]: continue
    suppliers.append((i, f'SUP-{i:02d}', row[0].strip(), row[1], int(parse_num(row[2], 0)))); skey[sup_key(row[0])] = i
cats = {}; products = []; seen = {}
for n, row in enumerate(wb['รายการสินค้า'].iter_rows(min_row=2, values_only=True), 2):
    if not row[0]: continue
    sku = str(row[0]).strip().upper()
    rec = dict(sku=sku, name=re.sub(r'\s+', ' ', str(row[1]).strip()), cat=str(row[2]).strip(), unit=str(row[3]).strip(),
               cost=parse_num(row[4]), ret=parse_num(row[5]), wh=parse_num(row[6]), rop=int(parse_num(row[7], 0)),
               sup=skey[sup_key(row[8])], open=int(parse_num(row[9], 0)))
    if str(row[0]).strip() != sku: LOG['sku_case_fixed'] += 1
    if row[1] != str(row[1]).strip(): LOG['name_whitespace_trimmed'] += 1
    if sku in seen:
        same = {k: seen[sku][k] for k in rec} == rec
        exc('3_รายการสินค้า', f'แถว {n} รหัส {sku}', 'รหัสสินค้าซ้ำ', 'แถวซ้ำกับแถวก่อนหน้า' + (' (ข้อมูลเหมือนกัน)' if same else ' (ข้อมูลต่างกัน!)'), 'ตัดแถวซ้ำ เก็บแถวแรก')
        LOG['product_duplicate_rows_dropped'] += 1; continue
    seen[sku] = rec; products.append(rec)
    if rec['cat'] not in cats: cats[rec['cat']] = len(cats) + 1
products.sort(key=lambda p: p['sku'])
for i, p in enumerate(products, 1): p['id'] = i
by_sku = {p['sku']: p for p in products}
# placeholder สำหรับรายการที่ระบุสินค้าไม่ได้ (เก็บยอดเงินให้ครบ แต่ติดป้ายให้ตรวจสอบ)
cats['รอตรวจสอบ'] = len(cats) + 1
PH = dict(id=len(products) + 1, sku='UNMAPPED', name='[รอตรวจสอบ] สินค้าที่ระบุไม่ได้', cat='รอตรวจสอบ', unit='หน่วย', cost=0, ret=0, wh=0, rop=0, sup=1, open=0)
products.append(PH); by_sku['UNMAPPED'] = PH
pkey = {squash(p['name']): p for p in products if p is not PH}
assert len(pkey) == len(products) - 1, 'ชื่อสินค้าซ้ำหลังตัดช่องว่าง'
pcache = {}
def resolve_product(name):
    k = squash(name)
    if k in pcache: return pcache[k]
    res = None; how = None
    if k in pkey: res, how = pkey[k], 'exact'
    else:
        cand = difflib.get_close_matches(k, list(pkey), n=2, cutoff=0.88)
        dig = lambda s: re.findall(r'\d+', s)
        cand = [c for c in cand if dig(c) == dig(k)]
        if len(cand) >= 1:
            r1 = difflib.SequenceMatcher(None, k, cand[0]).ratio()
            r2 = difflib.SequenceMatcher(None, k, cand[1]).ratio() if len(cand) > 1 else 0
            if r1 - r2 >= 0.03: res, how = pkey[cand[0]], 'fuzzy'
    pcache[k] = (res, how); return pcache[k]

# ---------------- 4 customers ----------------
wb4 = openpyxl.load_workbook(f'{SRC}/4_รายชื่อลูกค้า.xlsx', data_only=True)
customers = []; ckey = {}
for i, row in enumerate(wb4.active.iter_rows(min_row=2, values_only=True), 1):
    if not row[0]: continue
    typ = 'retail' if str(row[2]).strip() == 'ปลีก' else 'wholesale'
    m = re.search(r'\d+', str(row[3])); credit = int(m[0]) if m else 0
    ph = row[4]
    if ph is not None:
        ph = str(ph).replace('-', '')
        if len(ph) == 9: ph = '0' + ph; LOG['phone_leading_zero_restored'] += 1
    c = dict(id=i, code=str(row[0]).strip(), name=re.sub(r'\s+', ' ', str(row[1]).strip()), type=typ, phone=ph, credit=credit, limit=parse_num(row[5], 0))
    customers.append(c); ckey[cust_key(c['name'])] = c
WALK = next(c for c in customers if c['code'] == 'WALKIN')
WALK_ALIASES = {'', 'ลูกค้าทั่วไป', 'หน้าร้าน', 'เงินสด'}
def resolve_cust(v):
    s = '' if v is None else str(v).strip()
    if s in WALK_ALIASES: return WALK
    return ckey.get(cust_key(s))

# ---------------- 1 sales ----------------
wb1 = openpyxl.load_workbook(f'{SRC}/1_สมุดขาย_พ.ย.68-ต.ค.69.xlsx', data_only=True)
SYN = dict(date=['วันที่','วัน/เดือน/ปี'], inv=['เลขที่บิล','บิลเลขที่'], cust=['ชื่อลูกค้า','ลูกค้า'], prod=['รายการสินค้า','สินค้า'],
           qty=['จำนวน'], price=['ราคา/หน่วย','ราคา'], disc=['ส่วนลด','ลด'], total=['รวมเงิน','ยอดรวม'], pm=['วิธีชำระ','ชำระโดย'], note=['หมายเหตุ'])
PM = lambda s: 'credit' if ('เครดิต' in s or 'เชื่อ' in s) else ('transfer' if ('โอน' in s or s.lower().startswith('transfer')) else 'cash')
invs = {}; inv_order = []; seen_line = {}; ph_lines = []
for ws in wb1.worksheets:
    hr, hv = find_header(ws, {'เลขที่บิล','บิลเลขที่'}); cm = colmap(hv, SYN)
    for n in range(hr + 1, ws.max_row + 1):
        g = lambda k: ws.cell(n, cm[k] + 1).value
        inv = g('inv')
        if not inv:
            LOG['non_data_rows_skipped(subtotal/blank)'] += 1; continue
        inv = str(inv).strip().upper(); ref = f'{ws.title} แถว {n} {inv}'
        d = parse_date(g('date')); c = resolve_cust(g('cust'))
        if c is None:
            exc('1_สมุดขาย', ref, 'ไม่พบลูกค้า', f'ชื่อ "{g("cust")}" ไม่ตรงทะเบียนลูกค้า', 'ใช้ลูกค้าหน้าร้านไปก่อน'); c = WALK
        pname = str(g('prod')).strip(); p, how = resolve_product(pname)
        if p is None:
            exc('1_สมุดขาย', ref, 'ระบุสินค้าไม่ได้', f'ชื่อในสมุด "{pname}"', 'บันทึกยอดเงินไว้ที่สินค้า UNMAPPED รอตรวจสอบ'); p = PH; LOG['product_unresolved_rows'] += 1
        elif how == 'fuzzy': LOG['product_name_fuzzy_matched'] += 1
        elif pname != p['name']: LOG['product_name_normalized'] += 1
        q = parse_qty(g('qty')); price = parse_num(g('price')); disc = parse_num(g('disc'), 0.0)
        tot = parse_num(g('total')); calc = round(q * price - disc, 2)
        if tot is not None and abs(tot - calc) > 0.01:
            exc('1_สมุดขาย', ref, 'ยอดรวมในสมุดไม่ตรง', f'สมุด {tot:,.2f} แต่ {q}×{price:,.2f}−{disc:,.2f} = {calc:,.2f}', 'ใช้ค่าที่คำนวณ'); LOG['line_total_mismatch'] += 1
        pm = PM(str(g('pm')).strip()); cancel = 'ยกเลิก' in str(g('note') or '')
        if inv not in invs:
            invs[inv] = dict(inv=inv, date=d, cust=c, pm=pm, cancel=False, lines={}, ws=ws.title); inv_order.append(inv)
        I = invs[inv]
        if I['date'] != d: exc('1_สมุดขาย', ref, 'เลขที่บิลเดียวกันคนละวันที่', f'{I["date"]} vs {d}', 'ใช้วันที่ของแถวแรก')
        if I['cust'] is not c: exc('1_สมุดขาย', ref, 'บิลเดียวกันคนละลูกค้า', f'{I["cust"]["name"]} vs {c["name"]}', 'ใช้ลูกค้าของแถวแรก')
        I['cancel'] |= cancel
        key = (inv, p['sku'] if p is not PH else ('UNMAPPED', pname))
        if key in I['lines']:
            same = I['lines'][key][:3] == (q, price, disc)
            if same: LOG['duplicate_rows_dropped'] += 1; exc('1_สมุดขาย', ref, 'แถวซ้ำ', f'{pname} จำนวน {q} (เหมือนแถวก่อนหน้า)', 'ตัดแถวซ้ำ')
            else: exc('1_สมุดขาย', ref, 'สินค้าซ้ำในบิลเดียวกัน (ข้อมูลต่างกัน)', pname, 'เก็บแถวแรก')
            continue
        I['lines'][key] = (q, price, disc, p)
# ---------------- 2 purchases ----------------
wb2 = openpyxl.load_workbook(f'{SRC}/2_ใบสั่งซื้อสินค้า.xlsx', data_only=True); ws = wb2.active
hr, hv = find_header(ws, {'เลขที่ PO'})
cm = colmap(hv, dict(po=['เลขที่ PO'], date=['วันที่สั่ง'], sup=['ผู้จำหน่าย'], prod=['สินค้า'], qty=['จำนวน'], cost=['ราคาทุน/หน่วย'], rdate=['วันที่รับของ'], note=['หมายเหตุ']))
pos = {}; po_order = []
for n in range(hr + 1, ws.max_row + 1):
    g = lambda k: ws.cell(n, cm[k] + 1).value
    if not g('po'): continue
    no = str(g('po')).strip().upper(); sk = sup_key(g('sup'))
    if sk not in skey: exc('2_ใบสั่งซื้อ', f'แถว {n} {no}', 'ไม่พบผู้จำหน่าย', str(g('sup')), 'ข้ามแถว'); continue
    if no not in pos:
        pos[no] = dict(no=no, date=parse_date(g('date')), sup=skey[sk], rdate=parse_date(g('rdate')), note=str(g('note') or ''), lines={}); po_order.append(no)
    p, how = resolve_product(str(g('prod')).strip())
    if p is None:
        exc('2_ใบสั่งซื้อ', f'แถว {n} {no}', 'ระบุสินค้าไม่ได้', str(g('prod')), 'ข้ามแถว'); continue
    if how == 'fuzzy': LOG['po_product_fuzzy_matched'] += 1
    pos[no]['lines'][p['sku']] = (parse_qty(g('qty')), parse_num(g('cost')), p)
leads = [(o['rdate'] - o['date']).days for o in pos.values() if o['rdate']]
med_lead = int(statistics.median(leads))
for o in pos.values():
    if 'ยังไม่ได้รับ' in o['note'] and not o['rdate']: o['status'] = 'ordered'; o['est'] = False
    elif o['rdate']: o['status'] = 'received'; o['est'] = False
    else:
        o['status'] = 'received'; o['est'] = True; o['rdate'] = o['date'] + dt.timedelta(days=med_lead); LOG['po_received_date_estimated'] += 1
        exc('2_ใบสั่งซื้อ', o['no'], 'ไม่มีวันที่รับของ', f'ไม่ได้บันทึกวันที่รับ แต่ไม่ได้ระบุว่ายังไม่รับ', f'ถือว่ารับแล้ว ประมาณวันที่ {o["rdate"]} (มัธยฐานเวลาส่งของ {med_lead} วัน) — ติดธง received_date_is_estimated')

# ---------------- 5 payments ----------------
wb5 = openpyxl.load_workbook(f'{SRC}/5_บันทึกรับชำระหนี้.xlsx', data_only=True); pays = []
for n, row in enumerate(wb5.active.iter_rows(min_row=2, values_only=True), 2):
    if not row[1]: continue
    inv = re.sub(r'\s+', '', str(row[1])).upper()
    if '-' not in inv: inv = inv[:6] + '-' + inv[6:]; LOG['payment_invoice_no_dash_fixed'] += 1
    elif inv != str(row[1]): LOG['payment_invoice_no_trimmed_or_upper'] += 1
    if inv not in invs: exc('5_รับชำระ', f'แถว {n} {inv}', 'ไม่พบเลขที่บิล', 'บิลที่รับชำระไม่อยู่ในสมุดขาย', 'ข้ามแถว'); continue
    pays.append((inv, parse_date(row[0]), parse_num(row[2]), 'cash' if 'สด' in str(row[3]) else 'transfer'))
# ---------------- 6 stock count / adjustments ----------------
wb6 = openpyxl.load_workbook(f'{SRC}/6_นับสต็อกและปรับสต็อก.xlsx', data_only=True)
counts = [(by_sku[str(r[0]).strip().upper()]['id'], int(parse_num(r[2]))) for r in wb6.worksheets[0].iter_rows(min_row=2, values_only=True) if r[0]]
RSN = {'ชำรุด': 'damaged', 'ของหาย': 'lost', 'แก้ตามนับ': 'count_correction'}
adjs = [(parse_date(r[0]), by_sku[str(r[1]).strip().upper()]['id'], int(r[2]), RSN[str(r[3]).strip()]) for r in wb6.worksheets[1].iter_rows(min_row=2, values_only=True) if r[0]]

# ---------------- load ----------------
conn = psycopg2.connect(DSN); cur = conn.cursor(); cur.execute('SET search_path = shop')
execute_values(cur, 'INSERT INTO product_categories VALUES %s', [(v, k) for k, v in cats.items()])
execute_values(cur, 'INSERT INTO suppliers VALUES %s', suppliers)
execute_values(cur, 'INSERT INTO products (product_id,sku,product_name,category_id,supplier_id,unit,cost_price,retail_price,wholesale_price,reorder_point,is_active) VALUES %s',
    [(p['id'], p['sku'], p['name'], cats[p['cat']], p['sup'], p['unit'], p['cost'], p['ret'], p['wh'], p['rop'], p is not PH) for p in products])
execute_values(cur, 'INSERT INTO customers VALUES %s', [(c['id'], c['code'], c['name'], c['type'], c['phone'], c['credit'], c['limit']) for c in customers])
sid = {}; rows = []; lrows = []
for i, no in enumerate(sorted(inv_order, key=lambda k: (invs[k]['date'], k)), 1):
    I = invs[no]; sid[no] = i
    due = I['date'] + dt.timedelta(days=I['cust']['credit']) if I['pm'] == 'credit' else None
    rows.append((i, no, I['date'], I['cust']['id'], I['pm'], due, 'cancelled' if I['cancel'] else 'completed'))
    for ln, ((_, _), (q, price, disc, p)) in enumerate(((k, v) for k, v in I['lines'].items()), 1):
        lrows.append((i, ln, p['id'], q, price, disc))
# กันกรณีสินค้า UNMAPPED ซ้ำในบิลเดียวกัน (product_id ซ้ำ) ให้รวมแถว
merged = {}
for (i, ln, pid, q, price, disc) in lrows:
    k = (i, pid)
    if k in merged and pid == PH['id']:
        a = merged[k]; merged[k] = (a[0], a[1], pid, a[3] + q, round((a[3]*a[4] + q*price)/(a[3]+q), 2), a[5] + disc)
    else: merged[k] = (i, ln, pid, q, price, disc)
lrows = sorted(merged.values(), key=lambda r: (r[0], r[1]))
execute_values(cur, 'INSERT INTO sales_orders VALUES %s', rows)
execute_values(cur, 'INSERT INTO sales_order_lines (sales_order_id,line_no,product_id,quantity,unit_price,discount) VALUES %s', lrows, page_size=5000)
execute_values(cur, 'INSERT INTO customer_payments (sales_order_id,paid_date,amount,method) VALUES %s', [(sid[a], b, c, d) for a, b, c, d in pays])
poid = {}; prow = []; plrows = []
for i, no in enumerate(sorted(po_order, key=lambda k: (pos[k]['date'], k)), 1):
    o = pos[no]; poid[no] = i
    prow.append((i, no, o['date'], o['sup'], o['rdate'] if o['status'] == 'received' else None, o['est'], o['status']))
    for ln, (sku, (q, cst, p)) in enumerate(o['lines'].items(), 1): plrows.append((i, ln, p['id'], q, cst))
execute_values(cur, 'INSERT INTO purchase_orders VALUES %s', prow)
execute_values(cur, 'INSERT INTO purchase_order_lines (purchase_order_id,line_no,product_id,quantity,unit_cost) VALUES %s', plrows, page_size=5000)
opening = [(dt.date(2025, 11, 1), p['id'], p['open'], 'opening') for p in products if p['open'] > 0]
execute_values(cur, 'INSERT INTO stock_adjustments (adjust_date,product_id,quantity_change,reason) VALUES %s', opening + adjs)
execute_values(cur, 'INSERT INTO stock_counts VALUES %s', [(dt.date(2026, 10, 31), a, b) for a, b in counts])
# ตรวจราคาขายต่ำกว่าทุน (ไม่แก้ แต่บันทึกให้เจ้าของร้านตรวจ)
for (i, ln, pid, q, price, disc) in lrows:
    p = next(x for x in products if x['id'] == pid)
    if pid != PH['id'] and price < p['cost']:
        no = next(k for k, v in sid.items() if v == i)
        exc('1_สมุดขาย', no, 'ราคาขายต่ำกว่าทุน', f'{p["name"]} ขาย {price:,.2f} ทุน {p["cost"]:,.2f} (ตรวจว่าพิมพ์ราคาผิดหรือไม่)', 'นำเข้าตามที่บันทึก ไม่แก้')
        LOG['price_below_cost_flagged'] += 1
execute_values(cur, 'INSERT INTO import_exceptions (source_file,source_ref,issue_type,detail,action_taken) VALUES %s', EXC)
conn.commit()
for t in ['product_categories','suppliers','products','customers','sales_orders','sales_order_lines','customer_payments','purchase_orders','purchase_order_lines','stock_adjustments','stock_counts','import_exceptions']:
    cur.execute(f'SELECT count(*) FROM shop.{t}'); LOG['rows_in_' + t] = cur.fetchone()[0]
print(json.dumps(dict(LOG), ensure_ascii=False, indent=1))
json.dump(dict(LOG), open(sys.argv[3], 'w'), ensure_ascii=False, indent=1)
