package com.telecom.cacheaside.model;

import jakarta.persistence.*;
import lombok.Data;
import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Entity
@Table(name = "User_Plans")
public class UserPlan implements Serializable {
    @Id
    private Long userId;
    
    @Column(nullable = false)
    private String planName;
    
    private String planDetails;
    private Integer dataAmount;
    private Integer voiceMinutes;
    private Integer smsCount;
    private BigDecimal monthlyFee;
    
    @Column(name = "last_updated")
    private LocalDateTime lastUpdated;
}
