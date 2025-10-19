#!/bin/bash
set -euo pipefail

echo "修复Grafana ClickHouse数据源配置..."

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "依赖缺失: $cmd"
        exit 1
    fi
done

GRAFANA_URL=${GRAFANA_URL:-http://localhost:3000}
GRAFANA_USER=${GRAFANA_USER:-admin}
GRAFANA_PASS=${GRAFANA_PASS:-admin123}
CLICKHOUSE_URL=${CLICKHOUSE_URL:-http://localhost:8123}
CLICKHOUSE_HOST=${CLICKHOUSE_HOST:-localhost}
CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-8123}
CLICKHOUSE_DB=${CLICKHOUSE_DB:-prometheus}
CLICKHOUSE_USER=${CLICKHOUSE_USER:-default}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD:-02UAihxpMDFDzqZf}

echo "等待Grafana启动..."
sleep 5

if ! curl -sSf "$GRAFANA_URL/api/health" >/dev/null; then
    echo "Grafana未运行，请先启动服务"
    exit 1
fi

echo "Grafana运行正常"
echo "删除现有ClickHouse数据源..."
curl -sS -X DELETE \
  -H "Content-Type: application/json" \
  -u "$GRAFANA_USER:$GRAFANA_PASS" \
  "$GRAFANA_URL/api/datasources/name/ClickHouse" >/dev/null || true

echo "创建新的ClickHouse数据源..."
DATASOURCE_PAYLOAD=$(jq -n \
  --arg url "$CLICKHOUSE_URL" \
  --arg host "$CLICKHOUSE_HOST" \
  --argjson port "$CLICKHOUSE_PORT" \
  --arg user "$CLICKHOUSE_USER" \
  --arg db "$CLICKHOUSE_DB" \
  --arg password "$CLICKHOUSE_PASSWORD" '
  {
    name: "ClickHouse",
    type: "grafana-clickhouse-datasource",
    url: $url,
    access: "proxy",
    isDefault: true,
    jsonData: {
      host: $host,
      port: $port,
      username: $user,
      defaultDatabase: $db,
      protocol: "http",
      secure: false,
      tlsSkipVerify: true
    },
    secureJsonData: {
      password: $password
    }
  }
')

curl -sS -X POST \
  -H "Content-Type: application/json" \
  -u "$GRAFANA_USER:$GRAFANA_PASS" \
  -d "$DATASOURCE_PAYLOAD" \
  "$GRAFANA_URL/api/datasources" >/dev/null

echo ""
echo "测试数据源连接..."
sleep 2

DATASOURCE=$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/datasources/name/ClickHouse")
DATASOURCE_ID=$(echo "$DATASOURCE" | jq -r '.id // empty')

if [ -n "$DATASOURCE_ID" ]; then
    echo "数据源创建成功，ID: $DATASOURCE_ID"
    curl -sS -X POST \
      -H "Content-Type: application/json" \
      -u "$GRAFANA_USER:$GRAFANA_PASS" \
      "$GRAFANA_URL/api/datasources/$DATASOURCE_ID/health" | jq '.'

    echo ""
    echo "Grafana ClickHouse数据源配置完成！"
    echo "访问 $GRAFANA_URL 查看仪表板"
    echo "用户名: $GRAFANA_USER"
else
    echo "数据源创建失败"
    exit 1
fi
