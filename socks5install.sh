#!/bin/bash

#===============================================================================
#
#  SOCKS5 代理服务器 - 全自动无人值守部署脚本
#  
#  支持系统: Ubuntu 20.04 / 22.04 / 24.04, Debian 10 / 11 / 12
#  兼容用户: root / ubuntu / 任何具有sudo权限的用户
#  
#  功能特性:
#    - 全自动无人值守安装
#    - 完善的依赖检查与安装
#    - 健壮的错误处理机制
#    - 自动网卡检测
#    - 防火墙自动配置
#    - 服务健康检查
#
#===============================================================================

set -o pipefail  # 管道命令中任一命令失败则整体失败

#===============================================================================
# 固定配置参数（无需修改）
#===============================================================================

readonly PROXY_PORT=1080
readonly PROXY_USER="MaiDong"
readonly PROXY_PASS="Goog1eNice"
readonly LOG_FILE="/var/log/socks5_deploy.log"
readonly DANTE_CONF="/etc/danted.conf"
readonly DANTE_SERVICE="/etc/systemd/system/danted.service"
readonly MAX_RETRY=3
readonly RETRY_DELAY=5

#===============================================================================
# 颜色定义
#===============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

#===============================================================================
# 日志函数
#===============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
    log "INFO" "$1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
    log "INFO" "$1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    log "WARN" "$1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    log "ERROR" "$1"
}

print_step() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    log "STEP" "$1"
}

#===============================================================================
# 权限处理函数
#===============================================================================

# 统一的命令执行函数，自动处理权限
run_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# 检查是否有root权限或sudo权限
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        print_status "当前以 root 用户运行"
        return 0
    fi
    
    # 检查sudo权限
    if sudo -n true 2>/dev/null; then
        print_status "当前用户具有 sudo 权限（免密）"
        return 0
    fi
    
    # 尝试获取sudo权限
    print_info "需要 sudo 权限，请输入密码..."
    if sudo -v; then
        print_status "sudo 权限验证成功"
        # 保持sudo会话活跃
        (while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null) &
        return 0
    else
        print_error "无法获取 sudo 权限"
        return 1
    fi
}

#===============================================================================
# 系统检测函数
#===============================================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$PRETTY_NAME"
    elif [[ -f /etc/lsb-release ]]; then
        . /etc/lsb-release
        OS_ID="$DISTRIB_ID"
        OS_VERSION="$DISTRIB_RELEASE"
        OS_NAME="$DISTRIB_DESCRIPTION"
    else
        print_error "无法识别操作系统"
        return 1
    fi
    
    # 转换为小写
    OS_ID=$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')
    
    print_info "检测到系统: $OS_NAME"
    
    # 验证支持的系统
    case "$OS_ID" in
        ubuntu|debian)
            print_status "系统类型支持: $OS_ID"
            return 0
            ;;
        *)
            print_error "不支持的系统: $OS_ID (仅支持 Ubuntu/Debian)"
            return 1
            ;;
    esac
}

detect_architecture() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            print_status "系统架构: x86_64 (64位)"
            ;;
        aarch64|arm64)
            print_status "系统架构: ARM64"
            ;;
        armv7l|armhf)
            print_status "系统架构: ARMv7"
            ;;
        *)
            print_warn "未知架构: $ARCH，将尝试继续安装"
            ;;
    esac
}

