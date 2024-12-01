package com.telecom.cacheaside.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.telecom.cacheaside.model.UserPlan;
import lombok.RequiredArgsConstructor;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.concurrent.TimeUnit;

@Service
@RequiredArgsConstructor
public class CacheService {
    private final RedisTemplate<String, Object> redisTemplate;
    private final ObjectMapper objectMapper;  // ObjectMapper 주입
    private static final String CACHE_KEY_PREFIX = "userplan:";
    private static final long CACHE_TTL_MINUTES = 10;

    public void put(Long userId, Object data) {
        String key = CACHE_KEY_PREFIX + userId;
        redisTemplate.opsForValue().set(key, data, CACHE_TTL_MINUTES, TimeUnit.MINUTES);
    }

    public UserPlan get(Long userId) {  // 반환 타입을 UserPlan으로 변경
        Object value = redisTemplate.opsForValue().get(CACHE_KEY_PREFIX + userId);
        if (value instanceof LinkedHashMap) {
            return objectMapper.convertValue(value, UserPlan.class);
        }
        return (UserPlan) value;
    }

    public void evict(Long userId) {
        redisTemplate.delete(CACHE_KEY_PREFIX + userId);
    }
}

