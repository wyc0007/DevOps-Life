#!/bin/bash

set -e

echo "🚀 开始部署 K8s Health Checker 到 Kubernetes 集群..."

# 检查 kubectl 是否可用
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl 未安装或不在 PATH 中"
    exit 1
fi

# 检查集群连接
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ 无法连接到 Kubernetes 集群"
    exit 1
fi

echo "✅ Kubernetes 集群连接正常"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 构建 Docker 镜像
echo "📦 构建 Docker 镜像..."
docker build -t local-harbor.esxi.shuqinkeji.cn/library/k8s-health-checker:latest -f Dockerfile .

# 检查是否需要推送到镜像仓库
# 如果集群节点无法访问本地镜像，需要推送到镜像仓库
echo "💡 提示: 如果集群节点无法访问本地镜像，请先推送到镜像仓库"
docker push local-harbor.esxi.shuqinkeji.cn/library/k8s-health-checker:latest

read -p "是否已经推送镜像到仓库或使用本地镜像? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "⏸️  部署已取消"
    exit 0
fi

# 应用 Kubernetes 资源
echo "📋 创建 Namespace..."
kubectl apply -f k8s/namespace.yaml

echo "🔑 创建 ServiceAccount 和 RBAC..."
kubectl apply -f k8s/serviceaccount.yaml

echo "⚙️  创建 ConfigMap..."
kubectl apply -f k8s/configmap.yaml

echo "💾 创建 PVC..."
kubectl apply -f k8s/pvc.yaml

echo "🚢 部署应用..."
kubectl apply -f k8s/deployment.yaml

echo "🌐 创建 Service..."
kubectl apply -f k8s/service.yaml

echo ""
echo "✅ 部署完成！"
echo ""
echo "📊 查看部署状态:"
echo "   kubectl get pods -n k8s-health-checker -l app=k8s-health-checker"
echo ""
echo "📝 查看日志:"
echo "   kubectl logs -n k8s-health-checker -l app=k8s-health-checker -f"
echo ""
echo "📂 查看输出文件:"
echo "   kubectl exec -n k8s-health-checker -it \$(kubectl get pod -n k8s-health-checker -l app=k8s-health-checker -o jsonpath='{.items[0].metadata.name}') -- ls -la /app/output/"
echo ""
echo "📥 下载输出文件:"
echo "   kubectl cp k8s-health-checker/\$(kubectl get pod -n k8s-health-checker -l app=k8s-health-checker -o jsonpath='{.items[0].metadata.name}'):/app/output/health-check-urls.verification.xlsx ./health-check-urls.verification.xlsx"
