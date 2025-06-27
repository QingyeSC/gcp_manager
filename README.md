# GCP账号管理系统 (Docker版本)

一个基于Docker的完整GCP服务账号自动化管理解决方案，集成MySQL数据库、Redis缓存、Web管理界面和自动监控系统。

## 🎯 系统特性

- **🐳 Docker化部署**: 一键部署，开箱即用
- **🗄️ MySQL数据库**: 持久化存储，支持集群
- **⚡ Redis缓存**: 高性能会话管理和缓存
- **🌐 Web管理界面**: 直观的账号管理面板
- **🤖 自动监控**: 实时监控New API状态，智能补充渠道
- **📊 状态管理**: 完整的账号生命周期管理
- **🔧 多进程架构**: 监控、Web面板、调度器独立运行
- **📈 健康检查**: 完整的服务健康监控

## 📁 项目结构

```
gcp_account_manager/
├── docker-compose.yml          # Docker编排文件
├── Dockerfile                  # 应用镜像构建文件
├── .env.example               # 环境变量模板
├── requirements.txt           # Python依赖
├── accounts/                  # 账号文件存储（挂载卷）
│   ├── fresh/                # 新账号池
│   ├── uploaded/             # 已上传使用中
│   ├── exhausted_300/        # 300刀用完，待激活
│   ├── activated/            # 已激活账号
│   ├── exhausted_100/        # 100刀用完
│   └── archive/              # 归档账号
├── scripts/                  # 核心脚本
│   ├── monitor.py           # 监控脚本
│   └── scheduler.py         # 调度脚本
├── app.py                   # Web应用主文件
├── templates/               # Web模板
├── config/                  # 配置文件
│   └── settings.json       # 主配置
├── logs/                    # 日志文件（挂载卷）
├── docker/                  # Docker配置
│   ├── entrypoint.sh       # 启动脚本
│   ├── supervisord.conf    # 进程管理配置
│   └── healthcheck.py      # 健康检查脚本
├── mysql/                   # MySQL配置
│   ├── init/               # 初始化SQL脚本
│   └── conf/               # 配置文件
└── nginx/                   # Nginx配置
    └── nginx.conf          # 反向代理配置
```

## 🚀 快速部署

### 1. 环境准备

确保您的服务器已安装：
- Docker (20.10+)
- Docker Compose (2.0+)

```bash
# 检查Docker版本
docker --version
docker-compose --version
```

### 2. 获取项目文件

```bash
# 下载项目文件到服务器
cd /opt
git clone <your-repo-url> gcp_account_manager
cd gcp_account_manager
```

### 3. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑环境变量
nano .env
```

**重要配置项：**
```bash
# 数据库配置
MYSQL_ROOT_PASSWORD=your_secure_root_password
MYSQL_PASSWORD=your_secure_password

# New API配置
NEW_API_BASE_URL=http://152.53.166.175:3058
NEW_API_TOKEN=your_new_api_token_here

# 安全配置
SECRET_KEY=your_very_secure_secret_key_here
REDIS_PASSWORD=your_redis_password_here
```

### 4. 准备账号文件

将您的GCP服务账号JSON文件放入相应目录：

```bash
# 创建账号目录
mkdir -p accounts/fresh

