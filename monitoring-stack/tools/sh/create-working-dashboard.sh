#!/bin/bash
echo "🎨 创建可工作的Grafana仪表板..."
# 等待Grafana启动
sleep 5
# 检查Grafana是否运行
if ! curl -s http://localhost:3000/api/health > /dev/null; then
    echo "❌ Grafana未运行，请先启动服务"
    exit 1
fi
echo "✅ Grafana运行正常"
# 获取ClickHouse数据源UID
DATASOURCE_UID=$(curl -s -u admin:admin123 "http://localhost:3000/api/datasources/name/ClickHouse" | jq -r '.uid')

if [ "$DATASOURCE_UID" = "null" ] || [ "$DATASOURCE_UID" = "" ]; then
    echo "❌ ClickHouse数据源不存在，请先运行 make fix-grafana"
    exit 1
fi

echo "✅ 找到ClickHouse数据源，UID: $DATASOURCE_UID"
# 创建仪表板JSON
cat > /tmp/dashboard.json << EOF
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
    "title": "Prometheus ClickHouse 监控 ",
    "uid": "prometheus-clickhouse-working",
    "version": 1,
    "weekStart": ""
  },
  "overwrite": true
}
EOF

# 创建仪表板
echo "📊 创建新仪表板..."
curl -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d @/tmp/dashboard.json \
  "http://localhost:3000/api/dashboards/db"

echo ""
echo "🎉 仪表板创建完成！"
echo "🌐 访问: http://localhost:3000/d/prometheus-clickhouse-working"
echo "📊 仪表板名称: Prometheus ClickHouse 监控 "

# 清理临时文件
rm -f /tmp/dashboard.json