detect_network_interface() {
    print_info "检测网络接口..."
    
    # 方法1: 通过默认路由获取
    MAIN_INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    
    # 方法2: 获取有IP的第一个非lo接口
    if [[ -z "$MAIN_INTERFACE" ]]; then
        MAIN_INTERFACE=$(ip -o -4 addr show 2>/dev/null | awk '!/^[0-9]+: lo/ {print $2}' | head -n1)
    fi
    
    # 方法3: 通过ip link获取UP状态的接口
    if [[ -z "$MAIN_INTERFACE" ]]; then
        MAIN_INTERFACE=$(ip link show 2>/dev/null | awk -F: '/state UP/ {print $2}' | tr -d ' ' | grep -v lo | head -n1)
    fi
    
    # 方法4: 常见接口名称
    if [[ -z "$MAIN_INTERFACE" ]]; then
        for iface in eth0 ens3 ens4 enp0s3 enp3s0; do
            if ip link show "$iface" &>/dev/null; then
                MAIN_INTERFACE="$iface"
                break
            fi
        done
    fi
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        print_error "无法检测到网络接口"
        return 1
    fi
    
    # 验证接口存在
    if ! ip link show "$MAIN_INTERFACE" &>/dev/null; then
        print_error "网络接口 $MAIN_INTERFACE 不存在"
        return 1
    fi
    
    print_status "主网络接口: $MAIN_INTERFACE"
    return 0
}

get_public_ip() {
    local ip=""
    local services=(
        "ifconfig.me"
        "icanhazip.com"
        "ipinfo.io/ip"
        "api.ipify.org"
        "ipecho.net/plain"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s -4 --connect-timeout 5 --max-time 10 "$service" 2>/dev/null)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    echo "无法获取"
    return 1
}

check_port_available() {
    local port=$1
    
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    fi
    
    return 0
}

#===============================================================================
# 依赖安装函数
#===============================================================================

update_package_lists() {
    print_info "更新软件包列表..."
    
    local retry=0
    while [[ $retry -lt $MAX_RETRY ]]; do
        if run_as_root apt-get update -y 2>&1 | tee -a "$LOG_FILE"; then
            print_status "软件包列表更新成功"
            return 0
        fi
        
        retry=$((retry + 1))
        print_warn "更新失败，第 $retry 次重试..."
        sleep $RETRY_DELAY
    done
    
    print_error "软件包列表更新失败"
    return 1
}

install_package() {
    local package="$1"
    local description="${2:-$package}"
    
    # 检查是否已安装
    if dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
        print_status "$description 已安装"
        return 0
    fi
    
    print_info "安装 $description..."
    
    local retry=0
    while [[ $retry -lt $MAX_RETRY ]]; do
        # 设置非交互式安装
        export DEBIAN_FRONTEND=noninteractive
        
        if run_as_root apt-get install -y -q \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$package" 2>&1 | tee -a "$LOG_FILE"; then
            
            # 验证安装
            if dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
                print_status "$description 安装成功"
                return 0
            fi
        fi
        
        retry=$((retry + 1))
        print_warn "安装失败，第 $retry 次重试..."
        sleep $RETRY_DELAY
    done
    
    print_error "$description 安装失败"
    return 1
}

check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

