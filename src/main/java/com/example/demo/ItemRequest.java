package com.example.demo;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Input of {@code POST /api/items}. Validation lives here so untrusted input is
 * rejected before it reaches any application logic.
 */
public record ItemRequest(

        @NotBlank(message = "name must not be blank")
        @Size(max = 20, message = "name must be at most 20 characters")
        String name,

        @Min(value = 1, message = "quantity must be at least 1")
        int quantity
) {
}
