#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

# 检测操作系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法检测操作系统类型"
    exit 1
fi

# 检查软件是否已安装
check_installed() {
    if command -v $1 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 安装依赖函数
install_dependencies() {
    echo "检查必要软件..."
    
    # 检查包管理器
    if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        # 检查是否有 dnf 命令
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
        else
            PKG_MANAGER="yum"
        fi
    fi
    
    # 检查并安装 nginx
    if ! check_installed nginx; then
        echo "正在安装 Nginx..."
        case $OS in
            ubuntu|debian)
                apt update
                apt install -y nginx
                ;;
            centos|rhel|fedora)
                $PKG_MANAGER install -y epel-release
                $PKG_MANAGER install -y nginx
                ;;
        esac
    else
        echo "Nginx 已安装"
    fi

    # 检查并安装 certbot
    if ! check_installed certbot; then
        echo "正在安装 Certbot..."
        case $OS in
            ubuntu|debian)
                apt update
                apt install -y certbot python3-certbot-nginx
                ;;
            centos|rhel|fedora)
                $PKG_MANAGER install -y certbot python3-certbot-nginx
                ;;
        esac
    else
        echo "Certbot 已安装"
    fi
}

# 设置 Nginx 配置目录
setup_nginx_dirs() {
    case $OS in
        ubuntu|debian)
            NGINX_CONF_DIR="/etc/nginx/sites-available"
            NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
            ;;
        centos|rhel|fedora)
            NGINX_CONF_DIR="/etc/nginx/conf.d"
            NGINX_ENABLED_DIR="/etc/nginx/conf.d"
            ;;
    esac
}

# 添加新的代理配置
add_proxy() {
    local domain=$1
    local port=$2
    local backend_url="http://127.0.0.1:$port"
    
    # 检查域名配置是否已存在
    if [ -f "$NGINX_CONF_DIR/$domain.conf" ]; then
        echo "警告：域名 $domain 的配置文件已存在"
        read -p "是否要覆盖？(y/n): " overwrite
        if [ "$overwrite" != "y" ]; then
            echo "操作取消"
            return 1
        fi
    fi

    # 创建 Nginx 配置文件
    cat > "$NGINX_CONF_DIR/$domain.conf" << EOF
server {
    server_name $domain;
    
    location / {
        proxy_pass $backend_url;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    # 创建符号链接（仅用于 Ubuntu/Debian）
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        ln -sf "$NGINX_CONF_DIR/$domain.conf" "$NGINX_ENABLED_DIR/"
    fi

    # 申请 SSL 证书
    # --nginx: 使用 nginx 插件，自动配置 nginx
    # -d: 指定要申请证书的域名
    # --non-interactive: 非交互模式运行
    # --agree-tos: 同意服务条款
    # --email: 设置联系邮箱，用于证书过期提醒等通知
    certbot --nginx -d $domain --non-interactive --agree-tos --email dynamicbeam@163.com
    nginx -s reload
    echo "域名 $domain 的代理配置已添加并启用 HTTPS"
}

# 主菜单
show_menu() {
    echo "=== 当前代理配置 ==="
    list_configs
    echo
    echo "=== Nginx 代理管理脚本 ==="
    echo "1. 添加新的代理配置"
    echo "2. 查看现有代理配置"
    echo "3. 删除代理配置"
    echo "4. 退出"
    echo "======================="
}

# 查看现有配置
list_configs() {
    local found=0
    for conf in "$NGINX_CONF_DIR"/*.conf; do
        if [ -f "$conf" ]; then
            found=1
            domain=$(grep "server_name" "$conf" | awk '{print $2}' | sed 's/;//')
            port=$(grep "proxy_pass" "$conf" | awk -F':' '{print $3}' | sed 's/;//')
            ssl_status="HTTP"
            if grep -q "ssl" "$conf"; then
                ssl_status="HTTPS"
            fi
            echo "域名: $domain, 端口: $port, 状态: $ssl_status"
        fi
    done
    if [ $found -eq 0 ]; then
        echo "当前没有代理配置"
    fi
}

# 删除配置
delete_config() {
    list_configs
    read -p "请输入要删除的域名: " domain
    if [ -f "$NGINX_CONF_DIR/$domain.conf" ]; then
        # 删除 SSL 证书和配置
        echo "正在删除 SSL 证书..."
        certbot delete --cert-name $domain --non-interactive

        # 删除 Nginx 配置文件
        rm -f "$NGINX_CONF_DIR/$domain.conf"
        if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
            rm -f "$NGINX_ENABLED_DIR/$domain.conf"
        fi
        
        echo "配置和证书已删除"
        nginx -s reload
    else
        echo "未找到该域名的配置"
    fi
}

# 安装必要的软件包
install_dependencies

# 设置 Nginx 配置目录
setup_nginx_dirs

# 确保 Nginx 服务启动
systemctl enable nginx
systemctl start nginx

# 设置自动续期的 cron 任务（如果还没设置）
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
fi

# 主循环
while true; do
    show_menu
    read -p "请选择操作 (1-4): " choice
    case $choice in
        1)
            read -p "请输入域名 (例如: example.com): " domain
            read -p "请输入本地端口 (例如: 3000): " port
            add_proxy "$domain" "$port"
            ;;
        2)
            list_configs
            ;;
        3)
            delete_config
            ;;
        4)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效的选择"
            ;;
    esac
    echo
    read -p "按回车键继续..."
done 