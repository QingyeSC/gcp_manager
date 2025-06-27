# mysql/init/01-init.sql
-- 初始化数据库脚本
CREATE DATABASE IF NOT EXISTS gcp_accounts CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE gcp_accounts;

-- 账号状态表
CREATE TABLE IF NOT EXISTS account_status (
    id INT AUTO_INCREMENT PRIMARY KEY,
    account_name VARCHAR(255) UNIQUE NOT NULL,
    current_status VARCHAR(50) NOT NULL,
    file_path VARCHAR(500),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    used_quota BIGINT DEFAULT 0,
    is_activated BOOLEAN DEFAULT FALSE,
    activation_date TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_account_name (account_name),
    INDEX idx_current_status (current_status),
    INDEX idx_last_updated (last_updated)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 状态变更历史表
CREATE TABLE IF NOT EXISTS status_history (
    id INT AUTO_INCREMENT PRIMARY KEY,
    account_name VARCHAR(255) NOT NULL,
    old_status VARCHAR(50),
    new_status VARCHAR(50) NOT NULL,
    change_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    used_quota BIGINT DEFAULT 0,
    remarks TEXT,
    INDEX idx_account_name (account_name),
    INDEX idx_change_time (change_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 操作日志表
CREATE TABLE IF NOT EXISTS operation_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    operation_type VARCHAR(50) NOT NULL,
    account_name VARCHAR(255),
    details JSON,
    operator VARCHAR(100),
    operation_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    INDEX idx_operation_type (operation_type),
    INDEX idx_operation_time (operation_time),
    INDEX idx_account_name (account_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 系统配置表
CREATE TABLE IF NOT EXISTS system_config (
    id INT AUTO_INCREMENT PRIMARY KEY,
    config_key VARCHAR(100) UNIQUE NOT NULL,
    config_value TEXT,
    description VARCHAR(255),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_config_key (config_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 插入默认配置
INSERT IGNORE INTO system_config (config_key, config_value, description) VALUES
('min_channels', '10', '最小渠道数量'),
('target_channels', '15', '目标渠道数量'),
('check_interval', '300', '检查间隔（秒）'),
('last_check_time', '', '最后检查时间');

---