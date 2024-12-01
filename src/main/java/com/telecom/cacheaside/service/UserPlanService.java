package com.telecom.cacheaside.service;

import com.telecom.cacheaside.model.UserPlan;
import com.telecom.cacheaside.repository.UserPlanRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDateTime;
import java.util.Optional;

@Slf4j
@Service
@RequiredArgsConstructor
public class UserPlanService {
    private final UserPlanRepository userPlanRepository;
    private final CacheService cacheService;

    @Transactional(readOnly = true)
    public Optional<UserPlan> getUserPlan(Long userId) {
        // 1. 캐시에서 조회
        UserPlan cachedPlan = (UserPlan) cacheService.get(userId);
        if (cachedPlan != null) {
            log.debug("Cache hit for user {}", userId);
            return Optional.of(cachedPlan);
        }

        // 2. Cache miss: DB에서 조회
        log.debug("Cache miss for user {}, fetching from database", userId);
        Optional<UserPlan> userPlan = userPlanRepository.findById(userId);
        
        // 3. DB에서 찾았으면 캐시에 저장
        userPlan.ifPresent(plan -> cacheService.put(userId, plan));
        
        return userPlan;
    }

    @Transactional
    public UserPlan updateUserPlan(Long userId, UserPlan updatedPlan) {
        // userId로 조회를 시도하고, 없으면 새로운 객체 생성
        UserPlan plan = userPlanRepository.findById(userId)
                .orElseGet(() -> {
                    UserPlan newPlan = new UserPlan();
                    newPlan.setUserId(userId);
                    return newPlan;
                });

        // 데이터 업데이트
        plan.setPlanName(updatedPlan.getPlanName());
        plan.setPlanDetails(updatedPlan.getPlanDetails());
        plan.setDataAmount(updatedPlan.getDataAmount());
        plan.setVoiceMinutes(updatedPlan.getVoiceMinutes());
        plan.setSmsCount(updatedPlan.getSmsCount());
        plan.setMonthlyFee(updatedPlan.getMonthlyFee());
        plan.setLastUpdated(LocalDateTime.now());

        // DB 업데이트
        UserPlan savedPlan = userPlanRepository.save(plan);
        
        // 캐시 무효화
        cacheService.evict(userId);
        
        return savedPlan;
    }
}
