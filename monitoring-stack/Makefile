.PHONY: help init up down logs status restart sync-clickhouse  query-clickhouse report-out-html sync-daemon-clickhouse dashboard-grafana sync-grafana reset-grafana test-grafana reset-stack reinstall
.DEFAULT_GOAL := help
# 项目名称
APP_NAME := prometheus-clickhouse

# 环境变量文件
ENV_FILE := .env
ifneq (,$(wildcard $(ENV_FILE)))
ENV_FILE_PRESENT := 1
include $(ENV_FILE)
export
endif

#docker-compose
DOCKER_COMPOSE ?= docker-compose

ifdef ENV_FILE_PRESENT
DC_ENV_FILE := --env-file $(ENV_FILE)
else
DC_ENV_FILE :=
endif

#docker-compose日志
DC_LOG_SERVICES ?= $(DOCKER_COMPOSE) ps -a
DC_LOG_ARGS ?= -f --tail=200

#工具脚本目录
Tools_DIR := tools
#sh相关脚本
create-working-dashboard-sh := $(Tools_DIR)/sh/create-working-dashboard.sh
fix-grafana-datasource-sh := $(Tools_DIR)/sh/fix-grafana-datasource.sh
reset-grafana-sh := $(Tools_DIR)/sh/reset-grafana.sh
test-grafana-queries-sh := $(Tools_DIR)/sh/test-grafana-queries.sh
#py相关脚本
prometheus-to-clickhouse-py := $(Tools_DIR)/py/prometheus-to-clickhouse.py
report-generator-py := $(Tools_DIR)/py/report-generator.py

