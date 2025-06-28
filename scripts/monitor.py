#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
统一的GCP账号监控和管理服务
集成了完整监控和轻量监控的功能
"""

import os
import json
import time
import shutil
import requests
import mysql.connector
import argparse
from datetime import datetime, timedelta
from pathlib import Path
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/monitor.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class GCPAccountManager:
    def __init__(self, config_path="config/settings.json", mode="full"):
        """
        初始化管理器
        Args:
            config_path: 配置文件路径
            mode: 运行模式 
                - "full": 完整模式（数据库+文件管理）
                - "lite": 轻量模式（仅监控+补充）
        """
        self.mode = mode
        self.load_config(config_path)
        self.base_dir = Path("accounts")
        self.log_dir = Path("logs")
        
        # 创建必要的目录
        directories = ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]
        for dir_name in directories:
            (self.base_dir / dir_name).mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        
        # 完整模式才初始化数据库
        if self.mode == "full":
            self.init_database()
            logger.info("监控器启动 - 完整模式（数据库+文件管理）")
        else:
            logger.info("监控器启动 - 轻量模式（仅监控+补充）")
    
    def load_config(self, config_path):
    """加载配置"""
    if Path(config_path).exists():
        with open(config_path, 'r', encoding='utf-8') as f:
            self.config = json.load(f)
    else:
        # 从环境变量加载配置
        self.config = {
            "database": {
                "host": os.getenv('DB_HOST', 'mysql'),
                "port": int(os.getenv('DB_PORT', 3306)),
                "user": os.getenv('DB_USER', 'gcp_user'),
                "password": os.getenv('DB_PASSWORD', 'gcp_password_123'),
                "name": os.getenv('DB_NAME', 'gcp_accounts'),
                "charset": "utf8mb4"
            },
            "new_api": {
                "base_url": os.getenv('NEW_API_BASE_URL', 'http://152.53.166.175:3058'),
                "api_key": os.getenv('NEW_API_TOKEN', ''),
                "min_channels": int(os.getenv('MIN_CHANNELS', 10)),
                "target_channels": int(os.getenv('TARGET_CHANNELS', 15)),
                # 添加查询路径配置
                "search_path": os.getenv('NEW_API_SEARCH_PATH', '/api/channel/search'),
                "search_params": os.getenv('NEW_API_SEARCH_PARAMS', 'keyword=&group=svip&model=&id_sort=true&tag_mode=false')
            },
            "monitoring": {
                "check_interval_seconds": int(os.getenv('CHECK_INTERVAL', 300))
            }
        }
    
    def get_db_connection(self):
        """获取MySQL数据库连接"""
        if self.mode != "full":
            return None
            
        return mysql.connector.connect(
            host=self.config['database']['host'],
            port=self.config['database']['port'],
            user=self.config['database']['user'],
            password=self.config['database']['password'],
            database=self.config['database']['name'],
            charset='utf8mb4'
        )
    
    def init_database(self):
        """初始化MySQL数据库表"""
        if self.mode != "full":
            return
            
        conn = self.get_db_connection()
        cursor = conn.cursor()
        
        # 创建账号状态表
        cursor.execute('''
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
                INDEX idx_current_status (current_status)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ''')
        
        # 创建状态变更历史表
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS status_history (
                id INT AUTO_INCREMENT PRIMARY KEY,
                account_name VARCHAR(255) NOT NULL,
                old_status VARCHAR(50),
                new_status VARCHAR(50) NOT NULL,
                change_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                used_quota BIGINT DEFAULT 0,
                INDEX idx_account_name (account_name),
                INDEX idx_change_time (change_time)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ''')
        
        conn.commit()
        conn.close()
        logger.info("数据库表初始化完成")
    
    def get_new_api_status(self):
    """获取New API的所有渠道状态"""
    try:
        # 使用配置的路径和参数
        base_url = self.config['new_api']['base_url']
        search_path = self.config['new_api']['search_path']
        search_params = self.config['new_api']['search_params']
        
        api_url = f"{base_url}{search_path}?{search_params}"
        
        headers = {
            "accept": "application/json, text/plain, */*",
            "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
            "cache-control": "no-store",
            "new-api-user": "1",
            "authorization": f"Bearer {self.config['new_api']['api_key']}",
            "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
        
        logger.info(f"查询API URL: {api_url}")
        response = requests.get(api_url, headers=headers, timeout=30)
        
        if response.status_code == 200:
            data = response.json()
            if data.get('success', False):
                return data.get('data', {}).get('items', [])
            else:
                logger.error(f"API返回失败: {data.get('message', '未知错误')}")
                return []
        else:
            logger.error(f"获取API状态失败: {response.status_code}")
            return []
            
    except Exception as e:
        logger.error(f"API请求异常: {e}")
        return []
                
        except Exception as e:
            logger.error(f"API请求异常: {e}")
            return []
    
    def update_account_status(self, api_channels):
        """根据API返回更新账号状态（仅完整模式）"""
        if self.mode != "full":
            return
            
        conn = self.get_db_connection()
        cursor = conn.cursor()
        
        current_time = datetime.now()
        
        for channel in api_channels:
            name = channel.get('name', '')
            status = channel.get('status', 0)
            used_quota = channel.get('used_quota', 0)
            
            # 检查是否是激活的账号
            is_activated = '-actived' in name
            
            # 获取当前数据库中的状态
            cursor.execute(
                "SELECT current_status, used_quota FROM account_status WHERE account_name = %s",
                (name,)
            )
            result = cursor.fetchone()
            
            old_status = result[0] if result else None
            new_status = 'active' if status == 1 else 'disabled'
            
            # 如果状态改变，记录历史
            if old_status and old_status != new_status:
                cursor.execute('''
                    INSERT INTO status_history (account_name, old_status, new_status, change_time, used_quota)
                    VALUES (%s, %s, %s, %s, %s)
                ''', (name, old_status, new_status, current_time, used_quota))
                
                logger.info(f"账号状态变更: {name} {old_status} -> {new_status}")
            
            # 更新或插入账号状态
            cursor.execute('''
                INSERT INTO account_status 
                (account_name, current_status, file_path, last_updated, used_quota, is_activated)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE
                current_status = VALUES(current_status),
                last_updated = VALUES(last_updated),
                used_quota = VALUES(used_quota),
                is_activated = VALUES(is_activated)
            ''', (name, new_status, '', current_time, used_quota, is_activated))
            
            # 处理文件移动（仅完整模式）
            if status != 1:
                self.handle_disabled_account(name)
        
        conn.commit()
        conn.close()
    
    def handle_disabled_account(self, account_name):
        """处理被禁用的账号（仅完整模式）"""
        if self.mode != "full":
            return
            
        is_activated = '-actived' in account_name
        
        if is_activated:
            self.move_account_to_exhausted_100(account_name)
        else:
            self.move_account_to_exhausted_300(account_name)
    
    def move_account_to_exhausted_300(self, account_name):
        """移动账号到待激活目录"""
        json_filename = f"{account_name}.json"
        source_path = self.base_dir / "uploaded" / json_filename
        target_path = self.base_dir / "exhausted_300" / json_filename
        
        if source_path.exists():
            shutil.move(str(source_path), str(target_path))
            logger.info(f"账号移动到待激活: {account_name}")
            self.update_file_path(account_name, str(target_path))
    
    def move_account_to_exhausted_100(self, account_name):
        """移动激活账号到100刀用完目录"""
        json_filename = f"{account_name}.json"
        source_path = self.base_dir / "uploaded" / json_filename
        target_path = self.base_dir / "exhausted_100" / json_filename
        
        if source_path.exists():
            shutil.move(str(source_path), str(target_path))
            logger.info(f"激活账号100刀用完: {account_name}")
            self.update_file_path(account_name, str(target_path))
    
    def update_file_path(self, account_name, file_path):
        """更新数据库中的文件路径"""
        if self.mode != "full":
            return
            
        conn = self.get_db_connection()
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE account_status SET file_path = %s WHERE account_name = %s",
            (file_path, account_name)
        )
        conn.commit()
        conn.close()
    
    def call_batch_upload_script(self, need_accounts):
        """调用批量上传脚本（轻量模式使用）"""
        try:
            import subprocess
            
            # 需要上传的文件数量（每个账号组3个文件）
            upload_count = need_accounts * 3
            
            # 优先使用已激活的账号
            activated_groups = self.get_available_account_groups(self.base_dir / "activated")
            if len(activated_groups) > 0:
                command = f"python scripts/batch_upload.py {min(len(activated_groups) * 3, upload_count)} --source activated"
                logger.info(f"调用批量上传脚本（已激活账号）: {command}")
            else:
                # 使用新账号
                command = f"python scripts/batch_upload.py {upload_count} --source fresh"
                logger.info(f"调用批量上传脚本（新账号）: {command}")
            
            result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=300)
            
            if result.returncode == 0:
                logger.info("批量上传脚本执行成功")
                return True
            else:
                logger.error(f"批量上传脚本执行失败: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"调用批量上传脚本异常: {e}")
            return False
    
    def get_available_account_groups(self, directory):
        """获取目录中可用的完整账号组"""
        if not directory.exists():
            return []
            
        files = list(directory.glob("*.json"))
        groups = {}
        
        for file in files:
            name_parts = file.stem.split('-')
            if len(name_parts) >= 4:
                prefix = '-'.join(name_parts[:-1])
                if prefix.endswith('-actived'):
                    prefix = prefix.replace('-actived', '')
                
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append(file)
        
        return [prefix for prefix, files in groups.items() if len(files) == 3]
    
    def monitor_and_replenish(self):
        """主监控和补充逻辑"""
        logger.info("="*50)
        logger.info(f"开始执行监控检查 - {self.mode}模式")
        
        # 获取当前API状态
        api_channels = self.get_new_api_status()
        
        if not api_channels:
            logger.warning("获取通道数据失败，本次检查结束")
            return
        
        # 完整模式才更新账号状态
        if self.mode == "full":
            self.update_account_status(api_channels)
        
        # 统计当前可用渠道
        active_channels = [ch for ch in api_channels if ch.get('status') == 1]
        current_count = len(active_channels)
        
        min_channels = self.config['new_api']['min_channels']
        target_channels = self.config['new_api']['target_channels']
        
        logger.info(f"通道状态统计:")
        logger.info(f"  - 总通道数: {len(api_channels)}")
        logger.info(f"  - 活跃通道数: {current_count}")
        logger.info(f"  - 非活跃通道数: {len(api_channels) - current_count}")
        logger.info(f"  - 最小需求: {min_channels}")
        
        if current_count < min_channels:
            need_accounts = (target_channels - current_count + 2) // 3
            logger.warning(f"活跃通道数不足! 需要补充 {need_accounts} 个账号组")
            
            if self.mode == "full":
                # 完整模式：直接上传
                uploaded_count = self.upload_account_groups(need_accounts)
                if uploaded_count > 0:
                    logger.info(f"✅ 本次共上传 {uploaded_count} 个账号组")
                else:
                    logger.error("❌ 没有可用的账号组进行补充")
            else:
                # 轻量模式：调用批量上传脚本
                success = self.call_batch_upload_script(need_accounts)
                if success:
                    logger.info("✅ 通道补充完成")
                else:
                    logger.error("❌ 通道补充失败")
        else:
            logger.info(f"✅ 通道数量充足 (当前: {current_count} >= 最小需求: {min_channels})")
        
        # 显示活跃通道信息
        if active_channels:
            logger.info("当前活跃通道:")
            for i, channel in enumerate(active_channels[:5], 1):
                quota_dollars = channel.get('used_quota', 0) / 500000
                logger.info(f"  {i}. ID:{channel.get('id')} 名称:{channel.get('name')} 已用额度:${quota_dollars:.2f}")
            if len(active_channels) > 5:
                logger.info(f"  ... 还有 {len(active_channels) - 5} 个活跃通道")
        
        logger.info("本次监控检查完成")
    
    def upload_account_groups(self, need_accounts):
        """上传账号组（完整模式使用）"""
        uploaded_count = 0
        
        # 优先使用已激活的账号
        activated_groups = self.get_available_account_groups(self.base_dir / "activated")
        for group_prefix in activated_groups:
            if uploaded_count >= need_accounts:
                break
                
            if self.upload_account_group(group_prefix, "activated"):
                uploaded_count += 1
                logger.info(f"成功上传已激活账号组: {group_prefix}")
        
        # 如果还不够，使用新账号
        fresh_groups = self.get_available_account_groups(self.base_dir / "fresh")
        for group_prefix in fresh_groups:
            if uploaded_count >= need_accounts:
                break
                
            if self.upload_account_group(group_prefix, "fresh"):
                uploaded_count += 1
                logger.info(f"成功上传新账号组: {group_prefix}")
        
        return uploaded_count
    
    def upload_account_group(self, account_prefix, source_dir="fresh"):
        """上传一个账号组的3个JSON文件"""
        # 这里复用之前的上传逻辑...
        # 为简化，暂时省略详细实现
        logger.info(f"模拟上传账号组: {account_prefix} from {source_dir}")
        return True
    
    def run_continuous(self):
        """持续运行模式"""
        logger.info("启动持续监控模式")
        
        while True:
            try:
                self.monitor_and_replenish()
                
                interval = self.config['monitoring']['check_interval_seconds']
                logger.info(f"等待 {interval} 秒后进行下次检查...")
                time.sleep(interval)
                
            except KeyboardInterrupt:
                logger.info("监控程序已停止")
                break
            except Exception as e:
                logger.error(f"监控异常: {e}")
                time.sleep(60)
    
    def run_once(self):
        """单次运行模式"""
        logger.info("执行单次监控检查")
        self.monitor_and_replenish()

def main():
    """主函数，支持不同运行模式"""
    parser = argparse.ArgumentParser(description='GCP账号监控管理器')
    parser.add_argument('--mode', choices=['full', 'lite'], default='full',
                       help='运行模式: full(完整) 或 lite(轻量)')
    parser.add_argument('--run-once', action='store_true',
                       help='单次运行模式（适合定时任务）')
    
    args = parser.parse_args()
    
    try:
        manager = GCPAccountManager(mode=args.mode)
        
        if args.run_once:
            manager.run_once()
        else:
            manager.run_continuous()
            
    except Exception as e:
        logger.error(f"程序启动失败: {e}")
        exit(1)

if __name__ == "__main__":
    main()