# GCP账号管理系统部署指南

## 目录
- [系统要求](#系统要求)
- [快速部署](#快速部署)
- [生产环境部署](#生产环境部署)
- [配置说明](#配置说明)
- [维护操作](#维护操作)
- [故障排除](#故障排除)

---

## 系统要求

### 硬件要求
- **CPU**: 2核以上
- **内存**: 4GB以上
- **存储**: 20GB以上可用空间
- **网络**: 稳定的互联网连接

### 软件要求
- **操作系统**: Linux (Ubuntu 20.04+/CentOS 8+/Debian 11+)
- **Docker**: 20.10+
- **Docker Compose**: 2.0+
- **端口**: 3306, 5000, 6379, 80, 443

### 依赖检查
```bash
# 检查Docker版本
docker --version
docker-compose --version

# 检查端口占用
sudo netstat -tlnp | grep -E ':(3306|5000|6379|80|443)'

# 检查磁盘空间
df -h
```

---

## 快速部署

### 1. 获取项目文件
```bash
# 下载项目到服务器
cd /opt
git clone <your-repo-url> gcp_account_manager
cd gcp_account_manager

# 或通过其他方式上传项目文件包
```

### 2. 配置环境变量
```bash
# 复制环境变量模板
cp .env.example .env

# 编辑配置文件
nano .env
```

**必须配置的环境变量**:
```bash
# 数据库配置
MYSQL_ROOT_PASSWORD=your_secure_root_password_here
MYSQL_PASSWORD=your_secure_password_here

# New API配置  
NEW_API_BASE_URL=http://152.53.166.175:3058
NEW_API_TOKEN=your_new_api_token_here

# 安全配置
SECRET_KEY=your_very_secure_secret_key_here
REDIS_PASSWORD=your_redis_password_here
```

### 3. 启动服务
```bash
# 启动所有服务
docker-compose up -d

# 查看启动状态
docker-compose ps

# 查看日志
docker-compose logs -f
```

### 4. 验证部署
```bash
# 检查Web界面
curl -I http://localhost:5000

# 检查健康状态
curl http://localhost:5000/health

# 检查数据库连接
docker-compose exec mysql mysqladmin ping -h localhost
```

---

## 生产环境部署

### 1. 安全配置

#### SSL/TLS证书配置
```bash
# 创建SSL证书目录
mkdir -p nginx/ssl

# 复制证书文件
cp your-domain.crt nginx/ssl/
cp your-domain.key nginx/ssl/

# 更新nginx配置启用HTTPS
```

#### 防火墙配置
```bash
# Ubuntu/Debian
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp  
sudo ufw allow 443/tcp
sudo ufw enable

# CentOS/RHEL
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### 2. 性能优化

#### Docker Compose 生产配置
```yaml
# docker-compose.prod.yml
version: '3.8'
services:
  gcp_manager:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '1.0'
          memory: 1G
      restart_policy:
        condition: on-failure
        max_attempts: 3
    environment:
      - WEB_DEBUG=false
      - WEB_WORKERS=4
```

#### 数据库优化
```sql
-- 性能调优配置
SET GLOBAL innodb_buffer_pool_size = 1073741824;  -- 1GB
SET GLOBAL query_cache_size = 134217728;          -- 128MB
SET GLOBAL max_connections = 300;
```

### 3. 监控配置

#### 系统监控
```bash
# 安装监控工具
sudo apt install htop iotop nethogs

# 设置日志轮转
sudo nano /etc/logrotate.d/gcp-manager
```

```bash
# /etc/logrotate.d/gcp-manager
/opt/gcp_account_manager/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
}
```

---

## 配置说明

### 环境变量详解

| 变量名 | 必需 | 默认值 | 说明 |
|--------|------|--------|------|
| `MYSQL_ROOT_PASSWORD` | ✓ | - | MySQL root密码 |
| `MYSQL_PASSWORD` | ✓ | - | 应用数据库密码 |
| `NEW_API_BASE_URL` | ✓ | - | New API服务器地址 |
| `NEW_API_TOKEN` | ✓ | - | New API访问令牌 |
| `SECRET_KEY` | ✓ | - | Web应用密钥(至少32位) |
| `REDIS_PASSWORD` | ✓ | - | Redis密码 |
| `MIN_CHANNELS` | ✗ | 10 | 最小渠道数量 |
| `TARGET_CHANNELS` | ✗ | 15 | 目标渠道数量 |
| `CHECK_INTERVAL` | ✗ | 300 | 检查间隔(秒) |
| `WEB_DEBUG` | ✗ | false | Web调试模式 |

### 高级配置

#### 1. 修改监控间隔
```bash
# 在 .env 文件中设置
CHECK_INTERVAL=180  # 3分钟检查一次
```

#### 2. 调整并发数
```json
// config/settings.json
{
  "monitoring": {
    "concurrent_uploads": 5,
    "upload_timeout": 30
  }
}
```

#### 3. 配置通知
```json
{
  "notifications": {
    "webhook_url": "https://hooks.slack.com/services/xxx",
    "telegram": {
      "bot_token": "your_bot_token",
      "chat_id": "your_chat_id"
    }
  }
}
```

---

## 维护操作

### 1. 数据备份

#### 自动备份
```bash
# 系统自动执行(每日3点)
# 手动执行备份
docker-compose exec mysql mysqldump -u root -p gcp_accounts > backup_$(date +%Y%m%d).sql
```

#### 备份恢复
```bash
# 恢复数据库
docker-compose exec -T mysql mysql -u root -p gcp_accounts < backup_20240101.sql

# 恢复账号文件
tar -xzf accounts_backup_20240101.tar.gz
```

### 2. 更新系统

#### 更新应用
```bash
# 停止服务
docker-compose down

# 拉取最新代码
git pull origin main

# 重新构建并启动
docker-compose up -d --build

# 查看更新状态
docker-compose logs -f gcp_manager
```

#### 更新依赖
```bash
# 重新构建镜像
docker-compose build --no-cache

# 清理旧镜像
docker image prune -f
```

### 3. 日志管理

#### 查看日志
```bash
# 查看所有服务日志
docker-compose logs

# 查看特定服务日志
docker-compose logs gcp_manager
docker-compose logs mysql
docker-compose logs redis

# 实时查看日志
docker-compose logs -f --tail=100 gcp_manager
```

#### 清理日志
```bash
# 清理Docker日志
docker system prune -f

# 清理应用日志
find ./logs -name "*.log" -mtime +30 -delete
```

### 4. 扩容操作

#### 垂直扩容(增加资源)
```yaml
# docker-compose.yml
services:
  gcp_manager:
    deploy:
      resources:
        limits:
          cpus: '4.0'     # 增加CPU
          memory: 4G      # 增加内存
```

#### 水平扩容(多实例)
```bash
# 启动多个应用实例
docker-compose up -d --scale gcp_manager=3

# 配置负载均衡器
```

---

## 故障排除

### 常见问题

#### 1. 服务无法启动
```bash
# 检查端口占用
sudo netstat -tlnp | grep :5000

# 检查Docker状态
docker ps -a
docker-compose ps

# 查看错误日志
docker-compose logs gcp_manager
```

#### 2. 数据库连接失败
```bash
# 检查MySQL服务
docker-compose exec mysql mysqladmin ping

# 检查连接参数
docker-compose exec mysql mysql -u gcp_user -p

# 重置数据库密码
docker-compose exec mysql mysql -u root -p
```

#### 3. 磁盘空间不足
```bash
# 检查磁盘使用
df -h

# 清理Docker资源
docker system prune -af

# 清理日志文件
find ./logs -name "*.log" -mtime +7 -delete
```

#### 4. 内存不足
```bash
# 检查内存使用
free -h
docker stats

# 重启服务释放内存
docker-compose restart
```

### 性能问题

#### 1. 响应慢
- 检查数据库查询性能
- 增加Redis缓存
- 优化监控间隔
- 增加系统资源

#### 2. 上传失败
- 检查网络连接
- 验证API Token
- 增加超时时间
- 检查文件格式

### 紧急恢复

#### 1. 完全重启
```bash
# 停止所有服务
docker-compose down

# 清理容器和网络
docker system prune -f

# 重新启动
docker-compose up -d
```

#### 2. 数据恢复
```bash
# 从备份恢复
docker-compose down
docker volume rm gcp_account_manager_mysql_data
docker-compose up -d mysql
# 等待MySQL启动完成
docker-compose exec -T mysql mysql -u root -p gcp_accounts < latest_backup.sql
docker-compose up -d
```

---

## 监控和告警

### 系统监控指标
- CPU使用率 < 80%
- 内存使用率 < 80%  
- 磁盘使用率 < 90%
- 网络连接正常
- 数据库连接池 < 80%

### 业务监控指标
- 活跃渠道数量 >= 10
- 监控脚本运行正常
- 文件上传成功率 > 95%
- API响应时间 < 5s

### 告警设置
建议配置以下告警：
- 系统资源使用率过高
- 服务不可用
- 活跃渠道数量不足
- 数据库连接失败
- 文件上传失败率过高

---

## 联系支持

如遇到无法解决的问题，请提供：
- 系统版本信息
- 错误日志
- 操作步骤
- 环境配置

技术支持渠道：
- GitHub Issues
- 技术文档
- 社区论坛