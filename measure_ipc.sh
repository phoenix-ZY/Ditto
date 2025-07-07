#!/bin/bash

# 配置文件路径


SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR"
CONFIG_FILE="$ROOT_DIR/app_config.json"
OUTPUT_DIR="$ROOT_DIR/perf_results"

# 解析命令行参数
APP_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 --app <app_name>"
    echo "Available apps:"
    jq -r 'keys[]' "$CONFIG_FILE"
    exit 1
fi


#从JSON文件读取配置
if ! jq -e ".${APP_NAME}" "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "Error: Application '$APP_NAME' not found in config file"
    exit 1
fi

# 提取应用配置
APP_CMD=$(jq -r ".${APP_NAME}.app_cmd" "$CONFIG_FILE")
LOAD_CMD=$(jq -r ".${APP_NAME}.load_cmd" "$CONFIG_FILE")
CLIENT_CMD=$(jq -r ".${APP_NAME}.client_cmd" "$CONFIG_FILE")

# 测试参数配置
PERF_SAMPLES=5
PERF_INTERVAL=10
CONNECTIONS=32
DURATION=170
REQS_PER_SEC=1000

# 创建输出目录
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$OUTPUT_DIR/perf_report_${APP_NAME}_${TIMESTAMP}.txt"
AVERAGE_FILE="$OUTPUT_DIR/perf_averages_${APP_NAME}_${TIMESTAMP}.txt"

