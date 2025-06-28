#!/usr/bin/env bash
set -e

echo "🚀 启动GCP账号管理系统..."

# 等待MySQL就绪
echo "⏳ 等待MySQL数据库就绪..."
while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --silent 2>/dev/null; do
    echo "MySQL还未就绪，等待5秒..."
    sleep 5
done
echo "✅ MySQL数据库已就绪"

# 等待Redis就绪（如果启用）
if [ ! -z "${REDIS_HOST}" ]; then
    echo "⏳ 等待Redis就绪..."
    while ! redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ${REDIS_PASSWORD:+-a "${REDIS_PASSWORD}"} ping > /dev/null 2>&1; do
        echo "Redis还未就绪，等待3秒..."
        sleep 3
    done
    echo "✅ Redis已就绪"
fi

# 创建必要的目录
echo "📁 创建必要的目录..."
mkdir -p /app/accounts/{fresh,uploaded,exhausted_300,activated,exhausted_100,archive}
mkdir -p /app/logs

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
    exit(1)
" || {
    echo "⚠️  数据库初始化失败，但继续启动..."
}

# 设置正确的文件权限（添加错误处理）
echo "🔐 设置文件权限..."
chown -R appuser:appuser /app/accounts /app/logs 2>/dev/null || {
    echo "⚠️  权限设置失败，可能权限不足，继续启动..."
}

echo "🎯 启动应用服务..."

# 使用supervisor启动多个服务
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf