#!/bin/bash

# 교육생별 고유 이름 설정
NAME="ondal-cache-aside"

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

# SQL Server 관리자 계정 설정
SQL_ADMIN_LOGIN="sqladmin"
SQL_ADMIN_PASSWORD="P@ssw0rd$"

# Azure Cache for Redis 생성
az redis create \
  --name $NAME-redis \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic \
  --vm-size c0

# Redis의 Private Endpoint 생성
az network private-endpoint create \
  --name $NAME-redis-pe \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_REDIS \
  --private-connection-resource-id $(az redis show -n $NAME-redis -g $RESOURCE_GROUP --query id -o tsv) \
  --connection-name redisConnection \
  --group-id redisCache

# Azure SQL Database 생성
az sql server create \
  --name $NAME-sql \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $SQL_ADMIN_LOGIN \
  --admin-password "$SQL_ADMIN_PASSWORD"

# SQL Server DB 생성
az sql db create \
  --name $NAME-db \
  --resource-group $RESOURCE_GROUP \
  --server $NAME-sql \
  --service-objective Basic

# SQL Server의 Private Endpoint 생성
az network private-endpoint create \
  --name $NAME-sql-pe \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_SQL \
  --private-connection-resource-id $(az sql server show -n $NAME-sql -g $RESOURCE_GROUP --query id -o tsv) \
  --connection-name sqlConnection \
  --group-id sqlServer


# Public network에서 sql server 접근 금지
az sql server update \
  --name $NAME-sql \
  --resource-group $RESOURCE_GROUP \
  --enable-public-network false



# App Service Plan 생성
az appservice plan create \
  --name $NAME-plan \
  --resource-group $RESOURCE_GROUP \
  --sku B1 \
  --is-linux

# Web App 생성
az webapp create \
  --name $NAME-app \
  --resource-group $RESOURCE_GROUP \
  --plan $NAME-plan \
  --runtime "JAVA:17-java17"

# VNET 통합 설정
az webapp vnet-integration add \
  --name $NAME-app \
  --resource-group $RESOURCE_GROUP \
  --vnet $VNET_NAME \
  --subnet $SUBNET_APP

# Private DNS에 DNS 레코드 생성 - Redis Server
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

# Private DNS에 DNS 레코드 생성 - SQL Server
PE_IP=$(az network private-endpoint show \
  --name "$NAME-sql-pe" \
  --resource-group $RESOURCE_GROUP \
  --query "customDnsConfigs[0].ipAddresses[0]" \
  --output tsv)

az network private-dns record-set a create \
  --name "$NAME-sql" \
  --zone-name "$DNS_ZONE_REDIS_SQL" \
  --resource-group $RESOURCE_GROUP

az network private-dns record-set a add-record \
  --record-set-name "$NAME-sql" \
  --zone-name "$DNS_ZONE_REDIS_SQL" \
  --resource-group $RESOURCE_GROUP \
  --ipv4-address $PE_IP


# 생성된 리소스 확인
az resource list --resource-group $RESOURCE_GROUP --output table | grep $NAME

# Web App에 서버 연결 정보 설정
redis_host=$(az redis show --name $NAME-redis --resource-group $RESOURCE_GROUP --query hostName -o tsv)
redis_key=$(az redis list-keys --name $NAME-redis --resource-group $RESOURCE_GROUP --query primaryKey -o tsv)

sql_connection=$(az sql db show-connection-string --name $NAME-db --server $NAME-sql --client jdbc)
sql_connection="jdbc:sqlserver://$NAME-sql.database.windows.net:1433;database=$NAME-db;user=$SQL_ADMIN_LOGIN;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30"

ai_connection_string=$(az monitor app-insights component show --app $NAME-insights --resource-group $RESOURCE_GROUP --query connectionString -o tsv)

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

az webapp config appsettings list --name $NAME-app --resource-group $RESOURCE_GROUP -o table

# Web App에 Application Insights 연결
az webapp config appsettings set \
  --name $NAME-app \
  --resource-group $RESOURCE_GROUP \
  --settings APPLICATIONINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show --app $APP_INSIGHTS --resource-group $RESOURCE_GROUP --query connectionString -o tsv)

echo "작업 완료"
