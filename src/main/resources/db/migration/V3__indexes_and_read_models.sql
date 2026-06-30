-- 20260622000000_orders_search_indexes
-- Indexes to keep /api/orders fast at ~4M rows: sort-by-total / sort-by-customer
-- and pg_trgm-backed text search.
--
-- NOTE: this migration uses plain (non-CONCURRENT) CREATE INDEX so it is
-- transaction-safe for Flyway. On a large, live table the non-concurrent build
-- takes a brief write lock. To add these to an already-populated production DB
-- without locking, use CREATE INDEX CONCURRENTLY outside a transaction.

-- B-tree indexes.
CREATE INDEX IF NOT EXISTS "orders_total_idx" ON "orders" ("total");
CREATE INDEX IF NOT EXISTS "customers_lastName_idx" ON "customers" ("lastName");

-- Trigram search. ILIKE '%q%' cannot use a B-tree; pg_trgm's gin_trgm_ops can.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Combined index over the exact expression the orders search filters on
-- (customer first name + last name + email). The query MUST use this same
-- expression (see lib/services/orders.service.ts) for the index to apply.
CREATE INDEX IF NOT EXISTS "idx_customers_trgm" ON "customers"
  USING gin (("firstName" || ' ' || "lastName" || ' ' || email) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS "idx_orders_notes_trgm" ON "orders"
  USING gin (notes gin_trgm_ops);

-- 20260623000000_orders_customer_placed_at_index
-- Supports exact aggregate recomputation for customer keyword searches by
-- letting the planner fetch matching customers' orders inside a date range.
CREATE INDEX IF NOT EXISTS "orders_customer_placedAt_idx"
  ON "orders" ("customerId", "placedAt");

-- 20260623001000_order_items_aggregate_index
-- Supports exact chart aggregates from a filtered order-id set without reading
-- the entire order_items table.
CREATE INDEX IF NOT EXISTS "order_items_orderId_aggregate_idx"
  ON "order_items" ("orderId") INCLUDE ("productId", quantity, "unitPrice", discount);

-- 20260623002000_dashboard_filter_indexes
-- Composite indexes for the dashboard's common filter combinations.
-- Single-column indexes exist, but 30-day filtered list/aggregate queries need
-- indexes that keep the date range close to status/region/total predicates.

CREATE INDEX IF NOT EXISTS "orders_status_placedAt_idx"
  ON "orders" ("status", "placedAt");

CREATE INDEX IF NOT EXISTS "orders_regionId_placedAt_idx"
  ON "orders" ("regionId", "placedAt");

CREATE INDEX IF NOT EXISTS "orders_status_regionId_placedAt_idx"
  ON "orders" ("status", "regionId", "placedAt");

CREATE INDEX IF NOT EXISTS "orders_total_placedAt_idx"
  ON "orders" ("total", "placedAt");

CREATE INDEX IF NOT EXISTS "daily_summary_regionCode_date_idx"
  ON "daily_summary" ("regionCode", "date");

-- 20260623003000_daily_customer_category_summary
-- Per-day, per-customer/category rollup for fast exact dashboard aggregates
-- when filtering by customer text, status, region, and date.
CREATE TABLE IF NOT EXISTS "daily_customer_category_summary" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "customerId" integer NOT NULL,
  "regionId" integer NOT NULL,
  "regionCode" varchar(10) NOT NULL,
  "status" "OrderStatus" NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14, 2) NOT NULL DEFAULT 0,
  "totalItems" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_customer_category_summary_day_customer_region_status_category_key"
  ON "daily_customer_category_summary" ("date", "customerId", "regionId", "status", "categoryId");

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_customer_date_idx"
  ON "daily_customer_category_summary" ("customerId", "date");

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_date_status_idx"
  ON "daily_customer_category_summary" ("date", "status");

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_date_region_idx"
  ON "daily_customer_category_summary" ("date", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_date_status_region_idx"
  ON "daily_customer_category_summary" ("date", "status", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_region_code_date_idx"
  ON "daily_customer_category_summary" ("regionCode", "date");

-- 20260623004000_daily_customer_token_category_summary
-- Token-level daily rollup for fast customer keyword analytics.
-- Example: q=frank reads token='frank' rows for the selected date range instead
-- of joining every matching customer/order/item/category row live.
CREATE TABLE IF NOT EXISTS "daily_customer_token_category_summary" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "token" varchar(255) NOT NULL,
  "regionId" integer NOT NULL,
  "regionCode" varchar(10) NOT NULL,
  "status" "OrderStatus" NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14, 2) NOT NULL DEFAULT 0,
  "totalItems" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_customer_token_category_summary_day_token_region_status_category_key"
  ON "daily_customer_token_category_summary" ("date", "token", "regionId", "status", "categoryId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_token_date_idx"
  ON "daily_customer_token_category_summary" ("token", "date");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_token_date_status_idx"
  ON "daily_customer_token_category_summary" ("token", "date", "status");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_token_date_region_idx"
  ON "daily_customer_token_category_summary" ("token", "date", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_token_date_status_region_idx"
  ON "daily_customer_token_category_summary" ("token", "date", "status", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_token_region_code_date_idx"
  ON "daily_customer_token_category_summary" ("token", "regionCode", "date");

-- 20260623005000_daily_customer_token_order_summary
-- Token-level daily order-count rollup for exact list pagination totals.
-- This is separate from the category rollup so list totals count each order
-- once, even if an order has items in multiple categories.
CREATE TABLE IF NOT EXISTS "daily_customer_token_order_summary" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "token" varchar(255) NOT NULL,
  "regionId" integer NOT NULL,
  "regionCode" varchar(10) NOT NULL,
  "status" "OrderStatus" NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14, 2) NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_customer_token_order_summary_day_token_region_status_key"
  ON "daily_customer_token_order_summary" ("date", "token", "regionId", "status");

CREATE INDEX IF NOT EXISTS "daily_customer_token_order_summary_token_date_idx"
  ON "daily_customer_token_order_summary" ("token", "date");

CREATE INDEX IF NOT EXISTS "daily_customer_token_order_summary_token_date_status_idx"
  ON "daily_customer_token_order_summary" ("token", "date", "status");

CREATE INDEX IF NOT EXISTS "daily_customer_token_order_summary_token_date_region_idx"
  ON "daily_customer_token_order_summary" ("token", "date", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_order_summary_token_date_status_region_idx"
  ON "daily_customer_token_order_summary" ("token", "date", "status", "regionId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_order_summary_token_region_code_date_idx"
  ON "daily_customer_token_order_summary" ("token", "regionCode", "date");

-- 20260624000000_token_chart_covering_index
-- Cover dense name-search chart queries from the token/category summary table.
-- This lets /api/aggregates?q=<name> group by date/category using an index-only
-- scan instead of fetching hundreds of thousands of heap rows.
CREATE INDEX IF NOT EXISTS "daily_customer_token_category_summary_chart_cover_idx"
  ON "daily_customer_token_category_summary" (token, date, "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue", status, "regionCode");

-- 20260624001000_daily_customer_token_category_rollup
-- Pre-aggregated token/date/category chart table for plain name searches.
-- This avoids scanning region/status-expanded token summary rows when the chart
-- has no status or region filter.
CREATE TABLE IF NOT EXISTS "daily_customer_token_category_rollup" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "token" varchar(255) NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14,2) NOT NULL DEFAULT 0,
  "totalItems" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT now(),
  "updatedAt" timestamp(3) NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_customer_token_category_rollup_day_token_category_key"
  ON "daily_customer_token_category_rollup" ("date", "token", "categoryId");

CREATE INDEX IF NOT EXISTS "daily_customer_token_category_rollup_token_date_idx"
  ON "daily_customer_token_category_rollup" ("token", "date");

INSERT INTO "daily_customer_token_category_rollup" (
  "date", "token", "categoryId", "categoryName", "totalOrders", "totalRevenue", "totalItems", "createdAt", "updatedAt"
)
SELECT
  "date",
  "token",
  "categoryId",
  "categoryName",
  sum("totalOrders")::int,
  sum("totalRevenue"),
  sum("totalItems")::int,
  now(),
  now()
FROM "daily_customer_token_category_summary"
GROUP BY "date", "token", "categoryId", "categoryName"
ON CONFLICT ("date", "token", "categoryId")
DO UPDATE SET
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders" = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems" = EXCLUDED."totalItems",
  "updatedAt" = now();

-- 20260624002000_order_category_facts
-- Per-order category facts used by visible text/note/id searches to build chart
-- aggregates without joining order_items/products/categories at request time.
CREATE TABLE IF NOT EXISTS "order_category_facts" (
  "orderId" integer NOT NULL,
  "placedAt" timestamp(3) NOT NULL,
  "date" date NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalItems" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY ("orderId", "categoryId")
);

CREATE INDEX IF NOT EXISTS "order_category_facts_order_id_idx"
  ON "order_category_facts" ("orderId");

CREATE INDEX IF NOT EXISTS "order_category_facts_date_idx"
  ON "order_category_facts" ("date");

INSERT INTO "order_category_facts" (
  "orderId", "placedAt", "date", "categoryId", "categoryName", "totalItems", "totalRevenue"
)
SELECT
  o.id,
  o."placedAt",
  o."placedAt"::date,
  cat.id,
  cat.name,
  coalesce(sum(oi.quantity), 0)::int,
  coalesce(sum(oi.quantity * oi."unitPrice" * (1 - oi.discount)), 0)
FROM "orders" o
JOIN "order_items" oi ON oi."orderId" = o.id
JOIN "products" p ON p.id = oi."productId"
JOIN "categories" cat ON cat.id = p."categoryId"
GROUP BY o.id, o."placedAt", cat.id, cat.name
ON CONFLICT ("orderId", "categoryId")
DO UPDATE SET
  "placedAt" = EXCLUDED."placedAt",
  "date" = EXCLUDED."date",
  "categoryName" = EXCLUDED."categoryName",
  "totalItems" = EXCLUDED."totalItems",
  "totalRevenue" = EXCLUDED."totalRevenue";

-- 20260624003000_daily_filter_category_summary
CREATE TABLE IF NOT EXISTS "daily_filter_category_summary" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "regionId" integer NOT NULL,
  "regionCode" varchar(10) NOT NULL,
  "status" "OrderStatus" NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14, 2) NOT NULL DEFAULT 0,
  "totalItems" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_filter_category_summary_day_region_status_category_key"
  ON "daily_filter_category_summary" ("date", "regionId", "status", "categoryId");

CREATE INDEX IF NOT EXISTS "daily_filter_category_summary_date_status_idx"
  ON "daily_filter_category_summary" ("date", "status");

CREATE INDEX IF NOT EXISTS "daily_filter_category_summary_date_status_region_idx"
  ON "daily_filter_category_summary" ("date", "status", "regionId");

CREATE INDEX IF NOT EXISTS "daily_filter_category_summary_region_code_date_status_idx"
  ON "daily_filter_category_summary" ("regionCode", "date", "status");

INSERT INTO "daily_filter_category_summary" (
  "date",
  "regionId",
  "regionCode",
  "status",
  "categoryId",
  "categoryName",
  "totalOrders",
  "totalRevenue",
  "totalItems"
)
SELECT
  "date",
  "regionId",
  "regionCode",
  "status",
  "categoryId",
  "categoryName",
  SUM("totalOrders")::integer,
  SUM("totalRevenue"),
  SUM("totalItems")::integer
FROM "daily_customer_category_summary"
GROUP BY
  "date",
  "regionId",
  "regionCode",
  "status",
  "categoryId",
  "categoryName"
ON CONFLICT ("date", "regionId", "status", "categoryId") DO UPDATE SET
  "regionCode" = EXCLUDED."regionCode",
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders" = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems" = EXCLUDED."totalItems",
  "updatedAt" = CURRENT_TIMESTAMP;

-- 20260624004000_order_category_fact_filter_columns
ALTER TABLE "order_category_facts"
  ADD COLUMN IF NOT EXISTS "regionId" integer,
  ADD COLUMN IF NOT EXISTS "regionCode" varchar(10),
  ADD COLUMN IF NOT EXISTS "status" "OrderStatus",
  ADD COLUMN IF NOT EXISTS "orderTotal" numeric(12, 2);

UPDATE "order_category_facts" f
SET
  "regionId" = o."regionId",
  "regionCode" = r.code,
  "status" = o.status,
  "orderTotal" = o.total
FROM orders o
JOIN regions r ON r.id = o."regionId"
WHERE o.id = f."orderId"
  AND (
    f."regionId" IS NULL
    OR f."regionCode" IS NULL
    OR f."status" IS NULL
    OR f."orderTotal" IS NULL
  );

CREATE INDEX IF NOT EXISTS "order_category_facts_date_total_idx"
  ON "order_category_facts" ("date", "orderTotal");

CREATE INDEX IF NOT EXISTS "order_category_facts_status_date_total_idx"
  ON "order_category_facts" ("status", "date", "orderTotal");

CREATE INDEX IF NOT EXISTS "order_category_facts_region_code_date_status_total_idx"
  ON "order_category_facts" ("regionCode", "date", "status", "orderTotal");

-- 20260624005000_daily_filter_covering_indexes
CREATE INDEX IF NOT EXISTS "daily_filter_category_summary_status_date_category_cover_idx"
  ON "daily_filter_category_summary" (status, date, "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue", "regionCode");

CREATE INDEX IF NOT EXISTS "daily_filter_category_summary_region_status_date_category_cover_idx"
  ON "daily_filter_category_summary" ("regionCode", status, date, "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue");

-- 20260624006000_order_category_fact_covering_indexes
CREATE INDEX IF NOT EXISTS "order_category_facts_date_total_category_cover_idx"
  ON "order_category_facts" ("date", "orderTotal", "categoryName")
  INCLUDE ("totalItems", "totalRevenue", status, "regionCode");

CREATE INDEX IF NOT EXISTS "order_category_facts_status_date_total_category_cover_idx"
  ON "order_category_facts" (status, "date", "orderTotal", "categoryName")
  INCLUDE ("totalItems", "totalRevenue", "regionCode");

CREATE INDEX IF NOT EXISTS "order_category_facts_region_status_date_total_category_cover_idx"
  ON "order_category_facts" ("regionCode", status, "date", "orderTotal", "categoryName")
  INCLUDE ("totalItems", "totalRevenue");

-- 20260624007000_daily_status_category_summary
CREATE TABLE IF NOT EXISTS "daily_status_category_summary" (
  "id" serial PRIMARY KEY,
  "date" date NOT NULL,
  "status" "OrderStatus" NOT NULL,
  "categoryId" integer NOT NULL,
  "categoryName" varchar(100) NOT NULL,
  "totalOrders" integer NOT NULL DEFAULT 0,
  "totalRevenue" numeric(14, 2) NOT NULL DEFAULT 0,
  "totalItems" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "daily_status_category_summary_day_status_category_key"
  ON "daily_status_category_summary" ("date", "status", "categoryId");

CREATE INDEX IF NOT EXISTS "daily_status_category_summary_status_date_category_cover_idx"
  ON "daily_status_category_summary" (status, date, "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue");

INSERT INTO "daily_status_category_summary" (
  "date",
  "status",
  "categoryId",
  "categoryName",
  "totalOrders",
  "totalRevenue",
  "totalItems"
)
SELECT
  "date",
  "status",
  "categoryId",
  "categoryName",
  SUM("totalOrders")::integer,
  SUM("totalRevenue"),
  SUM("totalItems")::integer
FROM "daily_filter_category_summary"
GROUP BY
  "date",
  "status",
  "categoryId",
  "categoryName"
ON CONFLICT ("date", "status", "categoryId") DO UPDATE SET
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders" = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems" = EXCLUDED."totalItems",
  "updatedAt" = CURRENT_TIMESTAMP;

-- 20260624008000_backfill_visible_customer_token_category_summary
-- Backfill exact chart aggregates for visible customer-name token searches with
-- status/region filters. Plain token searches can use the denormalized rollup,
-- but token + status/region needs the status/region-expanded summary.
INSERT INTO "daily_customer_token_category_summary" (
  "date",
  "token",
  "regionId",
  "regionCode",
  "status",
  "categoryId",
  "categoryName",
  "totalOrders",
  "totalRevenue",
  "totalItems",
  "createdAt",
  "updatedAt"
)
SELECT
  ds."date",
  t.token,
  ds."regionId",
  ds."regionCode",
  ds."status",
  ds."categoryId",
  ds."categoryName",
  SUM(ds."totalOrders")::integer,
  SUM(ds."totalRevenue"),
  SUM(ds."totalItems")::integer,
  now(),
  now()
FROM "daily_customer_category_summary" ds
JOIN customers c ON c.id = ds."customerId"
CROSS JOIN LATERAL (
  SELECT DISTINCT token
  FROM unnest(ARRAY[
    lower(c."firstName"),
    lower(c."lastName")
  ]) AS token
  WHERE token <> ''
) t
GROUP BY
  ds."date",
  t.token,
  ds."regionId",
  ds."regionCode",
  ds."status",
  ds."categoryId",
  ds."categoryName"
ON CONFLICT ("date", "token", "regionId", "status", "categoryId") DO UPDATE SET
  "regionCode" = EXCLUDED."regionCode",
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders" = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems" = EXCLUDED."totalItems",
  "updatedAt" = now();

INSERT INTO "daily_customer_token_category_rollup" (
  "date",
  "token",
  "categoryId",
  "categoryName",
  "totalOrders",
  "totalRevenue",
  "totalItems",
  "createdAt",
  "updatedAt"
)
SELECT
  "date",
  "token",
  "categoryId",
  "categoryName",
  SUM("totalOrders")::integer,
  SUM("totalRevenue"),
  SUM("totalItems")::integer,
  now(),
  now()
FROM "daily_customer_token_category_summary"
GROUP BY "date", "token", "categoryId", "categoryName"
ON CONFLICT ("date", "token", "categoryId") DO UPDATE SET
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders" = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems" = EXCLUDED."totalItems",
  "updatedAt" = now();

-- 20260624009000_customer_category_filter_covering_index
CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_status_date_customer_category_cover_idx"
  ON "daily_customer_category_summary" (status, date, "customerId", "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue", "regionCode");

-- 20260624010000_customer_category_region_covering_indexes
CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_region_date_customer_category_cover_idx"
  ON "daily_customer_category_summary" ("regionCode", date, "customerId", "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue", status);

CREATE INDEX IF NOT EXISTS "daily_customer_category_summary_region_status_date_customer_category_cover_idx"
  ON "daily_customer_category_summary" ("regionCode", status, date, "customerId", "categoryName")
  INCLUDE ("totalOrders", "totalItems", "totalRevenue");

