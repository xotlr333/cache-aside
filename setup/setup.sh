#!/bin/bash

# ===========================================
# Cache-aside Pattern 실습환경 구성 스크립트 (AKS with Redis Container)
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
    $0 gappa     # gappa-cache-aside-sql 등의 리소스가 생성됨
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
NAME="${1}-cache-aside"
RESOURCE_GROUP="tiu-dgga-rg"
VNET_NAME="tiu-dgga-vnet"
LOCATION="koreacentral"
AKS_NAME="${1}-aks"

SUBNET_REDIS="tiu-dgga-pe-snet"
SUBNET_SQL="tiu-dgga-psql-snet"
SUBNET_APP="tiu-dgga-pri-snet"

DNS_ZONE_REDIS="privatelink.redis.cache.windows.net"
DNS_ZONE_SQL="privatelink.database.windows.net"

LOG_FILE="deployment_${NAME}.log"

# Redis namespace와 설정
REDIS_NAMESPACE="redis"
REDIS_PASSWORD="P@ssw0rd$"

# SQL Server 관리자 계정 설정
SQL_ADMIN_LOGIN="sqladmin"
SQL_ADMIN_PASSWORD="P@ssw0rd$"

# Redis 컨테이너 설정
setup_redis_container() {
    log "Redis 컨테이너 설정 중..."

    # AKS 자격 증명 가져오기
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME
    check_error "AKS 자격 증명 가져오기 실패"

    # Redis namespace 생성
    kubectl create namespace $REDIS_NAMESPACE 2>/dev/null || true

    # Redis 설정 ConfigMap 생성
    kubectl create configmap redis-config -n $REDIS_NAMESPACE --from-literal=redis.conf="
maxmemory 256mb
maxmemory-policy allkeys-lru
" 2>/dev/null || true

    # Redis password secret 생성
    kubectl create secret generic redis-secret -n $REDIS_NAMESPACE \
        --from-literal=redis-password=$REDIS_PASSWORD \
        2>/dev/null || true

    # Redis deployment YAML 생성 및 적용
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME-redis
  namespace: $REDIS_NAMESPACE
spec:
  selector:
    matchLabels:
      app: redis
  replicas: 1
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:6.2
        command:
          - redis-server
          - "/redis-config/redis.conf"
          - "--requirepass"
          - "\$(REDIS_PASSWORD)"
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: redis-secret
              key: redis-password
        volumeMounts:
        - name: config
          mountPath: /redis-config
      volumes:
      - name: config
        configMap:
          name: redis-config
---
apiVersion: v1
kind: Service
metadata:
  name: $NAME-redis
  namespace: $REDIS_NAMESPACE
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
  type: LoadBalancer
EOF
    check_error "Redis 배포 실패"
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

setup_private_dns() {
    log "Private DNS 설정 중..."

    # SQL DNS Zone이 없으면 생성
    az network private-dns zone create \
        --resource-group $RESOURCE_GROUP \
        --name $DNS_ZONE_SQL \
        2>/dev/null || true

    # SQL DNS 레코드 생성
    SQL_PE_IP=$(az network private-endpoint show \
        --name "$NAME-sql-pe" \
        --resource-group $RESOURCE_GROUP \
        --query "customDnsConfigs[0].ipAddresses[0]" \
        --output tsv)

    az network private-dns record-set a create \
        --name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP \
        2>/dev/null || true

    az network private-dns record-set a add-record \
        --record-set-name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP \
        --ipv4-address $SQL_PE_IP \
        2>/dev/null || true
    check_error "SQL DNS 레코드 생성 실패"

    # Private DNS Zone을 VNET에 연결
    az network private-dns link vnet create \
        --name "$NAME-sql-link" \
        --resource-group $RESOURCE_GROUP \
        --zone-name "$DNS_ZONE_SQL" \
        --virtual-network $VNET_NAME \
        --registration-enabled false \
        2>/dev/null || true

    log "Private DNS Zone VNET 연결 완료 또는 이미 존재함"
}
#!/bin/bash

# ===========================================
# Cache-aside Pattern 실습환경 구성 스크립트 (AKS with Redis Container)
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
    $0 gappa     # gappa-cache-aside-sql 등의 리소스가 생성됨
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

# Redis 컨테이너 설정
setup_redis_container() {
    log "Redis 컨테이너 설정 중..."

    # AKS 자격 증명 가져오기
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME
    check_error "AKS 자격 증명 가져오기 실패"

    # Redis namespace 생성
    kubectl create namespace $REDIS_NAMESPACE 2>/dev/null || true

    # Redis 설정 ConfigMap 생성
    kubectl create configmap redis-config -n $REDIS_NAMESPACE --from-literal=redis.conf="
maxmemory 256mb
maxmemory-policy allkeys-lru
" 2>/dev/null || true

    # Redis password secret 생성
    kubectl create secret generic redis-secret -n $REDIS_NAMESPACE \
        --from-literal=redis-password=$REDIS_PASSWORD \
        2>/dev/null || true

    # Redis deployment YAML 생성 및 적용
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME-redis
  namespace: $REDIS_NAMESPACE
spec:
  selector:
    matchLabels:
      app: redis
  replicas: 1
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:6.2
        command:
          - redis-server
          - "/redis-config/redis.conf"
          - "--requirepass"
          - "\$(REDIS_PASSWORD)"
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: redis-secret
              key: redis-password
        volumeMounts:
        - name: config
          mountPath: /redis-config
      volumes:
      - name: config
        configMap:
          name: redis-config
---
apiVersion: v1
kind: Service
metadata:
  name: $NAME-redis
  namespace: $REDIS_NAMESPACE
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
  type: LoadBalancer
EOF
    check_error "Redis 배포 실패"
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

setup_private_dns() {
    log "Private DNS 설정 중..."

    # SQL DNS Zone이 없으면 생성
    az network private-dns zone create \
        --resource-group $RESOURCE_GROUP \
        --name $DNS_ZONE_SQL \
        2>/dev/null || true

    # SQL DNS 레코드 생성
    SQL_PE_IP=$(az network private-endpoint show \
        --name "$NAME-sql-pe" \
        --resource-group $RESOURCE_GROUP \
        --query "customDnsConfigs[0].ipAddresses[0]" \
        --output tsv)

    az network private-dns record-set a create \
        --name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP \
        2>/dev/null || true

    az network private-dns record-set a add-record \
        --record-set-name "$NAME-sql" \
        --zone-name "$DNS_ZONE_SQL" \
        --resource-group $RESOURCE_GROUP \
        --ipv4-address $SQL_PE_IP \
        2>/dev/null || true
    check_error "SQL DNS 레코드 생성 실패"

    # Private DNS Zone을 VNET에 연결
    az network private-dns link vnet create \
        --name "$NAME-sql-link" \
        --resource-group $RESOURCE_GROUP \
        --zone-name "$DNS_ZONE_SQL" \
        --virtual-network $VNET_NAME \
        --registration-enabled false \
        2>/dev/null || true

    log "Private DNS Zone VNET 연결 완료 또는 이미 존재함"
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

    # Web App VNET 통합 설정
    az webapp vnet-integration add \
      --name $NAME-app \
      --resource-group $RESOURCE_GROUP \
      --vnet $VNET_NAME \
      --subnet $SUBNET_APP
    check_error "Web App VNET 통합 설정 실패"
}

# Web App 환경 설정
setup_webapp_config() {
    log "Web App 환경 설정 중..."

    # Redis 서비스의 공용 IP 조회 (LoadBalancer IP)
    for i in {1..30}; do
        REDIS_HOST=$(kubectl get svc $NAME-redis -n $REDIS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [ ! -z "$REDIS_HOST" ]; then
            break
        fi
        log "LoadBalancer IP를 기다리는 중... (${i}/30)"
        sleep 10
    done

    if [ -z "$REDIS_HOST" ]; then
        log "Error: Redis LoadBalancer IP를 가져오는데 실패했습니다."
        exit 1
    fi

    log "Redis LoadBalancer IP: $REDIS_HOST"

    # SQL 연결 문자열
    sql_connection="jdbc:sqlserver://$NAME-sql.database.windows.net:1433;database=$NAME-db;user=$SQL_ADMIN_LOGIN;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30"

    # Web App 설정 적용
    az webapp config appsettings set \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        --settings \
            SPRING_DATA_REDIS_HOST="$REDIS_HOST" \
            SPRING_DATA_REDIS_PASSWORD="$REDIS_PASSWORD" \
            SPRING_DATA_REDIS_PORT=6379 \
            SPRING_DATASOURCE_URL="$sql_connection"
    check_error "Web App 환경 설정 실패"
}

# 메인 실행 함수
main() {
    log "Cache-aside 패턴 실습환경 구성을 시작합니다..."

    # 사전 체크
    check_azure_cli

    # 리소스 생성
    setup_redis_container
    setup_sql
    setup_private_dns
    setup_webapp
    setup_webapp_config

    log "모든 리소스가 성공적으로 생성되었습니다."
    # 생성 리소스 확인
    log "=== 생성 리소스 확인 ==="
    az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME

    # Redis 정보 출력
    log "=== Redis 연결 정보 ==="
    log "Host: $REDIS_HOST"
    log "Port: 6379"
    log "Password: $REDIS_PASSWORD"

    # SQL Server 정보 출력
    log "=== SQL Server 연결 정보 ==="
    log "Server: $NAME-sql.database.windows.net"
    log "Port: 1433"
    log "Database: $NAME-db"
    log "Username: $SQL_ADMIN_LOGIN"

    # Web App 정보 출력
    APP_HOST=$(az webapp show \
    --name $NAME-app \
    --query defaultHostName \
    --resource-group=$RESOURCE_GROUP -o tsv)
    KUDU_HOST=$(az webapp deployment list-publishing-profiles \
      --name $NAME-app \
      --query "[?publishMethod=='MSDeploy'].publishUrl" \
      --resource-group=$RESOURCE_GROUP -o tsv)

    log "=== Web App 연결 정보 ==="
    log "Host: $APP_HOST"
    log "Swagger: https://$APP_HOST/swagger-ui.html"
    log "Kudu: https://$KUDU_HOST"

    log "=== 기본값 설정 ==="
    log "az configure --defaults group=$RESOURCE_GROUP"
    log "az configure --defaults web=$NAME-app"

    log "=== 배포 가이드 ==="
    log "az webapp deploy --type jar --src-path={jar path}"
    log "az webapp log tail"

}

# 스크립트 시작
main

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

    # Web App VNET 통합 설정
    az webapp vnet-integration add \
      --name $NAME-app \
      --resource-group $RESOURCE_GROUP \
      --vnet $VNET_NAME \
      --subnet $SUBNET_APP
    check_error "Web App VNET 통합 설정 실패"
}

# Web App 환경 설정
setup_webapp_config() {
    log "Web App 환경 설정 중..."

    # Redis 서비스의 공용 IP 조회 (LoadBalancer IP)
    for i in {1..30}; do
        REDIS_HOST=$(kubectl get svc $NAME-redis -n $REDIS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [ ! -z "$REDIS_HOST" ]; then
            break
        fi
        log "LoadBalancer IP를 기다리는 중... (${i}/30)"
        sleep 10
    done

    if [ -z "$REDIS_HOST" ]; then
        log "Error: Redis LoadBalancer IP를 가져오는데 실패했습니다."
        exit 1
    fi

    log "Redis LoadBalancer IP: $REDIS_HOST"

    # SQL 연결 문자열
    sql_connection="jdbc:sqlserver://$NAME-sql.database.windows.net:1433;database=$NAME-db;user=$SQL_ADMIN_LOGIN;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30"

    # Web App 설정 적용
    az webapp config appsettings set \
        --name $NAME-app \
        --resource-group $RESOURCE_GROUP \
        --settings \
            SPRING_DATA_REDIS_HOST="$REDIS_HOST" \
            SPRING_DATA_REDIS_PASSWORD="$REDIS_PASSWORD" \
            SPRING_DATA_REDIS_PORT=6379 \
            SPRING_DATASOURCE_URL="$sql_connection"
    check_error "Web App 환경 설정 실패"
}

# 메인 실행 함수
main() {
    log "Cache-aside 패턴 실습환경 구성을 시작합니다..."

    # 사전 체크
    check_azure_cli

    # 리소스 생성
    setup_redis_container
    setup_sql
    setup_private_dns
    setup_webapp
    setup_webapp_config

    log "모든 리소스가 성공적으로 생성되었습니다."
    # 생성 리소스 확인
    log "=== 생성 리소스 확인 ==="
    az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME

    # Redis 정보 출력
    log "=== Redis 연결 정보 ==="
    log "Host: $REDIS_HOST"
    log "Port: 6379"
    log "Password: $REDIS_PASSWORD"

    # SQL Server 정보 출력
    log "=== SQL Server 연결 정보 ==="
    log "Server: $NAME-sql.database.windows.net"
    log "Port: 1433"
    log "Database: $NAME-db"
    log "Username: $SQL_ADMIN_LOGIN"

    # Web App 정보 출력
    APP_HOST=$(az webapp show \
    --name $NAME-app \
    --query defaultHostName \
    --resource-group=$RESOURCE_GROUP -o tsv)
    KUDU_HOST=$(az webapp deployment list-publishing-profiles \
      --name $NAME-app \
      --query "[?publishMethod=='MSDeploy'].publishUrl" \
      --resource-group=$RESOURCE_GROUP -o tsv)

    log "=== Web App 연결 정보 ==="
    log "Host: $APP_HOST"
    log "Swagger: https://$APP_HOST/swagger-ui.html"
    log "Kudu: https://$KUDU_HOST"

    log "=== 기본값 설정 ==="
    log "az configure --defaults group=$RESOURCE_GROUP"
    log "az configure --defaults web=$NAME-app"

    log "=== 배포 가이드 ==="
    log "az webapp deploy --type jar --src-path={jar path}"
    log "az webapp log tail"

}

# 스크립트 시작
main
