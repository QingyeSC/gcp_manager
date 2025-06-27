import os
import json
import time
import shutil
import requests
import mysql.connector
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
    def __init__(self, config_path="config/settings.json"):
        with open(config_path, 'r', encoding='utf-8') as f:
            self.config = json.load(f)
        
        self.base_dir = Path("accounts")
        self.log_dir = Path("logs")
        
        # 创建必要的目录
        directories = ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]
        for dir_name in directories:
            (self.base_dir / dir_name).mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        
        # 初始化数据库连接
        self.init_database()
    
    def get_db_connection(self):
        """获取MySQL数据库连接"""
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
        """获取New API的所有渠道状态 - 基于你的监控代码"""
        try:
            # 使用你的监控接口
            api_url = f"{self.config['new_api']['base_url']}/api/channel/search?keyword=&group=svip&model=&id_sort=true&tag_mode=false"
            
            headers = {
                "accept": "application/json, text/plain, */*",
                "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
                "cache-control": "no-store",
                "new-api-user": "1",
                "authorization": f"Bearer {self.config['new_api']['api_key']}",
                "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            
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
    
    def update_account_status(self, api_channels):
        """根据API返回更新账号状态"""
        conn = self.get_db_connection()
        cursor = conn.cursor()
        
        current_time = datetime.now()
        
        for channel in api_channels:
            name = channel.get('name', '')
            status = channel.get('status', 0)
            used_quota = channel.get('used_quota', 0)
            
            # 检查是否是激活的账号（包含-actived后缀）
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
            
            # 处理文件移动
            if status != 1:  # 被禁用了
                self.handle_disabled_account(name)
        
        conn.commit()
        conn.close()
    
    def handle_disabled_account(self, account_name):
        """处理被禁用的账号"""
        is_activated = '-actived' in account_name
        
        if is_activated:
            # 激活账号被禁用，说明100刀也用完了
            self.move_account_to_exhausted_100(account_name)
        else:
            # 普通账号被禁用，说明300刀用完了
            self.move_account_to_exhausted_300(account_name)
    
    def move_account_to_exhausted_300(self, account_name):
        """移动账号到待激活目录"""
        json_filename = f"{account_name}.json"
        source_path = self.base_dir / "uploaded" / json_filename
        target_path = self.base_dir / "exhausted_300" / json_filename
        
        if source_path.exists():
            shutil.move(str(source_path), str(target_path))
            logger.info(f"账号移动到待激活: {account_name}")
            
            # 更新数据库
            self.update_file_path(account_name, str(target_path))
    
    def move_account_to_exhausted_100(self, account_name):
        """移动激活账号到100刀用完目录"""
        json_filename = f"{account_name}.json"
        source_path = self.base_dir / "uploaded" / json_filename
        target_path = self.base_dir / "exhausted_100" / json_filename
        
        if source_path.exists():
            shutil.move(str(source_path), str(target_path))
            logger.info(f"激活账号100刀用完: {account_name}")
            
            # 更新数据库
            self.update_file_path(account_name, str(target_path))
    
    def update_file_path(self, account_name, file_path):
        """更新数据库中的文件路径"""
        conn = self.get_db_connection()
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE account_status SET file_path = %s WHERE account_name = %s",
            (file_path, account_name)
        )
        conn.commit()
        conn.close()
    
    def get_account_group_files(self, directory, account_prefix):
        """获取账号组的3个文件"""
        files = []
        for suffix in ['01', '02', '03']:
            filename = f"{account_prefix}-{suffix}.json"
            file_path = directory / filename
            if file_path.exists():
                files.append(file_path)
        return files if len(files) == 3 else []
    
    def upload_account_group(self, account_prefix, source_dir="fresh"):
        """上传一个账号组的3个JSON文件 - 基于你的上传代码"""
        source_path = self.base_dir / source_dir
        files = self.get_account_group_files(source_path, account_prefix)
        
        if not files:
            logger.error(f"账号组文件不完整: {account_prefix}")
            return False
        
        # 使用你的上传逻辑
        upload_results = []
        
        # 固定的payload模板（基于你的代码）
        fixed_payload = {
            "type": 41,
            "openai_organization": "",
            "max_input_tokens": 0,
            "base_url": "",
            "other": "{\n  \"default\": \"us-central1\",\n  \"gemini-2.5-flash-lite-preview-06-17\": \"global\",\n  \"gemini-2.5-pro-exp-03-25\": \"global\",\n  \"gemini-2.5-pro-preview-06-05\": \"global\"\n}",
            "model_mapping": "",
            "status_code_mapping": "",
            "models": "gemini-2.5-pro-exp-03-25,gemini-2.0-flash-001,gemini-2.5-flash-preview-04-17,gemini-2.5-flash-preview-05-20,gemini-2.5-pro-preview-03-25,gemini-2.5-pro-preview-05-06,gemini-2.5-pro-preview-06-05,gemini-2.5-flash,gemini-2.5-flash-lite-preview-06-17,gemini-2.5-pro",
            "auto_ban": 1,
            "test_model": "gemini-2.5-pro",
            "groups": ["default", "vip", "svip"],
            "priority": 1,
            "weight": 1,
            "tag": "Vertex-vip",
            "group": "default,vip,svip"
        }
        
        headers = {
            "Authorization": f"Bearer {self.config['new_api']['api_key']}",
            "Content-Type": "application/json",
            "New-API-User": "1"
        }
        
        # 使用线程池并发上传
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(self.upload_single_file, file_path, fixed_payload, headers) 
                      for file_path in files]
            
            for future in as_completed(futures):
                name, file_path, success, message = future.result()
                upload_results.append((name, file_path, success, message))
                
                if success:
                    logger.info(f"成功上传: {name}")
                    # 移动到uploaded目录
                    target_path = self.base_dir / "uploaded" / file_path.name
                    shutil.move(str(file_path), str(target_path))
                else:
                    logger.error(f"上传失败: {name}, 错误: {message}")
        
        # 检查是否全部成功
        success_count = sum(1 for _, _, success, _ in upload_results if success)
        return success_count == 3
    
    def upload_single_file(self, file_path, fixed_payload, headers):
        """上传单个文件 - 基于你的上传逻辑"""
        name = file_path.stem
        max_retries = 3
        
        try:
            # 读取并转义JSON内容
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            key_content = json.dumps(json.loads(content))  # 标准JSON转义
            
            # 构造payload
            payload = fixed_payload.copy()
            payload["name"] = name
            payload["key"] = key_content
            
            # 重试逻辑
            for attempt in range(1, max_retries + 1):
                try:
                    response = requests.post(
                        f"{self.config['new_api']['base_url']}/api/channel/",
                        headers=headers,
                        json=payload,
                        timeout=15
                    )
                    
                    if response.status_code == 200:
                        return (name, file_path, True, "")
                    else:
                        if attempt < max_retries:
                            logger.warning(f"[重试] {name} 第{attempt}次失败，状态码{response.status_code}，准备重试...")
                            time.sleep(1)
                        else:
                            return (name, file_path, False, f"状态码 {response.status_code}，返回: {response.text}")
                            
                except Exception as e:
                    if attempt < max_retries:
                        logger.warning(f"[重试] {name} 第{attempt}次异常 {e}，准备重试...")
                        time.sleep(1)
                    else:
                        return (name, file_path, False, f"异常: {str(e)}")
                        
        except Exception as e:
            return (name, file_path, False, f"解析或准备上传异常: {str(e)}")
    
    def monitor_and_replenish(self):
        """主监控和补充逻辑"""
        logger.info("="*50)
        logger.info("开始执行监控检查")
        
        # 获取当前API状态
        api_channels = self.get_new_api_status()
        
        if not api_channels:
            logger.warning("获取通道数据失败，本次检查结束")
            return
        
        # 更新账号状态
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
            
            # 获取可用的账号组
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
            
            if uploaded_count > 0:
                logger.info(f"✅ 本次共上传 {uploaded_count} 个账号组")
            else:
                logger.error("❌ 没有可用的账号组进行补充")
        else:
            logger.info(f"✅ 通道数量充足 (当前: {current_count} >= 最小需求: {min_channels})")
        
        # 显示活跃通道的简要信息
        if active_channels:
            logger.info("当前活跃通道:")
            for i, channel in enumerate(active_channels[:5], 1):  # 只显示前5个
                quota_dollars = channel.get('used_quota', 0) / 500000  # 转换为美元
                logger.info(f"  {i}. ID:{channel.get('id')} 名称:{channel.get('name')} 已用额度:${quota_dollars:.2f}")
            if len(active_channels) > 5:
                logger.info(f"  ... 还有 {len(active_channels) - 5} 个活跃通道")
        
        logger.info("本次监控检查完成")
    
    def get_available_account_groups(self, directory):
        """获取目录中可用的完整账号组"""
        if not directory.exists():
            return []
            
        files = list(directory.glob("*.json"))
        groups = {}
        
        for file in files:
            # 提取账号前缀
            name_parts = file.stem.split('-')
            if len(name_parts) >= 4:
                prefix = '-'.join(name_parts[:-1])  # 去掉最后的01/02/03
                # 处理激活账号的情况
                if prefix.endswith('-actived'):
                    prefix = prefix.replace('-actived', '')
                
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append(file)
        
        # 只返回有3个文件的完整组
        return [prefix for prefix, files in groups.items() if len(files) == 3]

def main():
    manager = GCPAccountManager()
    
    while True:
        try:
            manager.monitor_and_replenish()
            
            # 每5分钟检查一次
            logger.info(f"等待 {manager.config['monitoring']['check_interval_seconds']} 秒后进行下次检查...")
            time.sleep(manager.config['monitoring']['check_interval_seconds'])
            
        except KeyboardInterrupt:
            logger.info("监控程序已停止")
            break
        except Exception as e:
            logger.error(f"监控异常: {e}")
            time.sleep(60)  # 异常后等待1分钟再继续

if __name__ == "__main__":
    main()