package com.dashboard.service;

import com.dashboard.dto.*;
import com.dashboard.entity.*;
import com.dashboard.repository.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class OrderService {

    private static final int DEFAULT_PAGE_SIZE = 20;
    private static final int MAX_PAGE_SIZE = 100;
    private static final DateTimeFormatter ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");

    private final NamedParameterJdbcTemplate jdbc;
    private final OrderRepository orderRepository;
    private final CustomerRepository customerRepository;
    private final RegionRepository regionRepository;
    private final ProductRepository productRepository;

    public OrderListResult listOrders(
            String q, int page, int pageSize, String sort, String dir,
            String status, String regionCode,
            String from, String to,
            BigDecimal minTotal, BigDecimal maxTotal) {

        pageSize = Math.min(Math.max(pageSize, 1), MAX_PAGE_SIZE);
        page = Math.max(page, 1);
        int offset = (page - 1) * pageSize;

        String safeSort = Set.of("placedAt", "total", "status", "customer", "id").contains(sort) ? sort : "placedAt";
        String safeDir = "asc".equalsIgnoreCase(dir) ? "ASC" : "DESC";

        var params = new MapSqlParameterSource();
        String ctePrefix = buildSearchCte(q, params);
        var where = buildWhere(q, status, regionCode, from, to, minTotal, maxTotal, params);

        boolean needsRegionJoin = regionCode != null && !regionCode.isBlank();
        String regionJoin = needsRegionJoin ? "JOIN regions r ON r.id = o.\"regionId\" " : "";
        String countSql = ctePrefix + "SELECT COUNT(*) FROM orders o " + regionJoin + where;
        long total = Objects.requireNonNull(jdbc.queryForObject(countSql, params, Long.class));
        boolean approximate = false;

        // Data page
        String orderBy = switch (safeSort) {
            case "customer" -> "c.\"firstName\" " + safeDir + ", c.\"lastName\" " + safeDir + ", o.\"placedAt\" DESC";
            case "total"    -> "o.total " + safeDir + ", o.\"placedAt\" DESC";
            case "status"   -> "o.status " + safeDir + ", o.\"placedAt\" DESC";
            case "id"       -> "o.id " + safeDir;
            default         -> "o.\"placedAt\" " + safeDir;
        };
        String dataSql = ctePrefix + """
                SELECT o.id, o.status, o.total, o.currency, o.notes, o."placedAt",
                       c.id AS c_id, c.email, c."firstName", c."lastName", c.phone,
                       r.id AS r_id, r.code AS r_code, r.name AS r_name
                FROM orders o
                JOIN customers c ON c.id = o."customerId"
                JOIN regions r ON r.id = o."regionId"
                """ + where +
                " ORDER BY " + orderBy +
                " LIMIT :limit OFFSET :offset";
        params.addValue("limit", pageSize).addValue("offset", offset);

        List<Map<String, Object>> rows = jdbc.queryForList(dataSql, params);

        if (rows.isEmpty()) {
            return new OrderListResult(List.of(), page, pageSize, total,
                    (int) Math.ceil((double) total / pageSize), approximate);
        }

        List<Integer> orderIds = rows.stream()
                .map(r -> ((Number) r.get("id")).intValue())
                .toList();

        // Fetch items for this page
        Map<Integer, List<OrderItemDTO>> itemsByOrder = fetchItems(orderIds);

        List<OrderDTO> data = rows.stream().map(r -> {
            int id = ((Number) r.get("id")).intValue();
            return new OrderDTO(
                    id,
                    (String) r.get("status"),
                    (BigDecimal) r.get("total"),
                    (String) r.get("currency"),
                    (String) r.get("notes"),
                    formatTs(r.get("placedAt")),
                    new CustomerSummaryDTO(
                            ((Number) r.get("c_id")).intValue(),
                            (String) r.get("email"),
                            (String) r.get("firstName"),
                            (String) r.get("lastName")),
                    new RegionDTO(
                            ((Number) r.get("r_id")).intValue(),
                            (String) r.get("r_code"),
                            (String) r.get("r_name")),
                    itemsByOrder.getOrDefault(id, List.of())
            );
        }).toList();

        int totalPages = (int) Math.ceil((double) total / pageSize);
        return new OrderListResult(data, page, pageSize, total, totalPages, approximate);
    }

    @Transactional
    public Map<String, Object> createOrder(CreateOrderRequest req) {
        Customer customer = customerRepository.findById(req.customerId())
                .orElseThrow(() -> new IllegalArgumentException("Customer not found: " + req.customerId()));
        Region region = regionRepository.findById(req.regionId())
                .orElseThrow(() -> new IllegalArgumentException("Region not found: " + req.regionId()));

        Order order = new Order();
        order.setCustomer(customer);
        order.setRegion(region);
        order.setCurrency(req.currency() != null ? req.currency() : "USD");
        order.setNotes(req.notes());
        order.setPlacedAt(LocalDateTime.now());
        order.setUpdatedAt(LocalDateTime.now());

        BigDecimal total = BigDecimal.ZERO;
        List<OrderItem> items = new ArrayList<>();
        for (var itemReq : req.items()) {
            Product product = productRepository.findById(itemReq.productId())
                    .orElseThrow(() -> new IllegalArgumentException("Product not found: " + itemReq.productId()));
            OrderItem item = new OrderItem();
            item.setOrder(order);
            item.setProduct(product);
            item.setQuantity(itemReq.quantity());
            item.setUnitPrice(itemReq.unitPrice());
            BigDecimal disc = itemReq.discount() != null ? itemReq.discount() : BigDecimal.ZERO;
            item.setDiscount(disc);
            BigDecimal lineTotal = itemReq.unitPrice()
                    .multiply(BigDecimal.valueOf(itemReq.quantity()))
                    .multiply(BigDecimal.ONE.subtract(disc));
            total = total.add(lineTotal);
            items.add(item);
        }
        order.setTotal(total);
        order.setItems(items);
        Order saved = orderRepository.save(order);

        return Map.of(
                "id", saved.getId(),
                "status", saved.getStatus().name(),
                "total", saved.getTotal(),
                "placedAt", ISO.format(saved.getPlacedAt()));
    }

    // --- helpers ---

    private String buildSearchCte(String q, MapSqlParameterSource params) {
        return ""; // search_text column handles all search — no CTE needed
    }

    private String buildWhere(String q, String status, String regionCode,
                               String from, String to,
                               BigDecimal minTotal, BigDecimal maxTotal,
                               MapSqlParameterSource params) {
        List<String> clauses = new ArrayList<>();

        if (q != null && !q.isBlank()) {
            String[] tokens = q.strip().split("\\s+");
            for (int i = 0; i < tokens.length; i++) {
                String key = "q" + i;
                clauses.add("o.search_text ILIKE :" + key);
                params.addValue(key, "%" + tokens[i] + "%");
            }
        }
        if (status != null && !status.isBlank()) {
            List<String> statuses = Arrays.stream(status.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("o.status = ANY(ARRAY[" +
                    statuses.stream().map(s -> "'" + s + "'::\"OrderStatus\"").collect(Collectors.joining(",")) + "])");
        }
        if (regionCode != null && !regionCode.isBlank()) {
            List<String> codes = Arrays.stream(regionCode.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("r.code = ANY(ARRAY[" +
                    codes.stream().map(c -> "'" + c + "'").collect(Collectors.joining(",")) + "])");
        }
        if (from != null && !from.isBlank()) {
            clauses.add("o.\"placedAt\" >= :from::timestamptz");
            params.addValue("from", from);
        }
        if (to != null && !to.isBlank()) {
            clauses.add("o.\"placedAt\" <= (:to::date + interval '1 day' - interval '1 second')");
            params.addValue("to", to);
        }
        if (minTotal != null) {
            clauses.add("o.total >= :minTotal");
            params.addValue("minTotal", minTotal);
        }
        if (maxTotal != null) {
            clauses.add("o.total <= :maxTotal");
            params.addValue("maxTotal", maxTotal);
        }
        return clauses.isEmpty() ? "" : "WHERE " + String.join(" AND ", clauses);
    }

    private Map<Integer, List<OrderItemDTO>> fetchItems(List<Integer> orderIds) {
        if (orderIds.isEmpty()) return Map.of();
        String sql = """
                SELECT oi.id, oi."orderId", oi."productId", oi.quantity, oi."unitPrice", oi.discount,
                       p.sku, p.name AS p_name
                FROM order_items oi
                JOIN products p ON p.id = oi."productId"
                WHERE oi."orderId" = ANY(:ids)
                """;
        var params = new MapSqlParameterSource("ids", orderIds.toArray(new Integer[0]));
        List<Map<String, Object>> rows = jdbc.queryForList(sql, params);
        Map<Integer, List<OrderItemDTO>> result = new HashMap<>();
        for (var row : rows) {
            int orderId = ((Number) row.get("orderId")).intValue();
            result.computeIfAbsent(orderId, k -> new ArrayList<>()).add(new OrderItemDTO(
                    ((Number) row.get("id")).intValue(),
                    ((Number) row.get("productId")).intValue(),
                    (String) row.get("sku"),
                    (String) row.get("p_name"),
                    ((Number) row.get("quantity")).intValue(),
                    (BigDecimal) row.get("unitPrice"),
                    (BigDecimal) row.get("discount")));
        }
        return result;
    }

    private String formatTs(Object ts) {
        if (ts == null) return null;
        if (ts instanceof LocalDateTime ldt) return ISO.format(ldt);
        return ts.toString();
    }
}
