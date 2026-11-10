package com.example.demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final String greeting;

    /** The greeting comes from configuration, not from a hardcoded literal. */
    public HelloController(@Value("${app.greeting}") String greeting) {
        this.greeting = greeting;
    }

    @GetMapping("/hello")
    public String hello() {
        return greeting;
    }
}
