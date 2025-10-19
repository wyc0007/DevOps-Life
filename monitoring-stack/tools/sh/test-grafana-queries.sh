#!/bin/bash
echo "🧪 测试Grafana查询..."
# 获取数据源UID
DATASOURCE_UID=$(curl -s -u admin:admin123 "http://localhost:3000/api/datasources/name/ClickHouse" | jq -r '.uid')

if [ "$DATASOURCE_UID" = "null" ] || [ "$DATASOURCE_UID" = "" ]; then
    echo "❌ ClickHouse数据源不存在"
    exit 1
fi
echo "✅ 数据源UID: $DATASOURCE_UID"
# 测试查询1: 总记录数
echo "📊 测试查询1: 总记录数"
curl -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d "{
    \"queries\": [
      {
        \"datasource\": {
          \"type\": \"grafana-clickhouse-datasource\",
          \"uid\": \"$DATASOURCE_UID\"
        },
        \"queryType\": \"\",
        \"rawSql\": \"SELECT count() as value FROM prometheus.prometheus_metrics\",
        \"refId\": \"A\"
      }
    ],
    \"range\": {
      \"from\": \"now-1h\",
      \"to\": \"now\"
    }
  }" \
  "http://localhost:3000/api/ds/query" | jq '.'

echo ""
echo "📊 测试查询2: 指标类型数"
curl -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d "{
    \"queries\": [
      {
        \"datasource\": {
          \"type\": \"grafana-clickhouse-datasource\",
          \"uid\": \"$DATASOURCE_UID\"
        },
        \"queryType\": \"\",
        \"rawSql\": \"SELECT count(DISTINCT metric_name) as value FROM prometheus.prometheus_metrics\",
        \"refId\": \"A\"
      }
    ],
    \"range\": {
      \"from\": \"now-1h\",
      \"to\": \"now\"
    }
  }" \
  "http://localhost:3000/api/ds/query" | jq '.'

echo ""
echo "🎉 查询测试完成！"