# 复制JSON文件到fresh目录
# 文件命名格式: proj-账号名-vip-01.json, proj-账号名-vip-02.json, proj-账号名-vip-03.json
cp /path/to/your/json/files/* accounts/fresh/
```

### 5. 启动系统

```bash
# 启动所有服务
docker-compose up -d

# 查看启动状态
docker-compose ps

# 查看日志
docker-compose logs -f
```

### 6. 访问系统

- **Web管理界面**: http://your-server-ip:5000
- **Nginx代理** (如果启用): http://your-server-ip
- **数据库**: your-server-ip:3306
- **Redis**: your-server-ip:6379

## 📊 服务架构

### 核心服务

1. **MySQL数据库**
   - 存储账号状态和历史记录
   - 持久化配置信息
   - 支持连接池和集群

2. **Redis缓存**
   - 会话存储
   - 缓存常用数据
   - 提升性能

3. **应用服务**
   - **监控进程**: 自动检测和补充渠道
   - **Web界面**: 账号管理和状态展示
   - **调度器**: 定时任务和清理工作

4. **Nginx反向代理** (可选)
   - 负载均衡
   - SSL终止
   - 静态文件服务

## 🛠️ 管理操作

### 查看系统状态

```bash
# 查看所有服务状态
docker-compose ps

# 查看特定服务日志
docker-compose logs monitor
docker-compose logs web_panel
docker-compose logs mysql

# 实时查看日志
docker-compose logs -f gcp_manager
```

### 备份和恢复

```bash
# 备份数据库
docker-compose exec mysql mysqldump -u root -p gcp_accounts > backup.sql

# 备份账号文件
tar -czf accounts_backup.tar.gz accounts/

# 恢复数据库
docker-compose exec -T mysql mysql -u root -p gcp_accounts < backup.sql
```

### 更新系统

```bash
# 拉取最新代码
git pull origin main

# 重新构建并启动
docker-compose down
docker-compose up -d --build
```

### 扩展部署

```bash
# 扩展应用实例
docker-compose up -d --scale gcp_manager=3

# 查看扩展状态
docker-compose ps
```

## 🔧 配置说明

### 环境变量配置

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `NEW_API_BASE_URL` | New API服务器地址 | - |
| `NEW_API_TOKEN` | API访问令牌 | - |
| `MIN_CHANNELS` | 最小渠道数量 | 10 |
| `TARGET_CHANNELS` | 目标渠道数量 | 15 |
| `CHECK_INTERVAL` | 检查间隔（秒） | 300 |
| `MYSQL_ROOT_PASSWORD` | MySQL root密码 | - |
| `MYSQL_PASSWORD` | 应用数据库密码 | - |
| `REDIS_PASSWORD` | Redis密码 | - |
| `SECRET_KEY` | Web应用密钥 | - |

### 数据库配置

MySQL支持以下优化配置：
- 连接池大小：10-20
- 查询缓存：64MB
- InnoDB缓冲池：256MB
- 慢查询日志：启用

### 监控配置

系统提供多层监控：
- 容器健康检查
- 应用健康检查端点
- 数据库连接监控
- 文件系统监控

## 📱 Web界面功能

### 仪表板页面
- 📊 实时系统状态统计
- 🔄 渠道状态总览
- ⚡ 快速操作入口
- 📈 历史趋势图表

### 待激活账号管理
- 📋 待激活账号列表
- ✅ 批量激活操作
- 📝 激活状态跟踪
- 💰 额度使用情况

### 账号清理管理
- 🗑️ 用完账号清理
- 📦 批量归档操作
- 🔍 详细使用记录
- 💾 存储空间管理

## 🚨 故障排除

### 常见问题

**1. 服务启动失败**
```bash
# 检查端口占用
netstat -tlnp | grep -E ':(3306|5000|6379)'

# 检查磁盘空间
df -h

# 查看详细错误
docker-compose logs service_name
```

**2. 数据库连接失败**
```bash
# 检查MySQL服务状态
docker-compose exec mysql mysqladmin ping -h localhost

# 重置数据库密码
docker-compose exec mysql mysql -u root -p
```

**3. 账号上传失败**
```bash
# 检查网络连接
docker-compose exec gcp_manager curl -I http://152.53.166.175:3058

# 验证JSON文件格式
python -m json.tool accounts/fresh/example.json
```

**4. Web界面无法访问**
```bash
# 检查端口映射
docker-compose port gcp_manager 5000

# 检查防火墙设置
sudo ufw status
```

### 性能优化

**1. 数据库优化**
```sql
-- 查看连接数
SHOW PROCESSLIST;

-- 查看缓存命中率
SHOW STATUS LIKE 'Qcache%';

-- 分析慢查询
SELECT * FROM mysql.slow_log ORDER BY start_time DESC LIMIT 10;
```

**2. 应用优化**
- 增加检查间隔减少资源消耗
- 使用Redis缓存频繁查询
- 定期清理历史日志

**3. 容器优化**
```yaml
# docker-compose.yml中添加资源限制
services:
  gcp_manager:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
```

## 🔒 安全建议

1. **更改默认密码**: 使用强密码替换所有默认密码
2. **网络隔离**: 使用防火墙限制不必要的端口访问
3. **SSL/TLS**: 在生产环境中启用HTTPS
4. **定期备份**: 建立自动备份策略
5. **日志监控**: 配置日志告警和分析
6. **权限控制**: 限制容器运行权限

## 📈 监控和告警

### 系统监控
- CPU和内存使用率
- 磁盘空间占用
- 网络连接状态
- 数据库性能指标

### 业务监控
- 渠道可用数量
- 账号激活成功率
- 上传失败率
- 响应时间

### 告警配置
可以集成以下告警方式：
- 邮件通知
- Telegram Bot
- Slack消息
- Webhook回调

## 💡 最佳实践

1. **定期检查**: 每天检查待激活账号状态
2. **批量操作**: 利用批量功能提高效率
3. **文件备份**: 重要操作前备份账号文件
4. **监控告警**: 配置低渠道数告警
5. **日志分析**: 定期分析日志发现问题
6. **性能调优**: 根据使用情况调整配置

## 🤝 技术支持

如有问题请通过以下方式联系：
- 提交Issue到项目仓库
- 查看详细日志文件
- 参考故障排除文档

---

## 📄 许可证

本项目基于MIT许可证开源。