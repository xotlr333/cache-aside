package com.telecom.cacheaside.controller;

import com.telecom.cacheaside.model.UserPlan;
import com.telecom.cacheaside.service.UserPlanService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@Tag(name = "User Plan API", description = "사용자 요금제 관리 API")
@RestController
@RequestMapping("/api/plans")
@RequiredArgsConstructor
public class UserPlanController {
    private final UserPlanService userPlanService;

    @Operation(summary = "요금제 조회", description = "사용자 ID로 요금제 정보를 조회합니다.")
    @GetMapping("/{userId}")
    public ResponseEntity<UserPlan> getUserPlan(@PathVariable Long userId) {
        return userPlanService.getUserPlan(userId)
            .map(ResponseEntity::ok)
            .orElse(ResponseEntity.notFound().build());
    }

    @Operation(summary = "요금제 수정", description = "사용자 요금제 정보를 수정합니다.")
    @PutMapping("/{userId}")
    public ResponseEntity<UserPlan> updateUserPlan(
            @PathVariable Long userId,
            @RequestBody UserPlan userPlan) {
        return ResponseEntity.ok(userPlanService.updateUserPlan(userId, userPlan));
    }
}
