package com.example.demo;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Deliberately throws, so the security tests can prove that an unhandled error
 * is returned as a sanitized 500 and not as a stack trace.
 */
@RestController
public class ErrorProbeController {

    @GetMapping("/api/boom")
    public String boom() {
        throw new IllegalStateException("internal detail that must stay in the log");
    }
}
