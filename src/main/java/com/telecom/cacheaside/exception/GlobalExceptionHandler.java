// src/main/java/com/telecom/cacheaside/exception/GlobalExceptionHandler.java
package com.telecom.cacheaside.exception;

import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@Slf4j
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(RuntimeException.class)
    public ResponseEntity<String> handleRuntimeException(RuntimeException e) {
        log.error("Error occurred: ", e);  // 스택 트레이스와 함께 로그 출력
        return ResponseEntity.badRequest().body(e.getMessage());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<String> handleException(Exception e) {
        log.error("Unexpected error occurred: ", e);  // 스택 트레이스와 함께 로그 출력
        return ResponseEntity.internalServerError().body("An unexpected error occurred");
    }
}