#颜色
GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
NC     := \033[0m

#prometheus配置
define PROMETHEUS_CONFIG_TEMPLATE
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'prod'
    service: 'monitoring'

rule_files:
  - /etc/prometheus/alert-rules.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: []

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']
    scrape_interval: 15s
    metrics_path: '/metrics'
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['127.0.0.1:9100']
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'node-exporter'
      - source_labels: [__scheme__]
        target_label: scheme
        replacement: 'http'
endef
export PROMETHEUS_CONFIG_TEMPLATE

#prometheus告警规则
define PROMETHEUS_ALERT_RULES_TEMPLATE
groups:
  - name: Node Exporter
    interval: 30s
    rules:
      - alert: HighCPUUsage
        expr: (1 - avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU 使用率过高 (instance {{ $$labels.instance }})"
          description: "CPU 使用率已达到 {{ $$value | humanizePercentage }}"
      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "内存使用率过高 (instance {{ $$labels.instance }})"
          description: "内存使用率已达到 {{ $$value | humanizePercentage }}"
      - alert: LowDiskSpace
        expr: (node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes) < 0.1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "磁盘空间不足 (instance {{ $$labels.instance }})"
          description: "磁盘剩余空间不足 10%"
endef
export PROMETHEUS_ALERT_RULES_TEMPLATE

#帮助
help:
	@echo "$(BLUE)Prometheus ClickHouse 集成 - Docker容器运行$(NC)"
	@echo ""
	@echo "$(GREEN)快速开始:$(NC)"
	@echo "  make init      - 初始化服务(创建目录和配置文件,设置权限)"
	@echo "  make up        - 启动服务"
	@echo "  make status    - 查看运行状态"
	@echo "  make logs      - 查看实时日志"
	@echo "  make restart   - 重启服务"
	@echo "  make down      - 停止服务"
	@echo ""
	@echo "$(YELLOW)数据管理:$(NC)"
	@echo "  make sync-clickhouse            - 同步Prometheus数据到ClickHouse"
	@echo "  make query-clickhouse           - 查询ClickHouse中的数据"
	@echo "  make report-out-html            - 生成HTML监控报表"
	@echo "  make sync-daemon-clickhouse     - 启动定时同步守护进程-每60秒同步一次数据"
	@echo ""
	@echo "$(BLUE)扩展命令:$(NC)"
	@echo "  make sync-grafana                 - 将ClickHouse数据源配置到Grafana"
	@echo "  make test-grafana                 - 测试Grafana数据源配置"
	@echo "  make dashboard-grafana            - 创建Grafana仪表板"
	@echo "  make reset-grafana                - 重置Grafana数据源与仪表板"
	@echo "  make reset-stack                  - 卸载容器并清理数据目录"
	@echo "  make reinstall                    - 清理后重新部署整套服务"

#初始化
init:
	@echo "$(YELLOW)正在初始化Prometheus ClickHouse集成服务...$(NC)"
	@for dir in clickhouse/clickhouse_data clickhouse/clickhouse_logs clickhouse_reports_html \
		 grafana/data grafana/dashboards grafana/provisioning/datasources grafana/provisioning/dashboards \
		 prometheus/config prometheus/data; do \
		if [ ! -d "$$dir" ]; then mkdir -p "$$dir"; fi; \
	done
	@for dir in grafana/data prometheus/data clickhouse/clickhouse_data clickhouse/clickhouse_logs; do \
		if [ -d "$$dir" ]; then chmod -R 777 "$$dir"; fi; \
	done
	@if [ ! -f prometheus/config/prometheus.yml ]; then \
		printf '%s\n' "$$PROMETHEUS_CONFIG_TEMPLATE" > prometheus/config/prometheus.yml; \
	fi
	@if [ ! -f prometheus/config/alert-rules.yml ]; then \
		printf '%s\n' "$$PROMETHEUS_ALERT_RULES_TEMPLATE" > prometheus/config/alert-rules.yml; \
	fi
	@echo "$(GREEN)✓ 初始化完成$(NC)"

#启动
up: init
	@echo "$(YELLOW)正在启动Prometheus ClickHouse集成服务...$(NC)"
	@if ! $(DOCKER_COMPOSE) $(DC_ENV_FILE) up -d; then \
		echo "$(BLUE)✗ Docker Compose 启动失败，请检查日志$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ 服务启动完成$(NC)"
	@echo "$(YELLOW)等待服务启动完成-60秒...$(NC)"
	@sleep 60
	@$(MAKE) status

#日志
logs:
	@echo "$(BLUE)实时日志监控:$(NC)"
	@echo "🔍 目标服务: $(LOG_SERVICES)"
	@echo "🛠️ 追加参数: $(LOG_ARGS)"
	@$(DOCKER_COMPOSE) $(DC_ENV_FILE) logs $(LOG_ARGS) $(LOG_SERVICES)

#状态
status:
	@echo "$(BLUE)服务状态检查:$(NC)"
	@$(DOCKER_COMPOSE) $(DC_ENV_FILE) ps -a

#重启
restart:
	@echo "$(YELLOW)正在重启监控服务...$(NC)"
	@$(DOCKER_COMPOSE) $(DC_ENV_FILE) restart
	@echo "$(GREEN)✓ 服务重启完成$(NC)"

#停止
down:
	@echo "$(YELLOW)正在停止Prometheus ClickHouse集成服务...$(NC)"
	@$(DOCKER_COMPOSE) $(DC_ENV_FILE) down -v
	@echo "$(GREEN)✓ 服务已停止$(NC)"

#同步
sync-clickhouse:
	@echo "$(BLUE)同步Prometheus数据到ClickHouse...$(NC)"
	@python3 $(prometheus-to-clickhouse-py)

daemon-clickhouse:
	@echo "$(BLUE)启动定时同步守护进程...$(NC)"
	@echo "$(YELLOW)按 Ctrl+C 停止守护进程$(NC)"
	@echo "⏰ 每60秒同步一次数据..."
	@while true; do \
		echo "$(shell date '+%Y-%m-%d %H:%M:%S') - 开始数据同步..."; \
		python3 $(prometheus-to-clickhouse-py) > /dev/null 2>&1; \
		if [ $$? -eq 0 ]; then \
			echo "$(shell date '+%Y-%m-%d %H:%M:%S') - 数据同步完成"; \
		else \
			echo "$(shell date '+%Y-%m-%d %H:%M:%S') - 数据同步失败"; \
		fi; \
		sleep 60; \
	done


#查询
query-clickhouse:
	@echo "$(BLUE)查询ClickHouse中的Prometheus数据:$(NC)"
	@echo "总记录数:"
	@docker exec clickhouse-server clickhouse-client --user $${CLICKHOUSE_USER:-default} --password $${CLICKHOUSE_PASSWORD:?未设置CLICKHOUSE_PASSWORD} --query "SELECT count() FROM $${CLICKHOUSE_DB:-prometheus}.prometheus_metrics"
	@echo ""
	@echo "最新10条记录:"
	@docker exec clickhouse-server clickhouse-client --user $${CLICKHOUSE_USER:-default} --password $${CLICKHOUSE_PASSWORD:?未设置CLICKHOUSE_PASSWORD} --query "SELECT metric_name, value, job, formatDateTime(timestamp, '%Y-%m-%d %H:%M:%S') as time FROM $${CLICKHOUSE_DB:-prometheus}.prometheus_metrics ORDER BY timestamp DESC LIMIT 10"

#报表
report-out-html:
	@echo "$(BLUE)生成HTML监控报表...$(NC)"
	@python3 $(report-generator-py)

#仪表板
dashboard-grafana:
	@echo "$(BLUE)创建可工作的Grafana仪表板...$(NC)"
	@./$(create-working-dashboard-sh)
	@echo "$(BLUE)Grafana可视化仪表板:$(NC)"
	@echo "🌐 访问地址: $(YELLOW)$${GRAFANA_URL:-http://localhost:3000}$(NC)"
	@echo "👤 用户名: $(GREEN)$${GRAFANA_USER:-admin}$(NC)"
	@echo "🔑 密码: $(GREEN)$${GF_SECURITY_ADMIN_PASSWORD:?未设置GF_SECURITY_ADMIN_PASSWORD}$(NC)"
	@echo "💡 提示: 如果显示'No data'，请运行 make sync-grafana"
	@echo "📄 .env 文件位于 $(ENV_FILE)，请确保已正确填写密码"

#测试Grafana数据源配置
test-grafana:
	@echo "$(BLUE)测试Grafana数据源配置...$(NC)"	
	@GRAFANA_URL="$${GRAFANA_URL:-http://localhost:3000}" GRAFANA_USER="$${GRAFANA_USER:-admin}" GRAFANA_PASS="$${GF_SECURITY_ADMIN_PASSWORD:?未设置GF_SECURITY_ADMIN_PASSWORD}" CLICKHOUSE_URL="$${CLICKHOUSE_URL:-http://localhost:8123}" CLICKHOUSE_HOST="$${CLICKHOUSE_HOST:-localhost}" CLICKHOUSE_PORT="$${CLICKHOUSE_PORT:-8123}" CLICKHOUSE_DB="$${CLICKHOUSE_DB:-prometheus}" CLICKHOUSE_USER="$${CLICKHOUSE_USER:-default}" CLICKHOUSE_PASSWORD="$${CLICKHOUSE_PASSWORD:?未设置CLICKHOUSE_PASSWORD}" $(test-grafana-queries-sh)

#将ClickHouse数据源配置到Grafana
sync-grafana:
	@echo "$(BLUE)将ClickHouse数据源配置到Grafana...$(NC)"	
	@GRAFANA_URL="$${GRAFANA_URL:-http://localhost:3000}" GRAFANA_USER="$${GRAFANA_USER:-admin}" GRAFANA_PASS="$${GF_SECURITY_ADMIN_PASSWORD:?未设置GF_SECURITY_ADMIN_PASSWORD}" CLICKHOUSE_URL="$${CLICKHOUSE_URL:-http://localhost:8123}" CLICKHOUSE_HOST="$${CLICKHOUSE_HOST:-localhost}" CLICKHOUSE_PORT="$${CLICKHOUSE_PORT:-8123}" CLICKHOUSE_DB="$${CLICKHOUSE_DB:-prometheus}" CLICKHOUSE_USER="$${CLICKHOUSE_USER:-default}" CLICKHOUSE_PASSWORD="$${CLICKHOUSE_PASSWORD:?未设置CLICKHOUSE_PASSWORD}" $(fix-grafana-datasource-sh)


#重置
reset-grafana:
	@echo "$(BLUE)重置Grafana数据源与仪表板...$(NC)"
	@GRAFANA_URL="$${GRAFANA_URL:-http://localhost:3000}" GRAFANA_USER="$${GRAFANA_USER:-admin}" GRAFANA_PASS="$${GF_SECURITY_ADMIN_PASSWORD:?未设置GF_SECURITY_ADMIN_PASSWORD}" CLICKHOUSE_URL="$${CLICKHOUSE_URL:-http://localhost:8123}" CLICKHOUSE_HOST="$${CLICKHOUSE_HOST:-localhost}" CLICKHOUSE_PORT="$${CLICKHOUSE_PORT:-8123}" CLICKHOUSE_DB="$${CLICKHOUSE_DB:-prometheus}" CLICKHOUSE_USER="$${CLICKHOUSE_USER:-default}" CLICKHOUSE_PASSWORD="$${CLICKHOUSE_PASSWORD:?未设置CLICKHOUSE_PASSWORD}" $(reset-grafana-sh)

#卸载
reset-stack:
	@echo "$(BLUE)停止并清理监控栈...$(NC)"
	@$(DOCKER_COMPOSE) $(DC_ENV_FILE) down -v || true
	@for dir in grafana/data grafana/dashboards grafana/provisioning/datasources grafana/provisioning/dashboards \
		prometheus/data clickhouse/clickhouse_data clickhouse/clickhouse_logs clickhouse_reports_html; do \
		if [ -d "$$dir" ]; then \
			echo "  - 移除 $$dir"; \
			rm -rf "$$dir"; \
		fi; \
	done
	@$(MAKE) init

reinstall: reset-stack up