#!/bin/bash

echo "=== 리소스 삭제 스크립트 시작 ==="

echo "=== 1. 환경 변수 설정 ==="
# 교육생별 고유 이름 설정 (생성 시 사용한 것과 동일해야 합니다)
NAME="gappa-cache-aside"

# 리소스 그룹, VNET 이름 등 공통 변수
RESOURCE_GROUP="tiu-dgga-rg"
VNET_NAME="tiu-dgga-vnet"
LOCATION="koreacentral"
SUBNET_REDIS="tiu-dgga-pe-snet"
SUBNET_SQL="tiu-dgga-psql-snet"
SUBNET_APP="tiu-dgga-pri-snet"
DNS_ZONE_REDIS="privatelink.redis.cache.windows.net"
DNS_ZONE_SQL="privatelink.database.windows.net"
APP_INSIGHTS="tiu-dgga-insights"

echo "=== 2. Private DNS 레코드 삭제 ==="
echo "2-1. Redis Private DNS 레코드 삭제"
az network private-dns record-set a delete \
  --name "$NAME-redis" \
  --zone-name "$DNS_ZONE_REDIS" \
  --resource-group $RESOURCE_GROUP --yes

echo "2-2. SQL Server Private DNS 레코드 삭제"
az network private-dns record-set a delete \
  --name "$NAME-sql" \
  --zone-name "$DNS_ZONE_SQL" \
  --resource-group $RESOURCE_GROUP --yes

echo "=== 3. Private Endpoint 삭제 ==="
echo "3-1. Redis Private Endpoint 삭제"
az network private-endpoint delete \
  --name "$NAME-redis-pe" \
  --resource-group $RESOURCE_GROUP

echo "3-2. SQL Server Private Endpoint 삭제"
az network private-endpoint delete \
  --name "$NAME-sql-pe" \
  --resource-group $RESOURCE_GROUP

echo "=== 4. Web App 및 App Service Plan 삭제 ==="
echo "4-1. Web App VNET 통합 해제"
az webapp vnet-integration remove \
  --name "$NAME-app" \
  --resource-group $RESOURCE_GROUP

echo "4-2. Web App 삭제"
az webapp delete \
  --name "$NAME-app" \
  --resource-group $RESOURCE_GROUP

echo "4-3. App Service Plan 삭제"
az appservice plan delete \
  --name "$NAME-plan" \
  --resource-group $RESOURCE_GROUP --yes

echo "=== 5. Azure SQL Database 및 SQL Server 삭제 ==="
echo "5-1. SQL Database 삭제"
az sql db delete \
  --name "$NAME-db" \
  --server "$NAME-sql" \
  --resource-group $RESOURCE_GROUP --yes

echo "5-2. SQL Server 삭제"
az sql server delete \
  --name "$NAME-sql" \
  --resource-group $RESOURCE_GROUP --yes

echo "=== 6. Azure Redis Cache 삭제 ==="
az redis delete \
  --name "$NAME-redis" \
  --resource-group $RESOURCE_GROUP --yes

echo "=== 7. 리소스 삭제 확인 ==="
az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME

echo "모든 지정된 리소스가 삭제되었습니다."

echo "=== 스크립트 완료 ==="
