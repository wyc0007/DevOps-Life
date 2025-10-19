#!/usr/bin/env python3
"""
简单的Prometheus到ClickHouse数据同步脚本
定期从Prometheus获取指标数据并写入ClickHouse
"""

import os
import requests
import json
import time
from datetime import datetime
import subprocess
import sys

# 配置
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://localhost:9090")
CLICKHOUSE_HOST = os.getenv("CLICKHOUSE_HOST", "localhost")
CLICKHOUSE_PORT = os.getenv("CLICKHOUSE_PORT", "8123")
CLICKHOUSE_USER = os.getenv("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.getenv("CLICKHOUSE_PASSWORD", "02UAihxpMDFDzqZf")
CLICKHOUSE_DATABASE = os.getenv("CLICKHOUSE_DB", "prometheus")

def init_clickhouse():
    """初始化ClickHouse数据库和表"""
    print("🔧 初始化ClickHouse数据库...")
    
    # 创建数据库
    cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "CREATE DATABASE IF NOT EXISTS {CLICKHOUSE_DATABASE}" """
    subprocess.run(cmd, shell=True, capture_output=True)
    
    # 创建表
    create_table_sql = f"""
    CREATE TABLE IF NOT EXISTS {CLICKHOUSE_DATABASE}.prometheus_metrics (
        timestamp DateTime64(3),
        metric_name String,
        value Float64,
        labels String,
        job String DEFAULT '',
        instance String DEFAULT ''
    ) ENGINE = MergeTree()
    PARTITION BY toYYYYMM(timestamp)
    ORDER BY (metric_name, timestamp)
    TTL timestamp + INTERVAL 30 DAY
    SETTINGS index_granularity = 8192
    """
    
    cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "{create_table_sql}" """
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        print("✅ ClickHouse表创建成功")
    else:
        print(f"❌ ClickHouse表创建失败: {result.stderr}")

def get_prometheus_metrics():
    """从Prometheus获取指标数据"""
    try:
        # 获取一些基础指标
        metrics_queries = [
            "up",
            "prometheus_tsdb_head_samples_appended_total",
            "node_cpu_seconds_total",
            "process_resident_memory_bytes"
        ]
        
        all_metrics = []
        
        for query in metrics_queries:
            url = f"{PROMETHEUS_URL}/api/v1/query"
            params = {"query": query}
            
            response = requests.get(url, params=params, timeout=10)
            if response.status_code == 200:
                data = response.json()
                if data["status"] == "success":
                    for result in data["data"]["result"]:
                        metric = {
                            "timestamp": time.time(),
                            "metric_name": result["metric"].get("__name__", query),
                            "value": float(result["value"][1]),
                            "labels": json.dumps(result["metric"]),
                            "job": result["metric"].get("job", ""),
                            "instance": result["metric"].get("instance", "")
                        }
                        all_metrics.append(metric)
        
        return all_metrics
        
    except Exception as e:
        print(f"❌ 获取Prometheus指标失败: {e}")
        return []

def write_to_clickhouse(metrics):
    """将指标数据写入ClickHouse"""
    if not metrics:
        print("⚠️ 没有指标数据需要写入")
        return
    
    try:
        # 准备INSERT语句
        values = []
        for metric in metrics:
            timestamp = datetime.fromtimestamp(metric["timestamp"]).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            value = metric["value"]
            metric_name = metric["metric_name"].replace("'", "\\'")
            labels = metric["labels"].replace("'", "\\'")
            job = metric["job"].replace("'", "\\'")
            instance = metric["instance"].replace("'", "\\'")
            
            values.append(f"('{timestamp}', '{metric_name}', {value}, '{labels}', '{job}', '{instance}')")
        
        insert_sql = f"""
        INSERT INTO {CLICKHOUSE_DATABASE}.prometheus_metrics 
        (timestamp, metric_name, value, labels, job, instance) 
        VALUES {','.join(values)}
        """
        
        # 执行插入
        cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "{insert_sql}" """
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            print(f"✅ 成功写入 {len(metrics)} 条记录到ClickHouse")
        else:
            print(f"❌ 写入ClickHouse失败: {result.stderr}")
            
    except Exception as e:
        print(f"❌ 写入ClickHouse异常: {e}")

def check_services():
    """检查服务状态"""
    print("🔍 检查服务状态...")
    
    # 检查Prometheus
    try:
        response = requests.get(f"{PROMETHEUS_URL}/api/v1/query?query=up", timeout=5)
        if response.status_code == 200:
            print("✅ Prometheus: 正常")
        else:
            print("❌ Prometheus: 异常")
            return False
    except:
        print("❌ Prometheus: 无法连接")
        return False
    
    # 检查ClickHouse
    try:
        cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "SELECT 1" """
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if result.returncode == 0:
            print("✅ ClickHouse: 正常")
        else:
            print("❌ ClickHouse: 异常")
            return False
    except:
        print("❌ ClickHouse: 无法连接")
        return False
    
    return True

def main():
    """主函数"""
    print("🚀 启动Prometheus到ClickHouse数据同步...")
    
    # 检查服务
    if not check_services():
        print("❌ 服务检查失败，退出")
        sys.exit(1)
    
    # 初始化ClickHouse
    init_clickhouse()
    
    # 执行一次数据同步
    print("📊 开始数据同步...")
    metrics = get_prometheus_metrics()
    if metrics:
        print(f"📈 获取到 {len(metrics)} 个指标")
        write_to_clickhouse(metrics)
    
    # 查询验证
    print("\n🔍 验证数据写入...")
    cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "SELECT count() as total_records FROM {CLICKHOUSE_DATABASE}.prometheus_metrics" """
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.returncode == 0:
        count = result.stdout.strip()
        print(f"✅ ClickHouse中共有 {count} 条记录")
        
        # 显示最新的几条记录
        cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "SELECT metric_name, value, job, formatDateTime(timestamp, '%Y-%m-%d %H:%M:%S') as time FROM {CLICKHOUSE_DATABASE}.prometheus_metrics ORDER BY timestamp DESC LIMIT 5" """
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            print("\n📋 最新的5条记录:")
            print(result.stdout)
    
    print("\n🎉 数据同步完成！")
    print(f"💡 可以在ClickHouse Play界面 (http://localhost:8123/play) 中查询数据:")
    print(f"   SELECT * FROM {CLICKHOUSE_DATABASE}.prometheus_metrics ORDER BY timestamp DESC LIMIT 10;")

if __name__ == "__main__":
    main()
