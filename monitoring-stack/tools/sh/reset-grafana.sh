#!/bin/bash
set -euo pipefail

echo "🔧 完全重置Grafana配置..."

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ 依赖缺失: $cmd"
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
PROMETHEUS_URL=${PROMETHEUS_URL:-http://prometheus:9090}

NODE_EXPORTER_DASHBOARD_URL="https://grafana.com/api/dashboards/16098/revisions/1/download"
NODE_EXPORTER_UID="node-exporter-dashboard-cn"
NODE_EXPORTER_TITLE="Node Exporter Dashboard CN"

TEMP_DASHBOARD=$(mktemp)
TEMP_NODE_DASHBOARD=$(mktemp)
TEMP_NODE_IMPORT=$(mktemp)
cleanup() {
    rm -f "$TEMP_DASHBOARD" "$TEMP_NODE_DASHBOARD" "$TEMP_NODE_IMPORT"
}
trap cleanup EXIT

grafana_request() {
    local method=$1
    local path=$2
    local data=${3:-}
    if [ -n "$data" ]; then
        curl -sS -X "$method" \
            -H "Content-Type: application/json" \
            -u "$GRAFANA_USER:$GRAFANA_PASS" \
            "$GRAFANA_URL$path" \
            -d "$data"
    else
        curl -sS -X "$method" \
            -u "$GRAFANA_USER:$GRAFANA_PASS" \
            "$GRAFANA_URL$path"
    fi
}

grafana_get() {
    grafana_request GET "$1"
}

grafana_post() {
    grafana_request POST "$1" "$2"
}

grafana_delete() {
    grafana_request DELETE "$1"
}

echo "⏳ 检查Grafana状态..."
sleep 2

if ! grafana_get /api/health >/dev/null; then
    echo "❌ Grafana未运行，请先启动服务"
    exit 1
fi

echo "✅ Grafana运行正常"

echo "🗑️ 删除现有ClickHouse数据源..."
grafana_delete /api/datasources/name/ClickHouse >/dev/null || true

echo "🗑️ 删除现有Prometheus数据源..."
grafana_delete /api/datasources/name/Prometheus >/dev/null || true

echo "🗑️ 删除现有仪表板..."
for DASH_UID in prometheus-clickhouse-working "$NODE_EXPORTER_UID"; do
    grafana_delete "/api/dashboards/uid/$DASH_UID" >/dev/null || true
done

echo "➕ 创建新的ClickHouse数据源..."
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

RESPONSE=$(grafana_post /api/datasources "$DATASOURCE_PAYLOAD")
DATASOURCE_UID=$(echo "$RESPONSE" | jq -r '.datasource.uid // empty')

if [ -z "$DATASOURCE_UID" ]; then
    echo "❌ 数据源创建失败"
    exit 1
fi

echo "✅ 数据源创建成功，UID: $DATASOURCE_UID"

sleep 1
HEALTH=$(grafana_get "/api/datasources/$DATASOURCE_UID/health" || echo "{\"status\":\"unknown\"}")
echo "🧪 数据源连接测试: $(echo "$HEALTH" | jq -r '.status // "unknown"')"

echo "➕ 创建新的Prometheus数据源..."
PROMETHEUS_DS_PAYLOAD=$(jq -n \
  --arg url "$PROMETHEUS_URL" \
  '{
    name: "Prometheus",
    type: "prometheus",
    url: $url,
    access: "proxy",
    isDefault: false,
    jsonData: {
      httpMethod: "GET"
    }
  }')

PROM_RESPONSE=$(grafana_post /api/datasources "$PROMETHEUS_DS_PAYLOAD")
PROMETHEUS_UID=$(echo "$PROM_RESPONSE" | jq -r '.datasource.uid // empty')

if [ -z "$PROMETHEUS_UID" ]; then
    echo "❌ Prometheus 数据源创建失败"
    exit 1
fi

echo "✅ Prometheus 数据源创建成功，UID: $PROMETHEUS_UID"

# 创建新的仪表板
if [ "${SKIP_DASHBOARD:-false}" != "true" ]; then
  echo "📊 创建新仪表板..."
  cat > "$TEMP_DASHBOARD" << EOF
{
  "dashboard": {
    "annotations": {
      "list": []
    },
    "editable": true,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 0,
    "id": null,
    "links": [],
    "liveNow": false,
    "panels": [
      {
        "datasource": {
          "type": "grafana-clickhouse-datasource",
          "uid": "$DATASOURCE_UID"
        },
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                }
              ]
            },
            "unit": "short"
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 6,
          "x": 0,
          "y": 0
        },
        "id": 1,
        "options": {
          "colorMode": "value",
          "graphMode": "area",
          "justifyMode": "auto",
          "orientation": "auto",
          "reduceOptions": {
            "calcs": [
              "lastNotNull"
            ],
            "fields": "",
            "values": false
          },
          "textMode": "auto"
        },
        "pluginVersion": "10.0.0",
        "targets": [
          {
            "datasource": {
              "type": "grafana-clickhouse-datasource",
              "uid": "$DATASOURCE_UID"
            },
            "queryType": "",
            "rawSql": "SELECT count() as value FROM prometheus.prometheus_metrics",
            "refId": "A"
          }
        ],
        "title": "总记录数",
        "type": "stat"
      },
      {
        "datasource": {
          "type": "grafana-clickhouse-datasource",
          "uid": "$DATASOURCE_UID"
        },
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                }
              ]
            },
            "unit": "short"
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 6,
          "x": 6,
          "y": 0
        },
        "id": 2,
        "options": {
          "colorMode": "value",
          "graphMode": "area",
          "justifyMode": "auto",
          "orientation": "auto",
          "reduceOptions": {
            "calcs": [
              "lastNotNull"
            ],
            "fields": "",
            "values": false
          },
          "textMode": "auto"
        },
        "pluginVersion": "10.0.0",
        "targets": [
          {
            "datasource": {
              "type": "grafana-clickhouse-datasource",
              "uid": "$DATASOURCE_UID"
            },
            "queryType": "",
            "rawSql": "SELECT count(DISTINCT metric_name) as value FROM prometheus.prometheus_metrics",
            "refId": "A"
          }
        ],
        "title": "指标类型数",
        "type": "stat"
      },
      {
        "datasource": {
          "type": "grafana-clickhouse-datasource",
          "uid": "$DATASOURCE_UID"
        },
        "fieldConfig": {
          "defaults": {
            "custom": {
              "align": "auto",
              "cellOptions": {
                "type": "auto"
              },
              "inspect": false
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                }
              ]
            }
          },
          "overrides": []
        },
        "gridPos": {
          "h": 12,
          "w": 24,
          "x": 0,
          "y": 8
        },
        "id": 3,
        "options": {
          "cellHeight": "sm",
          "footer": {
            "countRows": false,
            "fields": "",
            "reducer": [
              "sum"
            ],
            "show": false
          },
          "showHeader": true
        },
        "pluginVersion": "10.0.0",
        "targets": [
          {
            "datasource": {
              "type": "grafana-clickhouse-datasource",
              "uid": "$DATASOURCE_UID"
            },
            "queryType": "",
            "rawSql": "SELECT metric_name, value, job, instance, formatDateTime(timestamp, '%Y-%m-%d %H:%M:%S') as time FROM prometheus.prometheus_metrics ORDER BY timestamp DESC LIMIT 15",
            "refId": "A"
          }
        ],
        "title": "最新数据记录",
        "type": "table"
      }
    ],
    "refresh": "10s",
    "schemaVersion": 38,
    "style": "dark",
    "tags": [
      "prometheus",
      "clickhouse"
    ],
    "templating": {
      "list": []
    },
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "timepicker": {},
    "timezone": "",
    "title": "Prometheus ClickHouse 监控",
    "uid": "prometheus-clickhouse-working",
    "version": 1,
    "weekStart": ""
  }
}
EOF

  grafana_post /api/dashboards/db "$(cat "$TEMP_DASHBOARD")" >/dev/null
  echo ""
  echo "🎉 Grafana完全重置完成！"
  echo "🌐 访问: $GRAFANA_URL/d/prometheus-clickhouse-working"
  echo "📊 仪表板名称: Prometheus ClickHouse 监控"

  echo "📥 下载 Node Exporter 仪表板模板..."
  if curl -fsS "$NODE_EXPORTER_DASHBOARD_URL" -o "$TEMP_NODE_DASHBOARD"; then
    jq --arg uid "$NODE_EXPORTER_UID" --arg title "$NODE_EXPORTER_TITLE" \
      '.id=null | .uid=$uid | .title=$title' \
      "$TEMP_NODE_DASHBOARD" > "$TEMP_NODE_IMPORT"

    NODE_IMPORT_PAYLOAD=$(jq -n \
      --slurpfile dash "$TEMP_NODE_IMPORT" \
      '{
        dashboard: $dash[0],
        overwrite: true,
        inputs: [
          {
            name: "DS__VICTORIAMETRICS",
            type: "datasource",
            pluginId: "prometheus",
            value: "Prometheus"
          }
        ]
      }')

    grafana_post /api/dashboards/import "$NODE_IMPORT_PAYLOAD" >/dev/null
    echo "✅ 已导入 Node Exporter 仪表板，UID: $NODE_EXPORTER_UID"
    echo "🌐 访问: $GRAFANA_URL/d/$NODE_EXPORTER_UID"
  else
    echo "❌ Node Exporter 仪表板下载失败"
  fi
else
  echo "📊 跳过仪表板创建 (SKIP_DASHBOARD=true)"
fi