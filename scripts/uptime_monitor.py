#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通道监控运维脚本 - 基于用户原始代码改进
功能：监控API通道状态，自动补充有效通道数量
"""

import os
import sys
import json
import logging
import requests
import subprocess
from datetime import datetime
from typing import Dict, Any, Tuple
from pathlib import Path

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/uptime_monitor.log', encoding='utf-8'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

class UptimeMonitor:
    """通道监控类 - 基于用户原始监控逻辑"""
    
    def __init__(self, config_path="config/settings.json"):
        """初始化监控器"""
        self.load_config(config_path)
        
        logger.info(f"监控器初始化完成:")
        logger.info(f"  - API地址: {self.api_url}")
        logger.info(f"  - 最小活跃通道数: {self.min_active_channels}")
        
    def load_config(self, config_path):
        """加载配置"""
        if Path(config_path).exists():
            with open(config_path, 'r', encoding='utf-8') as f:
                config = json.load(f)
            
            # 从配置文件获取
            self.api_url = config['new_api']['base_url'] + config['new_api']['search_endpoint']
            self.bearer_token = config['new_api']['api_key']
            self.min_active_channels = config['new_api']['min_channels']
            self.upload_script_path = f"python scripts/batch_upload.py"
        else:
            # 从环境变量获取配置，如果不存在则使用默认值
            base_url = os.getenv('NEW_API_BASE_URL', 'http://152.53.166.175:3058')
            self.api_url = base_url + '/api/channel/search?keyword=&group=svip&model=&id_sort=true&tag_mode=false'
            self.bearer_token = os.getenv('NEW_API_TOKEN', '')
            self.min_active_channels = int(os.getenv('MIN_CHANNELS', '15'))
            self.upload_script_path = f"python scripts/batch_upload.py"
        
        # 检查必要的配置
        if not self.bearer_token:
            logger.error("请设置 NEW_API_TOKEN")
            sys.exit(1)
    
    def get_request_headers(self) -> Dict[str, str]:
        """获取请求头 - 沿用用户的原始设置"""
        return {
            "accept": "application/json, text/plain, */*",
            "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
            "cache-control": "no-store",
            "new-api-user": "1",
            "authorization": f"Bearer {self.bearer_token}",
            "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
    
    def fetch_channel_data(self) -> Dict[str, Any]:
        """
        获取通道数据 - 沿用用户的原始逻辑
        返回: API响应的JSON数据
        """
        try:
            logger.info("正在获取通道数据...")
            
            # 发送GET请求
            response = requests.get(
                self.api_url,
                headers=self.get_request_headers(),
                timeout=30  # 30秒超时
            )
            
            # 检查HTTP状态码
            if response.status_code != 200:
                logger.error(f"API请求失败，状态码: {response.status_code}")
                logger.error(f"响应内容: {response.text}")
                return {}
            
            # 解析JSON响应
            data = response.json()
            
            # 检查API返回是否成功
            if not data.get('success', False):
                logger.error(f"API返回失败: {data.get('message', '未知错误')}")
                return {}
                
            logger.info("通道数据获取成功")
            return data
            
        except requests.RequestException as e:
            logger.error(f"网络请求异常: {e}")
            return {}
        except json.JSONDecodeError as e:
            logger.error(f"JSON解析失败: {e}")
            return {}
        except Exception as e:
            logger.error(f"获取通道数据时发生未知错误: {e}")
            return {}
    
    def analyze_channel_status(self, data: Dict[str, Any]) -> Tuple[int, int, list]:
        """
        分析通道状态 - 修正额度计算
        参数: data - API返回的数据
        返回: (活跃通道数, 非活跃通道数, 活跃通道列表)
        """
        if not data or 'data' not in data or 'items' not in data['data']:
            logger.warning("API数据格式不正确或为空")
            return 0, 0, []
        
        channels = data['data']['items']
        active_channels = []  # status = 1 的通道
        inactive_count = 0    # status != 1 的通道数量
        
        # 遍历所有通道，统计状态
        for channel in channels:
            channel_id = channel.get('id', 'Unknown')
            channel_name = channel.get('name', 'Unknown')
            status = channel.get('status', 0)
            
            if status == 1:
                active_channels.append({
                    'id': channel_id,
                    'name': channel_name,
                    'used_quota': channel.get('used_quota', 0)
                })
            else:
                inactive_count += 1
                # 记录非活跃通道的详细信息
                other_info = channel.get('other_info', '')
                logger.debug(f"非活跃通道 ID:{channel_id} 名称:{channel_name} 状态:{status} 信息:{other_info}")
        
        active_count = len(active_channels)
        total_count = len(channels)
        
        logger.info(f"通道状态统计:")
        logger.info(f"  - 总通道数: {total_count}")
        logger.info(f"  - 活跃通道数 (status=1): {active_count}")
        logger.info(f"  - 非活跃通道数 (status≠1): {inactive_count}")
        
        return active_count, inactive_count, active_channels
    
    def execute_upload_script(self, needed_count: int) -> bool:
        """
        执行上传脚本补充通道
        参数: needed_count - 需要补充的通道数量
        返回: 是否执行成功
        """
        try:
            # 构造完整的命令
            command = f"{self.upload_script_path} {needed_count}"
            logger.info(f"准备执行补充脚本: {command}")
            
            # 执行命令
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=300  # 5分钟超时
            )
            
            # 检查执行结果
            if result.returncode == 0:
                logger.info(f"补充脚本执行成功!")
                logger.info(f"标准输出: {result.stdout}")
                return True
            else:
                logger.error(f"补充脚本执行失败，返回码: {result.returncode}")
                logger.error(f"错误输出: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            logger.error("补充脚本执行超时")
            return False
        except Exception as e:
            logger.error(f"执行补充脚本时发生错误: {e}")
            return False
    
    def run_check(self):
        """
        执行一次监控检查（用于定时任务）
        """
        try:
            logger.info("=" * 50)
            logger.info("开始执行监控检查")
            
            # 1. 获取通道数据
            data = self.fetch_channel_data()
            if not data:
                logger.warning("获取通道数据失败，本次检查结束")
                return
            
            # 2. 分析通道状态
            active_count, inactive_count, active_channels = self.analyze_channel_status(data)
            
            # 3. 检查是否需要补充通道
            if active_count < self.min_active_channels:
                needed_count = self.min_active_channels - active_count
                logger.warning(f"活跃通道数不足! 当前: {active_count}, 最小需求: {self.min_active_channels}")
                logger.info(f"需要补充 {needed_count} 个通道")
                
                # 执行补充脚本
                success = self.execute_upload_script(needed_count)
                if success:
                    logger.info("✅ 通道补充完成")
                else:
                    logger.error("❌ 通道补充失败")
            else:
                logger.info(f"✅ 通道数量充足 (当前: {active_count} >= 最小需求: {self.min_active_channels})")
            
            # 4. 显示活跃通道的简要信息 - 修正额度显示
            if active_channels:
                logger.info("当前活跃通道:")
                for i, channel in enumerate(active_channels[:5], 1):  # 只显示前5个
                    quota_dollars = channel['used_quota'] / 500000  # 修正：除以500000转换为美元
                    logger.info(f"  {i}. ID:{channel['id']} 名称:{channel['name']} 已用额度:${quota_dollars:.2f}")
                if len(active_channels) > 5:
                    logger.info(f"  ... 还有 {len(active_channels) - 5} 个活跃通道")
            
            logger.info("本次监控检查完成")
            
        except Exception as e:
            logger.error(f"监控过程中发生未知错误: {e}")
            raise

def main():
    """主函数"""
    print("通道监控运维脚本 (定时任务版本)")
    print("=" * 35)
    
    # 创建并运行监控器
    try:
        monitor = UptimeMonitor()
        monitor.run_check()
        print("🎉 监控检查执行完成!")
    except Exception as e:
        logger.error(f"程序执行失败: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()