package com.telecom.cacheaside.repository;

import com.telecom.cacheaside.model.UserPlan;
import org.springframework.data.jpa.repository.JpaRepository;

public interface UserPlanRepository extends JpaRepository<UserPlan, Long> {
}
