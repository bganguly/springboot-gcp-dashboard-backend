-- Denormalized search_text column on orders for single-index trigram search.
-- Covers every visible list column: customer name, notes, total, order ID,
-- status, region code/name, and placed date.
-- pg_trgm already enabled in V3.

-- 1. Add column
ALTER TABLE orders ADD COLUMN IF NOT EXISTS search_text TEXT;

-- 2. Populate all rows (runs inside Flyway transaction — may take several minutes)
UPDATE orders o
SET search_text =
  c."firstName" || ' ' || c."lastName" || ' ' ||
  COALESCE(o.notes, '') || ' ' ||
  o.total::text || ' ' ||
  o.id::text || ' ' ||
  o.status::text || ' ' ||
  r.code || ' ' || r.name || ' ' ||
  o."placedAt"::date::text
FROM customers c, regions r
WHERE c.id = o."customerId"
  AND r.id = o."regionId";

-- 3. GIN trigram index (no CONCURRENTLY — Flyway runs inside a transaction)
CREATE INDEX IF NOT EXISTS idx_orders_search_text_trgm
  ON orders USING gin (search_text gin_trgm_ops);

-- 4. Keep search_text up-to-date when an order row changes
CREATE OR REPLACE FUNCTION fn_order_search_text() RETURNS TRIGGER AS $$
DECLARE
  v_first text; v_last text; v_rcode text; v_rname text;
BEGIN
  SELECT "firstName", "lastName" INTO v_first, v_last
    FROM customers WHERE id = NEW."customerId";
  SELECT code, name INTO v_rcode, v_rname
    FROM regions WHERE id = NEW."regionId";
  NEW.search_text :=
    v_first || ' ' || v_last || ' ' ||
    COALESCE(NEW.notes, '') || ' ' ||
    NEW.total::text || ' ' ||
    NEW.id::text || ' ' ||
    NEW.status::text || ' ' ||
    v_rcode || ' ' || v_rname || ' ' ||
    NEW."placedAt"::date::text;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trgr_order_search_text
  BEFORE INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION fn_order_search_text();

-- 5. Propagate customer name changes to all their orders
CREATE OR REPLACE FUNCTION fn_customer_name_to_orders() RETURNS TRIGGER AS $$
BEGIN
  IF OLD."firstName" IS DISTINCT FROM NEW."firstName" OR
     OLD."lastName"  IS DISTINCT FROM NEW."lastName" THEN
    UPDATE orders o
    SET search_text =
      NEW."firstName" || ' ' || NEW."lastName" || ' ' ||
      COALESCE(o.notes, '') || ' ' ||
      o.total::text || ' ' ||
      o.id::text || ' ' ||
      o.status::text || ' ' ||
      r.code || ' ' || r.name || ' ' ||
      o."placedAt"::date::text
    FROM regions r
    WHERE o."customerId" = NEW.id AND r.id = o."regionId";
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trgr_customer_search_text
  AFTER UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION fn_customer_name_to_orders();
