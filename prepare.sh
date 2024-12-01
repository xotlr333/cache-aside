#!/bin/bash

# 교육생별 고유 이름 설정
NAME="ondal-cache-aside"

# 리소스 그룹 및 VNET 이름 설정
RESOURCE_GROUP="tiu-dgga-rg"
VNET_NAME="tiu-dgga-vnet"

# SQL Server 관리자 계정 설정 
SQL_ADMIN_LOGIN="sqladmin"
SQL_ADMIN_PASSWORD="P@ssw0rd$"

# Azure Cache for Redis 생성
az redis create \
  --name $NAME-redis \
  --resource-group $RESOURCE_GROUP \
  --location koreacentral \
  --sku Basic \
  --vm-size c0 

# Redis의 Private Endpoint 생성
az network private-endpoint create \
  --name $NAME-redis-pe \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet tiu-dgga-pe-snet \
  --private-connection-resource-id $(az redis show -n $NAME-redis -g $RESOURCE_GROUP --query id -o tsv) \
  --connection-name redisConnection \
  --group-id redisCache

# Azure SQL Database 생성 
az sql server create \
  --name $NAME-sql \
  --resource-group $RESOURCE_GROUP \
  --location koreacentral \
  --admin-user $SQL_ADMIN_LOGIN \
  --admin-password "$SQL_ADMIN_PASSWORD"

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
  --subnet tiu-dgga-psql-snet \  
  --private-connection-resource-id $(az sql server show -n $NAME-sql -g $RESOURCE_GROUP --query id -o tsv) \
  --connection-name sqlConnection \
  --group-id sqlServer

# Public network에서 sql server 접근 금지
az sql server update \     
  --name $NAME-sql \
  --resource-group $RESOURCE_GROUP \
  --enable-public-network false

# 공용 IP 생성
az network public-ip create \
  --name $NAME-pip \
  --resource-group $RESOURCE_GROUP \
  --allocation-method Static \
  --sku Standard

# Application Gateway 생성  
az network application-gateway create \
  --name $NAME-agw \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet tiu-dgga-pub-snet \
  --capacity 1 \
  --sku Standard_v2 \
  --http-settings-cookie-based-affinity Enabled \
  --public-ip-address $NAME-pip \
  --priority 100

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
  --subnet tiu-dgga-pri-snet

# Application Insights 생성
az monitor app-insights component create \
  --app $NAME-insights \
  --location koreacentral \
  --resource-group $RESOURCE_GROUP \
  --application-type web

# Web App에 Application Insights 연결
az webapp config appsettings set \
  --name $NAME-app \
  --resource-group $RESOURCE_GROUP \
  --settings APPLICATIONINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show --app $NAME-insights --resource-group $RESOURCE_GROUP --query connectionString -o tsv)

# Private DNS에 DNS 레코드 생성 - Redis Server
REDIS_PE_IP=$(az network private-endpoint show \
  --name "$NAME-redis-pe" \
  --resource-group $RESOURCE_GROUP \
  --query "customDnsConfigs[0].ipAddresses[0]" \
  --output tsv)

az network private-dns record-set a create \
  --name "$NAME-redis" \
  --zone-name "privatelink.redis.cache.windows.net" \
  --resource-group $RESOURCE_GROUP

az network private-dns record-set a add-record \
  --record-set-name "$NAME-redis" \
  --zone-name "privatelink.redis.cache.windows.net" \
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
  --zone-name "privatelink.database.windows.net" \
  --resource-group $RESOURCE_GROUP

az network private-dns record-set a add-record \
  --record-set-name "$NAME-sql" \
  --zone-name "privatelink.database.windows.net" \
  --resource-group $RESOURCE_GROUP \
  --ipv4-address $PE_IP

# 생성된 리소스 확인 
az redis list --resource-group $RESOURCE_GROUP --output table
az webapp list --resource-group $RESOURCE_GROUP --output table  

az redis show --name $NAME-redis --resource-group $RESOURCE_GROUP \
  --query "{provisioningState:provisioningState, sslPort:sslPort, hostName:hostName}" \
  --output table

az sql server list --resource-group $RESOURCE_GROUP --output table
az sql db list --resource-group $RESOURCE_GROUP --server $NAME-sql --output table
az sql db show --name $NAME-db --server $NAME-sql --resource-group $RESOURCE_GROUP \
  --query "{name:name, status:status, maxSizeBytes:maxSizeBytes}" \
  --output table 

az network application-gateway list --resource-group $RESOURCE_GROUP --output table  

az monitor app-insights component show --app $NAME-insights --resource-group $RESOURCE_GROUP --output table

az resource list --resource-group $RESOURCE_GROUP --output table

# Network 리소스 생성 확인
az network private-endpoint list --resource-group $RESOURCE_GROUP --output table
az webapp vnet-integration list --name $NAME-app --resource-group $RESOURCE_GROUP --output table

# Web App에 서버 연결 정보 설정
redis_host=$(az redis show --name $NAME-redis --resource-group $RESOURCE_GROUP --query hostName -o tsv) 
redis_key=$(az redis list-keys --name $NAME-redis --resource-group $RESOURCE_GROUP --query primaryKey -o tsv)

sql_connection=$(az sql db show-connection-string --name $NAME-db --server $NAME-sql --client jdbc)
sql_connection="jdbc:sqlserver://$NAME-sql.database.windows.net:1433;database=$NAME-db;user=$SQL_ADMIN_LOGIN@$NAME-sql;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30"

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

echo "작업 완료"

