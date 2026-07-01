-- B-tree index for sub-second ORDER BY customer name on 4M orders.
-- Enables: index scan on customers(firstName, lastName) → nested-loop join
-- to orders(customerId) → LIMIT 20 without sorting the full orders table.
CREATE INDEX IF NOT EXISTS "customers_firstName_lastName_idx"
    ON customers ("firstName", "lastName");
