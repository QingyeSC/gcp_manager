# GCP账号管理系统 API 文档

## 概述

本文档描述了GCP账号管理系统提供的RESTful API接口。所有API响应均为JSON格式。

## 基础信息

- **基础URL**: `http://your-server:5000`
- **Content-Type**: `application/json`
- **编码**: UTF-8

## API接口列表

### 1. 健康检查

检查系统运行状态。

**接口地址**: `GET /health`

**响应示例**:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T12:00:00"
}
```

**状态码**:
- `200`: 系统正常
- `500`: 系统异常

---

### 2. 获取统计信息

获取系统账号统计数据。

**接口地址**: `GET /api/stats`

**响应示例**:
```json
{
  "total_accounts": 45,
  "active_channels": 30,
  "disabled_channels": 15,
  "pending_activation": 5,
  "exhausted_100": 3,
  "fresh_groups": 10,
  "activated_groups": 8
}
```

---

### 3. 激活账号组

将用完300刀额度的账号组激活为可使用100刀额度。

**接口地址**: `POST /api/activate`

**请求参数**:
```json
{
  "account_prefix": "proj-alice-vip"
}
```

**响应示例**:
```json
{
  "success": true,
  "message": "账号组 proj-alice-vip 已成功激活"
}
```

**错误响应**:
```json
{
  "success": false,
  "message": "激活失败，请检查文件是否完整"
}
```

---

### 4. 清理账号组

清理已用完100刀额度的账号组。

**接口地址**: `POST /api/cleanup`

**请求参数**:
```json
{
  "account_prefix": "proj-alice-vip",
  "action": "archive"
}
```

**参数说明**:
- `account_prefix`: 账号组前缀
- `action`: 操作类型
  - `archive`: 归档到archive目录
  - `delete`: 直接删除

**响应示例**:
```json
{
  "success": true,
  "message": "账号组 proj-alice-vip 已归档"
}
```

---

### 5. 单文件上传

上传单个JSON服务账号文件。

**接口地址**: `POST /api/upload-json`

**请求类型**: `multipart/form-data`

**请求参数**:
- `file`: JSON文件 (必须是有效的GCP服务账号密钥文件)

**响应示例**:
```json
{
  "success": true,
  "message": "文件 proj-alice-vip-01.json 上传成功",
  "filename": "proj-alice-vip-01.json",
  "project_id": "proj-alice-vip-01",
  "client_email": "sa@proj-alice-vip-01.iam.gserviceaccount.com"
}
```

**错误响应**:
```json
{
  "success": false,
  "message": "JSON文件格式错误"
}
```

---

### 6. 批量文件上传

批量上传多个JSON服务账号文件。

**接口地址**: `POST /api/batch-upload-json`

**请求类型**: `multipart/form-data`

**请求参数**:
- `files`: 多个JSON文件

**响应示例**:
```json
{
  "success": true,
  "message": "批量上传完成: 3/3 个文件成功",
  "total": 3,
  "success_count": 3,
  "results": [
    {
      "filename": "proj-alice-vip-01.json",
      "success": true,
      "message": "上传成功",
      "project_id": "proj-alice-vip-01",
      "client_email": "sa@proj-alice-vip-01.iam.gserviceaccount.com"
    }
  ]
}
```

---

## 错误处理

### HTTP状态码

- `200`: 请求成功
- `400`: 请求参数错误
- `404`: 资源不存在
- `409`: 资源冲突（如文件已存在）
- `500`: 服务器内部错误

### 标准错误响应格式

```json
{
  "error": "错误描述信息"
}
```

---

## 使用示例

### curl 示例

#### 1. 检查系统状态
```bash
curl -X GET http://localhost:5000/health
```

#### 2. 获取统计信息
```bash
curl -X GET http://localhost:5000/api/stats
```

#### 3. 激活账号组
```bash
curl -X POST http://localhost:5000/api/activate \
  -H "Content-Type: application/json" \
  -d '{"account_prefix": "proj-alice-vip"}'
```

#### 4. 上传JSON文件
```bash
curl -X POST http://localhost:5000/api/upload-json \
  -F "file=@service-account.json"
```

#### 5. 批量上传文件
```bash
curl -X POST http://localhost:5000/api/batch-upload-json \
  -F "files=@file1.json" \
  -F "files=@file2.json" \
  -F "files=@file3.json"
```

---

### JavaScript示例

#### 使用fetch上传文件
```javascript
const uploadFile = async (file) => {
  const formData = new FormData();
  formData.append('file', file);
  
  const response = await fetch('/api/upload-json', {
    method: 'POST',
    body: formData
  });
  
  const result = await response.json();
  return result;
};
```

#### 激活账号组
```javascript
const activateAccount = async (accountPrefix) => {
  const response = await fetch('/api/activate', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      account_prefix: accountPrefix
    })
  });
  
  const result = await response.json();
  return result;
};
```

---

## 文件格式要求

### JSON服务账号文件格式

上传的JSON文件必须是有效的GCP服务账号密钥文件，包含以下必要字段：

```json
{
  "type": "service_account",
  "project_id": "your-project-id",
  "private_key_id": "key-id",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "client_email": "service-account@project.iam.gserviceaccount.com",
  "client_id": "123456789",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
```

### 文件命名规范

建议的文件命名格式：
- 新账号: `proj-前缀-vip-01.json`, `proj-前缀-vip-02.json`, `proj-前缀-vip-03.json`
- 激活账号: `proj-前缀-vip-01-actived.json`
- 归档账号: `proj-前缀-vip-01-used.json`

---

## 注意事项

1. **文件大小限制**: 单个文件最大16MB
2. **并发限制**: 建议不超过5个并发请求
3. **重试机制**: 上传失败请重试，系统会自动检测重复文件
4. **安全性**: 生产环境请启用HTTPS和认证机制

---

## 版本信息

- **API版本**: v1.0
- **最后更新**: 2024-01-01
- **兼容性**: 支持现代浏览器和HTTP客户端