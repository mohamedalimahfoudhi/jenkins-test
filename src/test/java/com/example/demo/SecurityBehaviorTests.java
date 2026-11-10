package com.example.demo;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

/**
 * Security-relevant behaviour of the REST API.
 *
 * <p>These are behavioural tests, not penetration tests: they pin down the
 * validation and error-handling contract so a later change cannot silently
 * weaken it.
 */
@SpringBootTest(properties = {"management.endpoints.web.exposure.include=health,prometheus"})
@AutoConfigureMockMvc
class SecurityBehaviorTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("a valid item is accepted")
    void validItemIsAccepted() throws Exception {
        mockMvc.perform(post("/api/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"bolt\",\"quantity\":3}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.quantity").value(3));
    }

    @Test
    @DisplayName("input validation rejects a blank name with HTTP 400")
    void blankNameIsRejected() throws Exception {
        mockMvc.perform(post("/api/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"   \",\"quantity\":3}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.fields.name").exists());
    }

    @Test
    @DisplayName("input validation rejects an out-of-range quantity with HTTP 400")
    void outOfRangeQuantityIsRejected() throws Exception {
        mockMvc.perform(post("/api/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"bolt\",\"quantity\":0}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.fields.quantity").exists());
    }

    @Test
    @DisplayName("input validation rejects an oversized name with HTTP 400")
    void oversizedNameIsRejected() throws Exception {
        String longName = "x".repeat(50);
        mockMvc.perform(post("/api/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"" + longName + "\",\"quantity\":1}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.fields.name").exists());
    }

    @Test
    @DisplayName("malformed JSON is answered with HTTP 400")
    void malformedJsonIsRejected() throws Exception {
        mockMvc.perform(post("/api/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"bolt\","))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("an unhandled error returns 500 without leaking internals")
    void errorResponseDoesNotLeakInternals() throws Exception {
        String body = mockMvc.perform(get("/api/boom"))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.error").value("Internal Server Error"))
                .andReturn()
                .getResponse()
                .getContentAsString();

        assertFalse(body.contains("IllegalStateException"), "exception type leaked: " + body);
        assertFalse(body.contains("com.example.demo"), "package/class names leaked: " + body);
        assertFalse(body.contains("internal detail"), "internal message leaked: " + body);
    }

    @Test
    @DisplayName("an unknown route returns 404, not 500")
    void unknownRouteReturns404() throws Exception {
        mockMvc.perform(get("/nope"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("Not Found"));
    }

    @Test
    @DisplayName("health is exposed for the monitoring stack without details")
    void healthEndpointIsExposedWithoutDetails() throws Exception {
        String body = mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                .andReturn().getResponse().getContentAsString();

        assertFalse(body.contains("components"), "health leaked component details: " + body);
    }

    // The scrape endpoint is asserted against a real running instance
    // (scripts/security-smoke-test.sh, scripts/monitoring-check.sh), not here:
    // in a MockMvc context the metrics-export auto-configuration stays disabled,
    // so /actuator/prometheus is never registered and an assertion here would
    // only be testing the harness.

    @Test
    @DisplayName("actuator endpoints that leak configuration stay closed")
    void sensitiveActuatorEndpointsAreClosed() throws Exception {
        // /actuator is the discovery page: it answers 200 by design, and the
        // security property is that it only advertises the two safe endpoints.
        String links = mockMvc.perform(get("/actuator"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        for (String forbidden : new String[] {"env", "beans", "heapdump", "threaddump", "loggers"}) {
            assertFalse(links.contains("/" + forbidden),
                    "actuator discovery advertises " + forbidden + ": " + links);
        }

        mockMvc.perform(get("/actuator/env")).andExpect(status().isNotFound());
        mockMvc.perform(get("/actuator/beans")).andExpect(status().isNotFound());
        mockMvc.perform(get("/actuator/heapdump")).andExpect(status().isNotFound());
    }
}