# 提取右侧指标值
extract_metrics() {
    local file="$1"
    declare -gA metrics

    while read line; do
        echo $line
        # 跳过空行和注释
        [[ -z "$line" || "$line" == \#* ]] && continue

        # 提取指标名称和右侧值
        if [[ "$line" =~ \#\s*([0-9.]+)\s*(.*)$ ]]; then
            echo "匹配成功:"
            echo "  第一部分: '${BASH_REMATCH[1]}'"
            echo "  数值部分: '${BASH_REMATCH[2]}'"
        #     metric_name=$(echo "${BASH_REMATCH[1]}" | sed 's/ *$//')
        #     value=${BASH_REMATCH[2]}
        #     unit=${BASH_REMATCH[3]}
            
        #     # 打印调试信息
        #     echo "DEBUG: metric_name='$metric_name', value='$value', unit='$unit'"

        #     # 特殊处理关键指标
        #     if [[ "$metric_name" =~ "insn per cycle" ]]; then
        #         metrics["IPC"]="$value"
        #         echo "DEBUG: Set metrics[IPC]=$value"
        #     elif [[ "$metric_name" =~ "retiring" ]]; then
        #         metrics["Retiring%"]="$value"
        #         echo "DEBUG: Set metrics[Retiring%]=$value"
        #     elif [[ "$metric_name" =~ "bad speculation" ]]; then
        #         metrics["BadSpec%"]="$value"
        #         echo "DEBUG: Set metrics[BadSpec%]=$value"
        #     elif [[ "$metric_name" =~ "frontend bound" ]]; then
        #         metrics["FrontendBound%"]="$value"
        #         echo "DEBUG: Set metrics[FrontendBound%]=$value"
        #     elif [[ "$metric_name" =~ "backend bound" ]]; then
        #         metrics["BackendBound%"]="$value"
        #         echo "DEBUG: Set metrics[BackendBound%]=$value"
        #     fi
        fi
    done < "$file"
}

# 启动服务器
start_server() {
    # 设置要绑定的CPU核心列表，例如 "0,1,2,3" 表示绑定到前4个核心
    CPU_CORES="0-64"  # 根据你的需求修改这个值
    
    echo "Starting server with: $APP_CMD"
    echo "Binding to CPU cores: $CPU_CORES"
    
    # 使用taskset绑定CPU
    eval "taskset -c $CPU_CORES $APP_CMD" &
    sleep 1
    cmd_name="${APP_CMD%% *}" 
    echo "Command path: $cmd_name"

    SERVER_PID=$(pgrep -f "$cmd_name")

    if [ -z "$SERVER_PID" ]; then
        echo "Error: Failed to start server"
        exit 1
    fi

    echo "Server started with PID $SERVER_PID"
    
    sleep 1
    if echo "$APP_CMD" | grep -qi "nginx"; then
        # 获取所有worker进程PID
        WORKER_PIDS=$(pgrep -P $SERVER_PID)
        
        if [ -z "$WORKER_PIDS" ]; then
            echo "Warning: No worker processes found under master $SERVER_PID"
            # 回退到使用master进程
            MONITOR_PID=$SERVER_PID
        else
            # 取第一个worker进程（或根据需要调整）
            MONITOR_PID=$(echo $WORKER_PIDS | awk '{print $1}')
            echo "Monitoring worker process: $MONITOR_PID"
        fi
    else
        MONITOR_PID=$SERVER_PID
    fi

    if ! ps -p $MONITOR_PID > /dev/null; then
        echo "Error: Failed to start server"
        exit 1
    fi
}

# 加载数据（如果配置中有load_cmd）
load_data() {
    echo $LOAD_CMD

    if [ -n "$LOAD_CMD" ] && [ "$LOAD_CMD" != "null" ]; then
        echo "Loading data with: $LOAD_CMD"
        eval "$LOAD_CMD" || {
            echo "Error: Failed to load data"
            cleanup
            exit 1
        }
    else
        echo "Skipping data loading as no load_cmd specified"
    fi
}

# 运行性能测试
run_perf_test() {
    sleep 5
    # 替换client_cmd中的占位符
    local test_cmd=$(echo "$CLIENT_CMD" | \
        sed "s/<conns>/$CONNECTIONS/g" | \
        sed "s/<duration>/$DURATION/g" | \
        sed "s/<reqs_per_sec>/$REQS_PER_SEC/g" | \
        sed "s/<reqs_per_sec_per_conn>/$((REQS_PER_SEC/CONNECTIONS))/g" | \
        sed "s/<reqs>/$((REQS_PER_SEC*DURATION))/g")
        
    
    echo "Starting performance test with: $test_cmd"
    eval "$test_cmd" &
    sleep 1  # 确保客户端进程启动
    CLIENT_PID=$(pgrep -f "$test_cmd")
    echo "Client started with PID $CLIENT_PID"
    
    # declare -A metric_sums
    # declare -A metric_counts
    
    for ((i=1; i<=$PERF_SAMPLES; i++)); do

        SAMPLE_FILE="$OUTPUT_DIR/perf_ipc_${APP_NAME}_${i}.txt"
        echo "Taking sample $i/$PERF_SAMPLES..."
        sudo perf stat -p $MONITOR_PID -o "$SAMPLE_FILE" -- sleep $PERF_INTERVAL

        SAMPLE_FILE="$OUTPUT_DIR/perf_cache_${APP_NAME}_${i}.txt"
        echo "Taking sample $i/$PERF_SAMPLES..."
        sudo perf stat -p $MONITOR_PID -e cache-misses,cache-references,L1-dcache-load-misses,L1-dcache-loads,LLC-loads,LLC-load-misses -o "$SAMPLE_FILE" -- sleep $PERF_INTERVAL

        SAMPLE_FILE="$OUTPUT_DIR/perf_topdown_${APP_NAME}_${i}.txt"
        echo "Taking sample $i/$PERF_SAMPLES..."
        sudo perf stat -p $MONITOR_PID -e topdown-fetch-bubbles,topdown-recovery-bubbles,topdown-slots-issued,topdown-slots-retired -o "$SAMPLE_FILE" -- sleep $PERF_INTERVAL
        # # 从样本中提取指标
        # declare -A metrics
        # extract_metrics "$SAMPLE_FILE"
        
        # # 累加指标值
        # for key in "${!metrics[@]}"; do
        #     metric_sums["$key"]=$(echo "${metric_sums["$key"]:-0} + ${metrics["$key"]}" | bc)
        #     metric_counts["$key"]=$(( ${metric_counts["$key"]:-0} + 1 ))
        # done

        sleep 1
    done
    
    sleep 1
    # 强制终止客户端进程（替换原来的 wait）
    kill -SIGTERM $CLIENT_PID 2>/dev/null  # 先尝试优雅终止
    wait $CLIENT_PID 2>/dev/null
    sleep 5  

}

# 生成平均值报告
generate_report() {
    echo "Generating averages report..."
    declare -A averages
    
    # 计算每个指标的平均值
    for metric in "${!metric_sums[@]}"; do
        avg=$(echo "scale=4; ${metric_sums[$metric]} / ${metric_counts[$metric]}" | bc)
        averages["$metric"]=$avg
    done
    
    # 写入平均值文件
    {
        echo "# Performance Metrics Averages for $APP_NAME"
        echo "# Generated on $(date)"
        echo "# Based on $PERF_SAMPLES samples of $PERF_INTERVAL seconds each"
        echo ""
        printf "%-20s %-15s\n" "METRIC" "AVERAGE_VALUE"
        echo "----------------------------------------"
        for metric in "${!averages[@]}"; do
            printf "%-20s %-15.4f\n" "$metric" "${averages[$metric]}"
        done
    } > "$AVERAGE_FILE"
    
    echo "Averages report generated: $AVERAGE_FILE"
    cat "$AVERAGE_FILE"
}

# 清理函数
cleanup() {
    echo "Cleaning up..."
    kill -SIGTERM $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}

# 主执行流程
start_server
load_data
run_perf_test
# generate_report
cleanup