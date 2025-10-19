#!/bin/sh

set -e

echo "=========================================="
echo "K8s Health Checker Starting..."
echo "=========================================="
echo "Time: $(date)"
echo "KUBECONFIG: ${KUBECONFIG:-<in-cluster>}"
echo "OUTPUT_FILE: ${OUTPUT_FILE}"
echo "VERIFY_URLS: ${VERIFY_URLS}"
echo "RUN_MODE: ${RUN_MODE}"
echo "SCHEDULE_INTERVAL: ${SCHEDULE_INTERVAL}"
echo "=========================================="

# 检查 kubeconfig 文件（仅在指定了 KUBECONFIG 且不在集群内时）
if [ -n "${KUBECONFIG}" ] && [ ! -f "${KUBECONFIG}" ] && [ ! -f "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
    echo "错误: kubeconfig 文件不存在且不在 Kubernetes 集群内: ${KUBECONFIG}"
    exit 1
fi

if [ "${RUN_MODE}" = "once" ]; then
    echo "运行模式: 单次执行"
    /app/k8s-health-checker
    echo "执行完成，容器将退出"
elif [ "${RUN_MODE}" = "schedule" ]; then
    echo "运行模式: 定时执行 (间隔: ${SCHEDULE_INTERVAL} 秒)"
    while true; do
        echo ""
        echo "=========================================="
        echo "开始新的收集任务 - $(date)"
        echo "=========================================="
        /app/k8s-health-checker
        echo ""
        echo "任务完成，等待 ${SCHEDULE_INTERVAL} 秒..."
        sleep ${SCHEDULE_INTERVAL}
    done
elif [ "${RUN_MODE}" = "daemon" ]; then
    echo "运行模式: 守护进程"
    /app/k8s-health-checker
    echo "保持容器运行..."
    tail -f /dev/null
else
    echo "未知的运行模式: ${RUN_MODE}"
    exit 1
fi
