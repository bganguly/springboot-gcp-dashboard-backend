package com.dashboard.config;

import org.springframework.boot.flyway.autoconfigure.FlywayMigrationStrategy;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class FlywayConfig {

    @Bean
    public FlywayMigrationStrategy resetOnStaleBaseline() {
        return flyway -> {
            // If flyway_schema_history contains only a BASELINE row (no versioned migrations),
            // the baseline was stamped on a fresh DB but the actual DDL was never executed.
            // Clearing that row lets Flyway treat the DB as new and run all versioned migrations.
            try (var conn = flyway.getConfiguration().getDataSource().getConnection();
                 var stmt = conn.createStatement()) {
                var rs = stmt.executeQuery(
                        "SELECT COUNT(*) FROM flyway_schema_history WHERE type != 'BASELINE'");
                rs.next();
                if (rs.getInt(1) == 0) {
                    stmt.execute("DELETE FROM flyway_schema_history");
                }
            } catch (Exception ignored) {
                // Table absent (truly fresh DB) — Flyway will initialise it normally.
            }
            flyway.migrate();
        };
    }
}