install_dependencies() {
    print_step "步骤 1/6: 安装依赖组件"
    
    # 定义所有需要的依赖
    declare -A DEPENDENCIES=(
        ["curl"]="curl - HTTP客户端工具"
        ["wget"]="wget - 下载工具"
        ["ss"]="iproute2 - 网络工具"
        ["awk"]="gawk - 文本处理工具"
        ["sed"]="sed - 流编辑器"
        ["grep"]="grep - 文本搜索工具"
        ["systemctl"]="systemd - 系统服务管理"
    )
    
    # 检查基础命令
    print_info "检查基础依赖..."
    
    local missing_deps=()
    
    # curl
    if ! check_command curl; then
        missing_deps+=("curl")
    else
        print_status "curl 已就绪"
    fi
    
    # wget (备用下载工具)
    if ! check_command wget; then
        missing_deps+=("wget")
    else
        print_status "wget 已就绪"
    fi
    
    # 更新包列表
    if [[ ${#missing_deps[@]} -gt 0 ]] || ! dpkg -l dante-server 2>/dev/null | grep -q "^ii"; then
        update_package_lists || return 1
    fi
    
    # 安装缺失的基础依赖
    for dep in "${missing_deps[@]}"; do
        install_package "$dep" "$dep" || return 1
    done
    
    # 安装额外的有用工具
    print_info "安装额外工具..."
    
    # net-tools (提供 netstat)
    install_package "net-tools" "net-tools (网络诊断工具)" || true
    
    # lsof (查看端口占用)
    install_package "lsof" "lsof (文件/端口查看工具)" || true
    
    print_status "所有依赖组件已就绪"
    return 0
}

#===============================================================================
# Dante 安装与配置
#===============================================================================

install_dante() {
    print_step "步骤 2/6: 安装 Dante SOCKS5 服务器"
    
    # 检查是否已安装
    if dpkg -l dante-server 2>/dev/null | grep -q "^ii"; then
        print_status "Dante 已安装，检查版本..."
        local version=$(dpkg -l dante-server | awk '/dante-server/ {print $3}')
        print_info "当前版本: $version"
    else
        install_package "dante-server" "Dante SOCKS5 服务器" || return 1
    fi
    
    # 验证安装
    if ! check_command danted; then
        print_error "Dante 安装验证失败: danted 命令不存在"
        return 1
    fi
    
    print_status "Dante SOCKS5 服务器安装完成"
    return 0
}

create_proxy_user() {
    print_step "步骤 3/6: 创建代理用户"
    
    print_info "用户名: $PROXY_USER"
    
    # 检查用户是否存在
    if id "$PROXY_USER" &>/dev/null; then
        print_info "用户 $PROXY_USER 已存在，更新密码..."
    else
        print_info "创建新用户 $PROXY_USER..."
        
        # 创建系统用户（无登录shell，无home目录）
        if ! run_as_root useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            "$PROXY_USER" 2>&1 | tee -a "$LOG_FILE"; then
            
            # 如果useradd失败，尝试另一种方式
            if ! id "$PROXY_USER" &>/dev/null; then
                run_as_root useradd -r -s /usr/sbin/nologin "$PROXY_USER" 2>/dev/null || true
            fi
        fi
    fi
    
    # 设置密码
    print_info "设置用户密码..."
    if echo "${PROXY_USER}:${PROXY_PASS}" | run_as_root chpasswd 2>&1 | tee -a "$LOG_FILE"; then
        print_status "用户密码设置成功"
    else
        print_error "用户密码设置失败"
        return 1
    fi
    
    # 验证用户
    if id "$PROXY_USER" &>/dev/null; then
        print_status "代理用户 $PROXY_USER 配置完成"
        return 0
    else
        print_error "用户创建验证失败"
        return 1
    fi
}

configure_dante() {
    print_step "步骤 4/6: 配置 Dante 服务"
    
    # 检测网络接口
    if ! detect_network_interface; then
        print_error "网络接口检测失败"
        return 1
    fi
    
    # 检查端口是否可用
    if ! check_port_available "$PROXY_PORT"; then
        print_warn "端口 $PROXY_PORT 已被占用，尝试停止现有服务..."
        run_as_root systemctl stop danted 2>/dev/null || true
        sleep 2
        
        if ! check_port_available "$PROXY_PORT"; then
            print_error "端口 $PROXY_PORT 仍被占用，请手动检查"
            run_as_root ss -tlnp | grep ":$PROXY_PORT" || true
            return 1
        fi
    fi
    print_status "端口 $PROXY_PORT 可用"
    
    # 备份现有配置
    if [[ -f "$DANTE_CONF" ]]; then
        local backup_file="${DANTE_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        print_info "备份现有配置到 $backup_file"
        run_as_root cp "$DANTE_CONF" "$backup_file"
    fi
    
    # 创建配置文件
    print_info "生成 Dante 配置文件..."
    
    run_as_root tee "$DANTE_CONF" > /dev/null << EOF
#===============================================================================
# Dante SOCKS5 代理服务器配置
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 网络接口: $MAIN_INTERFACE
# 监听端口: $PROXY_PORT
#===============================================================================

# 日志配置
logoutput: syslog /var/log/danted.log

# 内部接口配置（监听地址）
# 监听所有网络接口
internal: 0.0.0.0 port = $PROXY_PORT

# 外部接口配置（出口地址）
external: $MAIN_INTERFACE

# 认证方法
# username: 需要用户名密码认证
socksmethod: username

# 客户端认证方法
clientmethod: none

# 用户权限配置
user.privileged: root
user.unprivileged: nobody

# 超时设置（秒）
timeout.io: 300
timeout.negotiate: 30

#===============================================================================
# 访问控制规则
#===============================================================================

# 客户端连接规则 - 允许所有客户端连接
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# SOCKS请求规则 - 需要用户名密码认证
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: username
}

# 阻止访问本地网络（安全考虑，可选）
# socks block {
#     from: 0.0.0.0/0 to: 127.0.0.0/8
#     log: connect error
# }
# socks block {
#     from: 0.0.0.0/0 to: 10.0.0.0/8
#     log: connect error
# }
# socks block {
#     from: 0.0.0.0/0 to: 172.16.0.0/12
#     log: connect error
# }
# socks block {
#     from: 0.0.0.0/0 to: 192.168.0.0/16
#     log: connect error
# }
EOF

    # 创建日志文件
    run_as_root touch /var/log/danted.log
    run_as_root chmod 666 /var/log/danted.log
    
    # 验证配置语法
    print_info "验证配置文件语法..."
    if run_as_root danted -V -f "$DANTE_CONF" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "配置文件语法正确"
    else
        # danted -V 可能返回非0但配置正确，检查是否有实际错误
        if run_as_root danted -V -f "$DANTE_CONF" 2>&1 | grep -qi "error\|fatal"; then
            print_error "配置文件存在错误"
            return 1
        fi
        print_status "配置文件检查完成"
    fi
    
    return 0
}

create_systemd_service() {
    print_info "创建 systemd 服务文件..."
    
    run_as_root tee "$DANTE_SERVICE" > /dev/null << 'EOF'
[Unit]
Description=Dante SOCKS5 Proxy Server
Documentation=man:danted(8) man:danted.conf(5)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/danted.pid
ExecStartPre=/bin/rm -f /var/run/danted.pid
ExecStart=/usr/sbin/danted -D -f /etc/danted.conf -p /var/run/danted.pid
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

# 安全加固
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

    print_status "systemd 服务文件创建完成"
}

start_dante_service() {
    print_step "步骤 5/6: 启动 Dante 服务"
    
    # 创建systemd服务
    create_systemd_service
    
    # 重载systemd
    print_info "重载 systemd 配置..."
    run_as_root systemctl daemon-reload
    
    # 停止可能正在运行的服务
    print_info "停止现有服务（如果有）..."
    run_as_root systemctl stop danted 2>/dev/null || true
    sleep 2
    
    # 杀死可能残留的进程
    run_as_root pkill -9 danted 2>/dev/null || true
    sleep 1
    
    # 启用开机自启
    print_info "启用开机自启..."
    run_as_root systemctl enable danted 2>&1 | tee -a "$LOG_FILE"
    
    # 启动服务
    print_info "启动 Dante 服务..."
    if ! run_as_root systemctl start danted 2>&1 | tee -a "$LOG_FILE"; then
        print_error "服务启动命令执行失败"
        print_info "查看详细错误信息..."
        run_as_root systemctl status danted --no-pager -l || true
        run_as_root journalctl -u danted --no-pager -n 20 || true
        return 1
    fi
    
    # 等待服务启动
    print_info "等待服务启动..."
    local wait_count=0
    local max_wait=10
    
    while [[ $wait_count -lt $max_wait ]]; do
        sleep 1
        wait_count=$((wait_count + 1))
        
        if run_as_root systemctl is-active --quiet danted; then
            break
        fi
    done
    
    # 检查服务状态
    if run_as_root systemctl is-active --quiet danted; then
        print_status "Dante 服务启动成功"
    else
        print_error "Dante 服务启动失败"
        print_info "服务状态:"
        run_as_root systemctl status danted --no-pager -l || true
        print_info "系统日志:"
        run_as_root journalctl -u danted --no-pager -n 30 || true
        return 1
    fi
    
    # 验证端口监听
    print_info "验证端口监听状态..."
    sleep 2
    
    if ss -tuln 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        print_status "端口 $PROXY_PORT 正在监听"
    else
        print_warn "端口监听验证失败，但服务可能仍在启动中"
    fi
    
    return 0
}

#===============================================================================
# 防火墙配置
#===============================================================================

configure_firewall() {
    print_step "步骤 6/6: 配置防火墙"
    
    local firewall_configured=false
    
    # UFW 防火墙
    if check_command ufw; then
        print_info "检测到 UFW 防火墙..."
        
        # 检查UFW状态
        local ufw_status=$(run_as_root ufw status 2>/dev/null | head -n1)
        
        if echo "$ufw_status" | grep -qi "active"; then
            print_info "UFW 处于活动状态，添加规则..."
            run_as_root ufw allow "$PROXY_PORT/tcp" comment 'SOCKS5 Proxy' 2>&1 | tee -a "$LOG_FILE"
            print_status "UFW 规则已添加: 允许 TCP $PROXY_PORT"
            firewall_configured=true
        else
            print_info "UFW 未启用，跳过配置"
        fi
    fi
    
    # iptables 防火墙
    if check_command iptables; then
        print_info "配置 iptables 规则..."
        
        # 检查规则是否已存在
        if ! run_as_root iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null; then
            run_as_root iptables -I INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>&1 | tee -a "$LOG_FILE"
            print_status "iptables 规则已添加: 允许 TCP $PROXY_PORT"
            firewall_configured=true
        else
            print_status "iptables 规则已存在"
            firewall_configured=true
        fi
        
        # 尝试持久化规则
        if check_command netfilter-persistent; then
            run_as_root netfilter-persistent save 2>/dev/null || true
            print_info "iptables 规则已持久化"
        elif [[ -f /etc/iptables/rules.v4 ]]; then
            run_as_root iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
    
    # firewalld 防火墙
    if check_command firewall-cmd; then
        print_info "检测到 firewalld..."
        
        if run_as_root systemctl is-active --quiet firewalld; then
            run_as_root firewall-cmd --permanent --add-port="${PROXY_PORT}/tcp" 2>&1 | tee -a "$LOG_FILE"
            run_as_root firewall-cmd --reload 2>&1 | tee -a "$LOG_FILE"
            print_status "firewalld 规则已添加: 允许 TCP $PROXY_PORT"
            firewall_configured=true
        fi
    fi
    
    if $firewall_configured; then
        print_status "防火墙配置完成"
    else
        print_info "未检测到活动的防火墙，跳过配置"
        print_warn "请确保云服务器安全组已开放端口 $PROXY_PORT"
    fi
    
    return 0
}

#===============================================================================
# 测试与验证
#===============================================================================

test_proxy() {
    print_info "测试代理连接..."
    
    # 本地端口测试
    if ss -tuln 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        print_status "本地端口测试: 通过"
    else
        print_warn "本地端口测试: 端口未监听"
        return 1
    fi
    
    # 代理功能测试（如果curl支持socks5）
    if curl --help 2>&1 | grep -q "socks5"; then
        print_info "执行代理功能测试..."
        
        local test_result=$(curl -s --connect-timeout 10 --max-time 15 \
            --socks5 "127.0.0.1:$PROXY_PORT" \
            --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
            http://ifconfig.me 2>/dev/null)
        
        if [[ -n "$test_result" && "$test_result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            print_status "代理功能测试: 通过 (出口IP: $test_result)"
            return 0
        else
            print_warn "代理功能测试: 未获取到响应（可能需要等待服务完全启动）"
        fi
    else
        print_info "curl 不支持 SOCKS5，跳过功能测试"
    fi
    
    return 0
}

#===============================================================================
# 显示部署结果
#===============================================================================

show_result() {
    local public_ip=$(get_public_ip)
    
    echo ""
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}║            🎉 SOCKS5 代理服务器部署成功！🎉                       ║${NC}"
    echo -e "${GREEN}║                                                                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  连接信息                                                           │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  服务器地址:  ${YELLOW}$public_ip${NC}"
    echo -e "${CYAN}│${NC}  代理端口:    ${YELLOW}$PROXY_PORT${NC}"
    echo -e "${CYAN}│${NC}  用户名:      ${YELLOW}$PROXY_USER${NC}"
    echo -e "${CYAN}│${NC}  密码:        ${YELLOW}$PROXY_PASS${NC}"
    echo -e "${CYAN}│${NC}  代理类型:    ${YELLOW}SOCKS5${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  连接地址                                                           │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}socks5://${PROXY_USER}:${PROXY_PASS}@${public_ip}:${PROXY_PORT}${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  测试命令                                                           │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  curl --socks5 ${public_ip}:${PROXY_PORT} \\"
    echo -e "${CYAN}│${NC}       --proxy-user ${PROXY_USER}:${PROXY_PASS} http://ifconfig.me"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  管理命令                                                           │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  查看状态:  systemctl status danted"
    echo -e "${CYAN}│${NC}  重启服务:  systemctl restart danted"
    echo -e "${CYAN}│${NC}  停止服务:  systemctl stop danted"
    echo -e "${CYAN}│${NC}  查看日志:  tail -f /var/log/danted.log"
    echo -e "${CYAN}│${NC}  部署日志:  cat $LOG_FILE"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  重要提醒:${NC}"
    echo "    1. 请确保云服务器安全组已开放端口 $PROXY_PORT (TCP)"
    echo "    2. 建议通过防火墙限制可访问的IP地址"
    echo "    3. 配置文件位置: $DANTE_CONF"
    echo ""
    
    # 写入连接信息到文件
    local info_file="/root/socks5_info.txt"
    run_as_root tee "$info_file" > /dev/null << EOF
=== SOCKS5 代理连接信息 ===
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

服务器地址: $public_ip
代理端口: $PROXY_PORT
用户名: $PROXY_USER
密码: $PROXY_PASS

连接地址: socks5://${PROXY_USER}:${PROXY_PASS}@${public_ip}:${PROXY_PORT}

测试命令:
curl --socks5 ${public_ip}:${PROXY_PORT} --proxy-user ${PROXY_USER}:${PROXY_PASS} http://ifconfig.me
EOF
    print_info "连接信息已保存到: $info_file"
}

#===============================================================================
# 错误处理
#===============================================================================

cleanup_on_error() {
    print_error "部署过程中发生错误，执行清理..."
    
    # 停止服务
    run_as_root systemctl stop danted 2>/dev/null || true
    run_as_root systemctl disable danted 2>/dev/null || true
    
    print_info "查看日志文件获取详细信息: $LOG_FILE"
}

#===============================================================================
# 主函数
#===============================================================================

main() {
    # 初始化日志文件
    run_as_root mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    run_as_root touch "$LOG_FILE" 2>/dev/null || true
    run_as_root chmod 666 "$LOG_FILE" 2>/dev/null || true
    
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                                   ║${NC}"
    echo -e "${BLUE}║         SOCKS5 代理服务器 - 全自动无人值守部署脚本                ║${NC}"
    echo -e "${BLUE}║                        版本: 2.0                                  ║${NC}"
    echo -e "${BLUE}║                                                                   ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log "INFO" "========== 开始部署 =========="
    log "INFO" "部署时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "当前用户: $(whoami)"
    
    # 设置错误处理
    trap cleanup_on_error ERR
    
    # 执行部署步骤
    print_step "预检查: 系统环境检测"
    
    check_privileges || exit 1
    detect_os || exit 1
    detect_architecture
    
    install_dependencies || exit 1
    install_dante || exit 1
    create_proxy_user || exit 1
    configure_dante || exit 1
    start_dante_service || exit 1
    configure_firewall || exit 1
    
    # 测试代理
    echo ""
    test_proxy
    
    # 显示结果
    show_result
    
    log "INFO" "========== 部署完成 =========="
    
    exit 0
}

#===============================================================================
# 执行
#===============================================================================

main "$@"
