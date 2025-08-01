#!/usr/bin/env bash
set -e

echo "🚀 启动GCP账号管理系统 (Root权限模式)..."

# 创建必要的目录（使用root权限直接创建）
echo "📁 创建必要的目录..."
mkdir -p /app/accounts/fresh
mkdir -p /app/accounts/uploaded
mkdir -p /app/accounts/exhausted_300
mkdir -p /app/accounts/activated
mkdir -p /app/accounts/exhausted_100
mkdir -p /app/accounts/archive
mkdir -p /app/logs
mkdir -p /app/config

# 设置目录权限
chmod -R 755 /app/accounts /app/logs /app/config

echo "✅ 目录创建完成"

# 等待MySQL就绪
echo "⏳ 等待MySQL数据库就绪..."
DB_HOST=${DB_HOST:-mysql}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_PASSWORD=${DB_PASSWORD:-root_password_123}

max_attempts=30
attempt=0
while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --silent 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
        echo "❌ MySQL连接超时，已尝试 $max_attempts 次"
        exit 1
    fi
    echo "MySQL还未就绪，等待5秒... ($attempt/$max_attempts)"
    sleep 5
done
echo "✅ MySQL数据库已就绪"

# 等待Redis就绪（如果启用）
if [ ! -z "${REDIS_HOST}" ]; then
    echo "⏳ 等待Redis就绪..."
    REDIS_PORT=${REDIS_PORT:-6379}
    max_attempts=10
    attempt=0
    while ! redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ${REDIS_PASSWORD:+-a "${REDIS_PASSWORD}"} ping > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "⚠️ Redis连接超时，继续启动..."
            break
        fi
        echo "Redis还未就绪，等待3秒... ($attempt/$max_attempts)"
        sleep 3
    done
    if [ $attempt -lt $max_attempts ]; then
        echo "✅ Redis已就绪"
    fi
fi

# 初始化数据库（如果需要）
echo "🗄️  初始化数据库表..."
export PYTHONPATH=/app:$PYTHONPATH
python3 -c "
import sys
sys.path.insert(0, '/app')
try:
    from scripts.monitor import GCPAccountManager
    manager = GCPAccountManager()
    print('✅ 数据库初始化完成')
except Exception as e:
    print(f'❌ 数据库初始化失败: {e}')
    import traceback
    traceback.print_exc()
    # 不退出，继续启动
" || {
    echo "⚠️  数据库初始化失败，但继续启动..."
}

echo "🎯 启动应用服务..."

# 使用supervisor启动多个服务
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
