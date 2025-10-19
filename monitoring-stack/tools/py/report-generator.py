#!/usr/bin/env python3
"""
简单的Web报表生成器
生成HTML格式的监控报表
"""

import subprocess
import json
import time
from datetime import datetime
import os
import math
import urllib.request
import urllib.parse
import urllib.error

# 配置
CLICKHOUSE_USER = os.getenv("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.getenv("CLICKHOUSE_PASSWORD", "02UAihxpMDFDzqZf")
CLICKHOUSE_DATABASE = os.getenv("CLICKHOUSE_DB", "prometheus")
OUTPUT_DIR = os.getenv("CLICKHOUSE_REPORT_DIR", "clickhouse_reports_html")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://localhost:9090")

def execute_clickhouse_query(query):
    """执行ClickHouse查询"""
    try:
        cmd = f"""docker exec clickhouse-server clickhouse-client --user {CLICKHOUSE_USER} --password {CLICKHOUSE_PASSWORD} --query "{query}" --format JSONEachRow"""
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            return [json.loads(line) for line in lines if line.strip()]
        else:
            print(f"查询失败: {result.stderr}")
            return []
    except Exception as e:
        print(f"查询异常: {e}")
        return []

def get_summary_stats():
    """获取汇总统计数据"""
    stats = {}
    
    # 总记录数
    query = f"SELECT count() as total FROM {CLICKHOUSE_DATABASE}.prometheus_metrics"
    result = execute_clickhouse_query(query)
    stats['total_records'] = result[0]['total'] if result else 0
    
    # 指标类型数量
    query = f"SELECT count(DISTINCT metric_name) as metric_count FROM {CLICKHOUSE_DATABASE}.prometheus_metrics"
    result = execute_clickhouse_query(query)
    stats['metric_types'] = result[0]['metric_count'] if result else 0
    
    # 最新数据时间
    query = f"SELECT max(timestamp) as latest FROM {CLICKHOUSE_DATABASE}.prometheus_metrics"
    result = execute_clickhouse_query(query)
    stats['latest_time'] = result[0]['latest'] if result else 'N/A'
    
    # 数据时间范围
    query = f"SELECT min(timestamp) as earliest FROM {CLICKHOUSE_DATABASE}.prometheus_metrics"
    result = execute_clickhouse_query(query)
    stats['earliest_time'] = result[0]['earliest'] if result else 'N/A'
    
    return stats

def get_top_metrics():
    """获取Top指标统计"""
    query = f"""
    SELECT 
        metric_name,
        count() as count,
        avg(value) as avg_value,
        max(value) as max_value,
        min(value) as min_value
    FROM {CLICKHOUSE_DATABASE}.prometheus_metrics 
    GROUP BY metric_name 
    ORDER BY count DESC 
    LIMIT 10
    """
    return execute_clickhouse_query(query)


def query_prometheus(promql):
    """执行Prometheus即时查询"""
    try:
        params = urllib.parse.urlencode({"query": promql})
        url = f"{PROMETHEUS_URL.rstrip('/')}/api/v1/query?{params}"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.load(response)
        if data.get("status") == "success":
            return data.get("data", {}).get("result", [])
        error_message = data.get("error") or "unknown error"
        print(f"Prometheus查询失败: {error_message}")
    except urllib.error.URLError as e:
        print(f"Prometheus连接失败: {e}")
    except Exception as e:
        print(f"Prometheus查询异常: {e}")
    return []


def format_timestamp(ts_value):
    """格式化Unix时间戳"""
    if not ts_value:
        return "N/A"
    try:
        return datetime.fromtimestamp(float(ts_value)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return "N/A"


def get_node_exporter_overview():
    """获取Node Exporter核心指标概览"""
    metrics = {}

    def ensure_entry(instance):
        return metrics.setdefault(instance, {"latest_ts": 0})

    def update_metric(results, key, transform=None):
        for res in results:
            labels = res.get("metric", {})
            instance = labels.get("instance")
            if not instance:
                continue
            value_pair = res.get("value") or []
            if len(value_pair) < 2:
                continue
            ts_str, value_str = value_pair
            try:
                ts = float(ts_str)
                raw_val = float(value_str)
            except (TypeError, ValueError):
                continue
            if not math.isfinite(raw_val):
                continue
            val = transform(raw_val) if transform else raw_val
            if isinstance(val, float) and not math.isfinite(val):
                continue
            entry = ensure_entry(instance)
            entry[key] = val
            entry["latest_ts"] = max(entry.get("latest_ts", 0), ts)

    def update_labels(results, label_key, target_key):
        for res in results:
            labels = res.get("metric", {})
            instance = labels.get("instance")
            if not instance:
                continue
            entry = ensure_entry(instance)
            entry[target_key] = labels.get(label_key)
            value_pair = res.get("value") or []
            if value_pair:
                try:
                    ts = float(value_pair[0])
                    entry["latest_ts"] = max(entry.get("latest_ts", 0), ts)
                except (TypeError, ValueError):
                    pass

    cpu_results = query_prometheus('100 - (avg by(instance) (rate(node_cpu_seconds_total{job="node-exporter",mode="idle"}[5m])) * 100)')
    update_metric(cpu_results, "cpu")

    memory_results = query_prometheus('((node_memory_MemTotal_bytes{job="node-exporter"} - node_memory_MemAvailable_bytes{job="node-exporter"}) / node_memory_MemTotal_bytes{job="node-exporter"}) * 100')
    update_metric(memory_results, "memory")

    disk_results = query_prometheus('max by(instance) ((node_filesystem_size_bytes{job="node-exporter",fstype!~"tmpfs|fuse.lxcfs|overlay",mountpoint!~"^/(sys|proc|dev|run)($|/)"} - node_filesystem_avail_bytes{job="node-exporter",fstype!~"tmpfs|fuse.lxcfs|overlay",mountpoint!~"^/(sys|proc|dev|run)($|/)"}) / node_filesystem_size_bytes{job="node-exporter",fstype!~"tmpfs|fuse.lxcfs|overlay",mountpoint!~"^/(sys|proc|dev|run)($|/)"} * 100)')
    update_metric(disk_results, "disk")

    net_in_results = query_prometheus('sum by(instance) (rate(node_network_receive_bytes_total{job="node-exporter"}[5m]))')
    update_metric(net_in_results, "net_in", lambda v: v / 1024 / 1024)

    net_out_results = query_prometheus('sum by(instance) (rate(node_network_transmit_bytes_total{job="node-exporter"}[5m]))')
    update_metric(net_out_results, "net_out", lambda v: v / 1024 / 1024)

    load_results = query_prometheus('node_load1{job="node-exporter"}')
    update_metric(load_results, "load1")

    status_results = query_prometheus('up{job="node-exporter"}')
    update_metric(status_results, "status")

    hostname_results = query_prometheus('node_uname_info{job="node-exporter"}')
    update_labels(hostname_results, "nodename", "hostname")

    overview = []
    for instance, data in sorted(metrics.items(), key=lambda item: item[0]):
        overview.append({
            "instance": instance,
            "hostname": data.get("hostname"),
            "status": data.get("status", 0),
            "cpu": data.get("cpu"),
            "memory": data.get("memory"),
            "disk": data.get("disk"),
            "net_in": data.get("net_in"),
            "net_out": data.get("net_out"),
            "load1": data.get("load1"),
            "last_scrape": format_timestamp(data.get("latest_ts"))
        })

    return overview

def get_recent_data():
    """获取最近的数据"""
    query = f"""
    SELECT 
        metric_name,
        value,
        job,
        instance,
        formatDateTime(timestamp, '%Y-%m-%d %H:%M:%S') as time
    FROM {CLICKHOUSE_DATABASE}.prometheus_metrics 
    ORDER BY timestamp DESC 
    LIMIT 20
    """
    return execute_clickhouse_query(query)

def get_job_stats():
    """按Job统计数据"""
    query = f"""
    SELECT 
        job,
        count() as count,
        count(DISTINCT metric_name) as metric_types,
        max(timestamp) as latest_time
    FROM {CLICKHOUSE_DATABASE}.prometheus_metrics 
    GROUP BY job 
    ORDER BY count DESC
    """
    return execute_clickhouse_query(query)

def generate_html_report():
    """生成HTML报表"""
    print("📊 生成监控数据报表...")
    
    # 获取数据
    summary = get_summary_stats()
    top_metrics = get_top_metrics()
    recent_data = get_recent_data()
    job_stats = get_job_stats()
    node_overview = get_node_exporter_overview()
    
    # 生成时间
    report_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    # HTML模板
    html_content = f"""
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Prometheus监控数据报表</title>
        <style>
            body {{
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                margin: 0;
                padding: 20px;
                background-color: #f5f5f5;
                color: #333;
            }}
            .container {{
                max-width: 1200px;
                margin: 0 auto;
                background: white;
                padding: 30px;
                border-radius: 10px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            }}
            .header {{
                text-align: center;
                margin-bottom: 30px;
                padding-bottom: 20px;
                border-bottom: 2px solid #007bff;
            }}
            .header h1 {{
                color: #007bff;
                margin: 0;
                font-size: 2.5em;
            }}
            .header p {{
                color: #666;
                margin: 10px 0 0 0;
                font-size: 1.1em;
            }}
            .stats-grid {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
                gap: 20px;
                margin-bottom: 30px;
            }}
            .stat-card {{
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 20px;
                border-radius: 8px;
                text-align: center;
            }}
            .stat-card h3 {{
                margin: 0 0 10px 0;
                font-size: 1.2em;
                opacity: 0.9;
            }}
            .stat-card .value {{
                font-size: 2em;
                font-weight: bold;
                margin: 0;
            }}
            .section {{
                margin-bottom: 40px;
            }}
            .section h2 {{
                color: #333;
                border-bottom: 2px solid #007bff;
                padding-bottom: 10px;
                margin-bottom: 20px;
            }}
            table {{
                width: 100%;
                border-collapse: collapse;
                margin-bottom: 20px;
                background: white;
                border-radius: 8px;
                overflow: hidden;
                box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            }}
            th, td {{
                padding: 12px;
                text-align: left;
                border-bottom: 1px solid #ddd;
            }}
            th {{
                background-color: #007bff;
                color: white;
                font-weight: 600;
            }}
            tr:hover {{
                background-color: #f8f9fa;
            }}
            .metric-name {{
                font-family: 'Courier New', monospace;
                background: #f8f9fa;
                padding: 2px 6px;
                border-radius: 4px;
                font-size: 0.9em;
            }}
            .number {{
                text-align: right;
                font-weight: 600;
            }}
            .badge {{
                display: inline-block;
                padding: 4px 10px;
                border-radius: 999px;
                font-weight: 600;
                font-size: 0.85em;
            }}
            .badge-success {{
                background-color: #28a745;
                color: #fff;
            }}
            .badge-danger {{
                background-color: #dc3545;
                color: #fff;
            }}
            .subtext {{
                color: #888;
                font-size: 0.85em;
            }}
            .footer {{
                text-align: center;
                margin-top: 40px;
                padding-top: 20px;
                border-top: 1px solid #ddd;
                color: #666;
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>📊 Prometheus监控数据报表</h1>
                <p>生成时间: {report_time}</p>
            </div>
            
            <div class="stats-grid">
                <div class="stat-card">
                    <h3>总记录数</h3>
                    <p class="value">{summary.get('total_records', 0):,}</p>
                </div>
                <div class="stat-card">
                    <h3>指标类型</h3>
                    <p class="value">{summary.get('metric_types', 0)}</p>
                </div>
                <div class="stat-card">
                    <h3>最新数据</h3>
                    <p class="value" style="font-size: 1.2em;">{summary.get('latest_time', 'N/A')}</p>
                </div>
                <div class="stat-card">
                    <h3>数据范围</h3>
                    <p class="value" style="font-size: 1.2em;">{summary.get('earliest_time', 'N/A')}</p>
                </div>
            </div>
            
            <div class="section">
                <h2>🏆 Top 10 指标统计</h2>
                <table>
                    <thead>
                        <tr>
                            <th>指标名称</th>
                            <th>记录数</th>
                            <th>平均值</th>
                            <th>最大值</th>
                            <th>最小值</th>
                        </tr>
                    </thead>
                    <tbody>
    """
    
    # 添加Top指标数据
    for metric in top_metrics:
        html_content += f"""
                        <tr>
                            <td><span class="metric-name">{metric['metric_name']}</span></td>
                            <td class="number">{metric['count']:,}</td>
                            <td class="number">{metric['avg_value']:.2f}</td>
                            <td class="number">{metric['max_value']:.2f}</td>
                            <td class="number">{metric['min_value']:.2f}</td>
                        </tr>
        """
    
    html_content += """
                    </tbody>
                </table>
            </div>
            
            <div class="section">
                <h2>📈 按Job统计</h2>
                <table>
                    <thead>
                        <tr>
                            <th>Job名称</th>
                            <th>记录数</th>
                            <th>指标类型数</th>
                            <th>最新数据时间</th>
                        </tr>
                    </thead>
                    <tbody>
    """
    
    # 添加Job统计数据
    for job in job_stats:
        html_content += f"""
                        <tr>
                            <td><strong>{job['job']}</strong></td>
                            <td class="number">{job['count']:,}</td>
                            <td class="number">{job['metric_types']}</td>
                            <td>{job['latest_time']}</td>
                        </tr>
        """

    html_content += """
                    </tbody>
                </table>
            </div>

            <div class="section">
                <h2>🖥️ Node Exporter 主机概览</h2>
                <p>基于 Grafana 仪表板 <strong>Node Exporter Dashboard CN</strong> 的核心监控指标</p>
    """

    if node_overview:
        html_content += """
                <table>
                    <thead>
                        <tr>
                            <th>主机</th>
                            <th>状态</th>
                            <th>CPU使用率</th>
                            <th>内存使用率</th>
                            <th>磁盘使用率</th>
                            <th>网络接收</th>
                            <th>网络发送</th>
                            <th>负载(1m)</th>
                            <th>数据时间</th>
                        </tr>
                    </thead>
                    <tbody>
        """

        for node in node_overview:
            hostname = node.get("hostname") or "-"
            instance = node.get("instance", "-")
            status_value = node.get("status", 0)
            status_badge = '<span class="badge badge-success">在线</span>' if status_value >= 0.5 else '<span class="badge badge-danger">离线</span>'
            cpu_text = f"{node['cpu']:.2f}%" if node.get("cpu") is not None else "N/A"
            memory_text = f"{node['memory']:.2f}%" if node.get("memory") is not None else "N/A"
            disk_text = f"{node['disk']:.2f}%" if node.get("disk") is not None else "N/A"
            net_in_val = node.get("net_in")
            net_out_val = node.get("net_out")
            net_in_text = f"{net_in_val:.2f} MB/s" if net_in_val is not None else "N/A"
            net_out_text = f"{net_out_val:.2f} MB/s" if net_out_val is not None else "N/A"
            load1_text = f"{node['load1']:.2f}" if node.get("load1") is not None else "N/A"
            last_scrape = node.get("last_scrape", "N/A")

            html_content += f"""
                        <tr>
                            <td>
                                <div><strong>{hostname}</strong></div>
                                <div class="subtext">{instance}</div>
                            </td>
                            <td>{status_badge}</td>
                            <td class="number">{cpu_text}</td>
                            <td class="number">{memory_text}</td>
                            <td class="number">{disk_text}</td>
                            <td class="number">{net_in_text}</td>
                            <td class="number">{net_out_text}</td>
                            <td class="number">{load1_text}</td>
                            <td>{last_scrape}</td>
                        </tr>
            """

        html_content += """
                    </tbody>
                </table>
        """
    else:
        html_content += """
                <p>暂无 Node Exporter 指标数据，请确认 Prometheus 正在采集 node-exporter 指标。</p>
        """

    html_content += """
            </div>

            <div class="section">
                <h2>🕒 最新20条数据</h2>
                <table>
                    <thead>
                        <tr>
                            <th>指标名称</th>
                            <th>数值</th>
                            <th>Job</th>
                            <th>实例</th>
                            <th>时间</th>
                        </tr>
                    </thead>
                    <tbody>
    """
    
    # 添加最新数据
    for data in recent_data:
        html_content += f"""
                        <tr>
                            <td><span class="metric-name">{data['metric_name']}</span></td>
                            <td class="number">{data['value']}</td>
                            <td>{data['job']}</td>
                            <td>{data['instance']}</td>
                            <td>{data['time']}</td>
                        </tr>
        """
    
    html_content += f"""
                    </tbody>
                </table>
            </div>
            
            <div class="footer">
                <p>📊 Prometheus ClickHouse 监控系统 | 报表生成时间: {report_time}</p>
                <p>💡 访问 <a href="http://localhost:3000" target="_blank">Grafana仪表板</a> 查看实时可视化图表</p>
            </div>
        </div>
    </body>
    </html>
    """
    
    return html_content

def main():
    """主函数"""
    print("🚀 启动监控报表生成器...")
    
    # 创建报表目录
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # 生成HTML报表
    html_content = generate_html_report()
    
    # 保存报表
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"{OUTPUT_DIR}/prometheus_report_{timestamp}.html"
    
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    # 创建最新报表链接
    latest_filename = f"{OUTPUT_DIR}/latest_report.html"
    with open(latest_filename, 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    print(f"✅ 报表生成完成!")
    print(f"📄 报表文件: {filename}")
    print(f"🔗 最新报表: {latest_filename}")
    print(f"🌐 在浏览器中打开: file://{os.path.abspath(latest_filename)}")

if __name__ == "__main__":
    main()
