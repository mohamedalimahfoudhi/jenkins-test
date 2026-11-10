package com.example.demo;

import java.util.Map;

import jakarta.validation.Valid;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/items")
public class ItemController {

    /**
     * Echoes the validated item back. Not business logic — it exists so the
     * validation and error-handling tests have a real endpoint to exercise.
     */
    @PostMapping
    public ResponseEntity<Map<String, Object>> create(@Valid @RequestBody ItemRequest request) {
        return ResponseEntity.ok(Map.of(
                "name", request.name(),
                "quantity", request.quantity()));
    }
}
