#!/bin/bash

# ===========================================
# Cache-aside Pattern 실습환경 정리 스크립트
# ===========================================

# 사용법 출력
print_usage() {
    cat << EOF
사용법:
    $0 <userid>

설명:
    Cache-aside 패턴 실습을 위해 생성한 모든 Azure 리소스를 삭제합니다.

예제:
    $0 gappa     # gappa-cache-aside로 시작하는 모든 리소스 삭제
EOF
}

# 유틸리티 함수
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
}

# userid 파라미터 체크
if [ $# -ne 1 ]; then
    print_usage
    exit 1
fi

# userid 유효성 검사
if [[ ! $1 =~ ^[a-z0-9]+$ ]]; then
    echo "Error: userid는 영문 소문자와 숫자만 사용할 수 있습니다."
    exit 1
fi

# 환경 변수 설정
NAME="${1}-cache-aside"
RESOURCE_GROUP="tiu-dgga-rg"
AKS_NAME="${1}-aks"
REDIS_NAMESPACE="redis"

# 리소스 삭제 전 확인
confirm() {
    read -p "모든 리소스를 삭제하시겠습니까? (y/N) " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            echo "작업을 취소합니다."
            exit 1
            ;;
    esac
}

# AKS의 Redis 리소스 삭제
cleanup_redis_k8s() {
    log "AKS의 Redis 리소스 삭제 중..."

    # AKS 자격 증명 가져오기
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

    # Redis 관련 리소스 삭제
    kubectl delete service $NAME-redis -n $REDIS_NAMESPACE 2>/dev/null || true
    kubectl delete deployment $NAME-redis -n $REDIS_NAMESPACE 2>/dev/null || true
    kubectl delete configmap redis-config -n $REDIS_NAMESPACE 2>/dev/null || true
    kubectl delete secret redis-secret -n $REDIS_NAMESPACE 2>/dev/null || true

    log "Redis 리소스 삭제 완료"
}

# SQL Database 리소스 삭제
cleanup_sql() {
    log "SQL Database 리소스 삭제 중..."

    # Private Endpoint 삭제
    az network private-endpoint delete \
        --name $NAME-sql-pe \
        --resource-group $RESOURCE_GROUP \
        2>/dev/null || true

    # Database 삭제
    az sql db delete \
        --name $NAME-db \
        --resource-group $RESOURCE_GROUP \
        --server $NAME-sql \
        --yes \
        2>/dev/null || true

    # SQL Server 삭제
    az sql server delete \
        --name $NAME-sql \
        --resource-group $RESOURCE_GROUP \
        --yes \
        2>/dev/null || true

    log "SQL Database 리소스 삭제 완료"
}

# App Service 리소스 삭제
cleanup_webapp() {
    log "App Service 리소스 삭제 중..."

    # Web App VNET Integration 제거
    az webapp vnet-integration remove \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        2>/dev/null || true

    # Web App 삭제
    az webapp delete \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        2>/dev/null || true

    # App Service Plan 삭제
    az appservice plan delete \
        --name $NAME-plan \
        --resource-group $RESOURCE_GROUP \
        --yes \
        2>/dev/null || true

    log "App Service 리소스 삭제 완료"
}

# Private DNS 레코드 및 링크 삭제
cleanup_private_dns() {
    log "Private DNS 설정 삭제 중..."

    # SQL Server DNS 레코드 삭제
    az network private-dns record-set a delete \
        --name "$NAME-sql" \
        --zone-name privatelink.database.windows.net \
        --resource-group $RESOURCE_GROUP \
        --yes \
        2>/dev/null || true

    az network private-dns link vnet delete \
        --name "$NAME-sql-link" \
        --zone-name privatelink.database.windows.net \
        --resource-group $RESOURCE_GROUP \
        --yes \
        2>/dev/null || true

    log "Private DNS 설정 삭제 완료"
}

# 메인 실행 함수
main() {
    log "리소스 정리를 시작합니다..."

    # 사전 체크
    confirm

    # 리소스 삭제
    cleanup_redis_k8s
    cleanup_sql
    cleanup_webapp
    cleanup_private_dns

    log "모든 리소스가 정리되었습니다."

    # 남은 리소스 확인
    log "=== 남은 리소스 확인 ==="
    az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME || echo "남은 리소스 없음"
}

# 스크립트 시작
main
