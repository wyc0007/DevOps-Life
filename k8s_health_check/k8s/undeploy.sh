#!/bin/bash

set -e

echo "🗑️  开始卸载 K8s Health Checker..."

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚢 删除 Deployment..."
kubectl delete -f "$SCRIPT_DIR/deployment.yaml" --ignore-not-found=true

echo "🌐 删除 Service..."
kubectl delete -f "$SCRIPT_DIR/service.yaml" --ignore-not-found=true

echo "💾 删除 PVC..."
kubectl delete -f "$SCRIPT_DIR/pvc.yaml" --ignore-not-found=true

echo "⚙️  删除 ConfigMap..."
kubectl delete -f "$SCRIPT_DIR/configmap.yaml" --ignore-not-found=true

echo "🔑 删除 ServiceAccount 和 RBAC..."
kubectl delete -f "$SCRIPT_DIR/serviceaccount.yaml" --ignore-not-found=true

read -p "是否删除 k8s-health-checker namespace? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "📋 删除 Namespace..."
    kubectl delete -f "$SCRIPT_DIR/namespace.yaml" --ignore-not-found=true
fi

echo ""
echo "✅ 卸载完成！"
