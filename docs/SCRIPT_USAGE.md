# GCP项目创建脚本使用说明

## 🎯 功能特性

这个脚本的主要功能：
- 批量创建GCP项目
- 每个项目创建**1个服务账号**
- 自动下载服务账号密钥
- **直接上传JSON到管理系统**
- 移除了管理员服务账号创建

## 📋 使用前准备

### 1. 安装Google Cloud SDK
```bash
# 安装gcloud命令行工具
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud init
```

### 2. 登录Google Cloud
```bash
gcloud auth login
```

### 3. 配置脚本环境变量
```bash
# 设置JSON上传API地址（必需）
export UPLOAD_API_URL="http://your-server:5000/api/upload-json"

# 设置API认证TOKEN（可选，如果需要认证）
export UPLOAD_API_TOKEN="your-api-token"
```

## 🚀 运行脚本

### 基本用法
```bash
# 创建3个项目（默认）
./create_gcp_projects.sh

# 创建指定数量的项目
./create_gcp_projects.sh 5
```

### 执行流程
脚本会按以下步骤执行：

1. **检查环境**: 验证gcloud安装和登录状态
2. **获取账单信息**: 列出所有可用的账单账户
3. **解绑现有项目**: 清理账单绑定（可选）
4. **创建项目**: 批量创建指定数量的项目
5. **绑定账单**: 循环绑定可用账单
6. **启用API**: 为每个项目启用必要的API服务
7. **创建服务账号**: 每个项目创建3个服务账号
8. **处理密钥**: 下载密钥并上传到管理系统

## 📁 文件命名规则

### 项目命名
```
proj-{邮箱前5位}-vip-{序号}
```
例如：`proj-alice-vip-01`, `proj-alice-vip-02`

### 服务账号命名
```
{项目ID}
```
例如：`proj-alice-vip-01`, `proj-alice-vip-02`, `proj-alice-vip-03`

### 密钥文件命名
```
{项目ID}.json
```
例如：`proj-alice-vip-01.json`, `proj-alice-vip-02.json`, `proj-alice-vip-03.json`

## 🔧 配置选项

在脚本开头可以修改以下配置：

```bash
# 要创建的项目数量
PROJECT_COUNT=${1:-3}

# 每个项目创建的服务账号数量
SERVICE_ACCOUNTS_PER_PROJECT=1

# 并发控制
MAX_PARALLEL_JOBS=5

# 重试配置
MAX_RETRIES=3
BASE_RETRY_DELAY=5

# JSON上传配置
UPLOAD_API_URL="${UPLOAD_API_URL:-http://localhost:5000/api/upload-json}"
UPLOAD_API_TOKEN="${UPLOAD_API_TOKEN:-}"
```

## 📡 API接口详情

### 单文件上传接口
```bash
POST /api/upload-json
Content-Type: multipart/form-data

# 使用curl测试
curl -X POST \
  -F "file=@your-service-account.json" \
  http://your-server:5000/api/upload-json
```

### 批量上传接口
```bash
POST /api/batch-upload-json
Content-Type: multipart/form-data

# 使用curl批量上传
curl -X POST \
  -F "files=@file1.json" \
  -F "files=@file2.json" \
  -F "files=@file3.json" \
  http://your-server:5000/api/batch-upload-json
```

### API响应格式
```json
{
  "success": true,
  "message": "文件上传成功",
  "filename": "proj-alice-vip-01-01.json",
  "project_id": "proj-alice-vip-01",
  "client_email": "proj-alice-vip-01-01@proj-alice-vip-01.iam.gserviceaccount.com"
}
```

## 🛠️ 故障排除

### 常见问题

**1. 脚本权限问题**
```bash
chmod +x create_gcp_projects.sh
```

**2. gcloud未登录**
```bash
gcloud auth login
gcloud auth list
```

**3. API配额限制**
- 降低并发数: 修改 `MAX_PARALLEL_JOBS=2`
- 增加重试延迟: 修改 `BASE_RETRY_DELAY=10`

**4. 上传API连接失败**
```bash
# 检查API地址是否正确
curl -I http://your-server:5000/health

# 检查网络连接
ping your-server
```

**5. JSON文件验证失败**
确保JSON文件包含以下必要字段：
- `type`: "service_account"
- `project_id`
- `private_key_id`
- `private_key`
- `client_email`

### 日志查看
脚本执行过程中的日志保存在临时目录：
```bash
# 查看进度文件
ls /tmp/gcp_script_*/

# 查看创建成功的项目
cat /tmp/gcp_script_*/created_projects

# 查看服务账号信息
cat /tmp/gcp_script_*/service_accounts
```

## 📊 执行结果

脚本执行完成后会显示详细的总结报告，包括：

- ✅ 成功创建的项目数量
- 💳 绑定的账单信息
- 👤 创建的服务账号统计
- 🔑 密钥文件处理结果
- 📈 整体成功率统计

### 本地文件处理
- **上传成功**: JSON文件会自动删除，避免本地堆积
- **上传失败**: JSON文件保留在当前目录，可手动处理
- **网络问题**: 所有文件保留本地，稍后可批量上传

## 💡 最佳实践

1. **测试环境**: 先用小数量测试（如1-2个项目）
2. **网络稳定**: 确保网络连接稳定，避免上传中断
3. **权限检查**: 确保有足够的GCP权限创建项目和服务账号
4. **监控配额**: 注意GCP项目数量和API调用配额
5. **备份策略**: 重要操作前备份现有配置

## 🔐 安全注意事项

1. **API Token**: 如果使用认证，确保Token安全性
2. **网络传输**: 建议使用HTTPS传输JSON文件
3. **本地清理**: 脚本会自动清理上传成功的本地文件
4. **权限最小化**: 服务账号只授予必要的Vertex AI权限

---

## 示例完整流程

```bash
# 1. 设置环境变量
export UPLOAD_API_URL="http://192.168.1.100:5000/api/upload-json"

# 2. 运行脚本创建5个项目
./create_gcp_projects.sh 5

# 3. 查看执行结果
# 脚本会自动显示详细的执行报告
# 5个项目 = 5个服务账号 = 5个JSON文件
```

这样你就能自动化创建GCP项目，每个项目3个服务账号，并直接上传到管理系统中！