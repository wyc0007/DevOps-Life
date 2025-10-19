.PHONY: help deploy undeploy logs status download restart

.DEFAULT_GOAL := help

APP_NAME := k8s-health-checker
NAMESPACE := k8s-health-checker
DOCKER_IMAGE := local-harbor.esxi.shuqinkeji.cn/library/k8s-health-checker:latest
GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
RED    := \033[0;31m
NC     := \033[0m

help:
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║        Kubernetes 健康检查器 - 可用命令                    ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "$(YELLOW)部署管理:$(NC)"
	@echo "  $(GREEN)deploy$(NC)      - 部署到 Kubernetes 集群"
	@echo "  $(GREEN)undeploy$(NC)    - 从 Kubernetes 集群卸载"
	@echo "  $(GREEN)restart$(NC)     - 重启 Pod"
	@echo ""
	@echo "$(YELLOW)监控查看:$(NC)"
	@echo "  $(GREEN)status$(NC)      - 查看 Pod 状态"
	@echo "  $(GREEN)logs$(NC)        - 查看实时日志"
	@echo "  $(GREEN)download$(NC)    - 下载输出文件"
	@echo ""
	@echo "$(BLUE)示例用法:$(NC)"
	@echo "  make deploy      # 部署服务"
	@echo "  make status      # 查看状态"
	@echo "  make logs        # 查看日志"
	@echo "  make download    # 下载结果文件"
	@echo ""

# 部署到 Kubernetes
deploy:
	@echo "$(YELLOW)正在部署到 Kubernetes 集群...$(NC)"
	@./k8s/deploy.sh

# 从 Kubernetes 卸载
undeploy:
	@echo "$(YELLOW)正在从 Kubernetes 集群卸载...$(NC)"
	@./k8s/undeploy.sh

# 查看实时日志
logs:
	@echo "$(YELLOW)正在查看 Pod 日志...$(NC)"
	@kubectl logs -n $(NAMESPACE) -l app=$(APP_NAME) -f

# 查看 Pod 状态
status:
	@echo "$(YELLOW)正在查看 Pod 状态...$(NC)"
	@echo ""
	@echo "$(BLUE)Pods:$(NC)"
	@kubectl get pods -n $(NAMESPACE) -l app=$(APP_NAME)
	@echo ""
	@echo "$(BLUE)PVC:$(NC)"
	@kubectl get pvc -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)Service:$(NC)"
	@kubectl get svc -n $(NAMESPACE)

# 重启 Pod
restart:
	@echo "$(YELLOW)正在重启 Pod...$(NC)"
	@kubectl rollout restart deployment/$(APP_NAME) -n $(NAMESPACE)
	@echo "$(GREEN)✓ 重启命令已发送$(NC)"

# 下载输出文件
download:
	@echo "$(YELLOW)正在下载输出文件...$(NC)"
	@POD_NAME=$$(kubectl get pod -n $(NAMESPACE) -l app=$(APP_NAME) -o jsonpath='{.items[0].metadata.name}'); \
	if [ -z "$$POD_NAME" ]; then \
		echo "$(RED)✗ 未找到运行中的 Pod$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)从 Pod $$POD_NAME 下载文件...$(NC)"; \
	mkdir -p ./output; \
	kubectl cp $(NAMESPACE)/$$POD_NAME:/app/output/health-check-urls ./output/health-check-urls 2>/dev/null || true; \
	kubectl cp $(NAMESPACE)/$$POD_NAME:/app/output/health-check-urls.verification ./output/health-check-urls.verification 2>/dev/null || true; \
	kubectl cp $(NAMESPACE)/$$POD_NAME:/app/output/health-check-urls.verification.xlsx ./output/health-check-urls.verification.xlsx 2>/dev/null || true; \
	echo "$(GREEN)✓ 文件已下载到 ./output/ 目录$(NC)"
	@echo ""
	@ls -lh ./output/ 2>/dev/null || true
