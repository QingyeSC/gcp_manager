# 使用Python 3.11作为基础镜像
FROM python:3.11-slim

# 设置工作目录
WORKDIR /app

# 设置环境变量
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
ENV TZ=Asia/Shanghai

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    default-libmysqlclient-dev \
    default-mysql-client \
    redis-tools \
    pkg-config \
    curl \
    cron \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# 复制requirements文件并安装Python依赖
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 复制应用代码
COPY . .

# 创建用户（但还不切换）
RUN useradd -m -u 1000 appuser

# 创建必要的目录并设置权限
RUN mkdir -p /app/accounts/fresh \
             /app/accounts/uploaded \
             /app/accounts/exhausted_300 \
             /app/accounts/activated \
             /app/accounts/exhausted_100 \
             /app/accounts/archive \
             /app/logs \
             /app/config \
    && chown -R appuser:appuser /app \
    && chmod -R 755 /app/accounts \
    && chmod -R 755 /app/logs \
    && chmod -R 755 /app/config

# 设置脚本权限
RUN chmod +x /app/scripts/*.py \
    && chmod +x /app/app.py \
    && chmod +x /app/docker/entrypoint.sh

# 复制supervisor配置
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 复制健康检查脚本
COPY docker/healthcheck.py /app/healthcheck.py

# 暴露端口
EXPOSE 5000

# 最后切换到非root用户
USER appuser

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python /app/healthcheck.py

# 使用supervisor启动多个服务
ENTRYPOINT ["/app/docker/entrypoint.sh"]