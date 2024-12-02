#!/bin/bash

# ===========================================
# Cache-aside Pattern 실습환경 구성 스크립트
# ===========================================

# 사용법 출력
print_usage() {
    cat << EOF
사용법:
    $0 <userid>

설명:
    Cache-aside 패턴 실습을 위한 Azure 리소스를 생성합니다.
    리소스 이름이 중복되지 않도록 userid를 prefix로 사용합니다.

예제:
    $0 gappa     # gappa-cache-redis, gappa-cache-sql 등의 리소스가 생성됨

참고:
    - userid는 영문 소문자와 숫자만 사용 가능합니다.
    - 리소스는 'tiu-dgga-rg' 리소스 그룹에 생성됩니다.
    - 생성되는 리소스: Redis Cache, SQL Database, App Service
EOF
}

# 유틸리티 함수
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

check_error() {
    if [ $? -ne 0 ]; then
        log "Error: $1"
        exit 1
    fi
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

# Azure CLI 로그인 체크
check_azure_cli() {
    log "Azure CLI 로그인 상태 확인 중..."
    az account show &> /dev/null
    if [ $? -ne 0 ]; then
        log "Azure CLI 로그인이 필요합니다."
        az login
        check_error "Azure 로그인 실패"
    fi
}

# 환경 변수 설정
echo "=== 1. 환경 변수 설정 ==="
NAME="${1}-cache"
RESOURCE_GROUP="tiu-dgga-rg"
VNET_NAME="tiu-dgga-vnet"
LOCATION="koreacentral"
SUBNET_REDIS="tiu-dgga-pe-snet"
SUBNET_SQL="tiu-dgga-psql-snet"
SUBNET_APP="tiu-dgga-pri-snet"
DNS_ZONE_REDIS="privatelink.redis.cache.windows.net"
DNS_ZONE_SQL="privatelink.database.windows.net"
APP_INSIGHTS="tiu-dgga-insights"
LOG_FILE="deployment_${NAME}.log"

# SQL Server 관리자 계정 설정
SQL_ADMIN_LOGIN="sqladmin"
SQL_ADMIN_PASSWORD="P@ssw0rd$"

# Redis Cache 설정
setup_redis() {
    log "Redis Cache 리소스 생성 중..."

    # Redis Cache 생성
    az redis create \
        --name $NAME-redis \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --sku Basic \
        --vm-size c0
    check_error "Redis Cache 생성 실패"

    # Redis Private Endpoint 생성
    az network private-endpoint create \
        --name $NAME-redis-pe \
        --resource-group $RESOURCE_GROUP \
        --vnet-name $VNET_NAME \
        --subnet $SUBNET_REDIS \
        --private-connection-resource-id $(az redis show -n $NAME-redis -g $RESOURCE_GROUP --query id -o tsv) \
        --connection-name redisConnection \
        --group-id redisCache
    check_error "Redis Private Endpoint 생성 실패"
}

# SQL Database 설정
setup_sql() {
    log "SQL Database 리소스 생성 중..."

    # SQL Server 생성
    az sql server create \
        --name $NAME-sql \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --admin-user $SQL_ADMIN_LOGIN \
        --admin-password "$SQL_ADMIN_PASSWORD"
    check_error "SQL Server 생성 실패"

    # Database 생성
    az sql db create \
        --name $NAME-db \
        --resource-group $RESOURCE_GROUP \
        --server $NAME-sql \
        --service-objective Basic
    check_error "SQL Database 생성 실패"

    # SQL Server Private Endpoint 생성
    az network private-endpoint create \
        --name $NAME-sql-pe \
        --resource-group $RESOURCE_GROUP \
        --vnet-name $VNET_NAME \
        --subnet $SUBNET_SQL \
        --private-connection-resource-id $(az sql server show -n $NAME-sql -g $RESOURCE_GROUP --query id -o tsv) \
        --connection-name sqlConnection \
        --group-id sqlServer
    check_error "SQL Server Private Endpoint 생성 실패"

    # SQL Server 공개 액세스 비활성화
    az sql server update \
        --name $NAME-sql \
        --resource-group $RESOURCE_GROUP \
        --enable-public-network false
    check_error "SQL Server 공개 액세스 비활성화 실패"
}

# App Service 설정
setup_webapp() {
    log "App Service 리소스 생성 중..."

    # App Service Plan 생성
    az appservice plan create \
        --name $NAME-plan \
        --resource-group $RESOURCE_GROUP \
        --sku B1 \
        --is-linux
    check_error "App Service Plan 생성 실패"

    # Web App 생성
    az webapp create \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        --plan $NAME-plan \
        --runtime "JAVA:17-java17"
    check_error "Web App 생성 실패"

    # VNET Integration 설정
    az webapp vnet-integration add \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        --vnet $VNET_NAME \
        --subnet $SUBNET_APP
    check_error "Web App VNET Integration 실패"
}

# Private DNS 설정
setup_private_dns() {
    log "Private DNS 설정 중..."

    # Redis DNS 레코드 생성
    REDIS_PE_IP=$(az network private-endpoint show \
        --name "$NAME-redis-pe" \
        --resource-group $RESOURCE_GROUP \
        --query "customDnsConfigs[0].ipAddresses[0]" \
        --output tsv)

    az network private-dns record-set a create \
        --name "$NAME-redis" \
        --zone-name "$DNS_ZONE_REDIS" \
        --resource-group $RESOURCE_GROUP

    az network private-dns record-set a add-record \
        --record-set-name "$NAME-redis" \
        --zone-name "$DNS_ZONE_REDIS" \
        --resource-group $RESOURCE_GROUP \
        --ipv4-address $REDIS_PE_IP
    check_error "Redis DNS 레코드 생성 실패"

    # SQL DNS 레코드 생성
    SQL_PE_IP=$(az network private-endpoint show \
        --name "$NAME-sql-pe" \
        --resource-group $RESOURCE_GROUP \
        --query "customDnsConfigs[0].ipAddresses[0]" \
        --output tsv)

    az network private-dns record-set a create \
        --name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP

    az network private-dns record-set a add-record \
        --record-set-name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP \
        --ipv4-address $SQL_PE_IP
    check_error "SQL DNS 레코드 생성 실패"
}

# Web App 환경 설정
setup_webapp_config() {
    log "Web App 환경 설정 중..."

    # 연결 문자열 조회
    redis_host=$(az redis show --name $NAME-redis --resource-group $RESOURCE_GROUP --query hostName -o tsv)
    redis_key=$(az redis list-keys --name $NAME-redis --resource-group $RESOURCE_GROUP --query primaryKey -o tsv)

    sql_connection="jdbc:sqlserver://$NAME-sql.database.windows.net:1433;database=$NAME-db;user=$SQL_ADMIN_LOGIN;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30"

    ai_connection_string=$(az monitor app-insights component show --app $APP_INSIGHTS --resource-group $RESOURCE_GROUP --query connectionString -o tsv)

    # Web App 설정 적용
    az webapp config appsettings set \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        --settings \
            SPRING_DATA_REDIS_SSL_ENABLED=true \
            SPRING_DATA_REDIS_HOST="$redis_host" \
            SPRING_DATA_REDIS_PASSWORD="$redis_key" \
            SPRING_DATA_REDIS_PORT=6380 \
            SPRING_DATASOURCE_URL="$sql_connection" \
            APPLICATIONINSIGHTS_CONNECTION_STRING="$ai_connection_string"
    check_error "Web App 환경 설정 실패"
}

# 메인 실행 함수
main() {
    log "Cache-aside 패턴 실습환경 구성을 시작합니다..."

    # 사전 체크
    check_azure_cli

    # Redis와 SQL 리소스 병렬 생성
    setup_redis &
    setup_sql &
    wait

    # App Service는 순차 실행
    setup_webapp

    # Private DNS와 Web App 설정
    setup_private_dns
    setup_webapp_config

    log "모든 리소스가 성공적으로 생성되었습니다."

    # 리소스 확인
    log "=== 생성된 리소스 목록 ==="
    az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME
}

# 스크립트 시작
main