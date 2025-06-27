#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
批量上传脚本 - 基于用户原始代码改进
功能：从账号池中选择并上传JSON文件到New API
"""

import json
import requests
import os
import time
import sys
import argparse
import random
import re
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from datetime import datetime

# 配置日志
import logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/batch_upload.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class BatchUploader:
    """批量上传管理类"""
    
    def __init__(self, config_path="config/settings.json"):
        self.load_config(config_path)
        self.base_dir = Path("accounts")
        
        # 沿用用户的固定payload配置
        self.fixed_payload = {
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
        
        self.max_retries = 3  # 最大重试次数
    
    def load_config(self, config_path):
        """加载配置"""
        if Path(config_path).exists():
            with open(config_path, 'r', encoding='utf-8') as f:
                config = json.load(f)
            
            self.api_url = config['new_api']['base_url'] + config['new_api']['upload_endpoint']
            self.api_token = config['new_api']['api_key']
        else:
            # 从环境变量获取
            base_url = os.getenv('NEW_API_BASE_URL', 'http://152.53.166.175:3058')
            self.api_url = base_url + '/api/channel/'
            self.api_token = os.getenv('NEW_API_TOKEN', '')
        
        # 设置请求头
        self.headers = {
            "Authorization": f"Bearer {self.api_token}",
            "Content-Type": "application/json",
            "New-API-User": "1"
        }
        
        if not self.api_token:
            logger.error("请设置 NEW_API_TOKEN")
            sys.exit(1)
    
    def parse_arguments(self):
        """解析命令行参数"""
        parser = argparse.ArgumentParser(description='批量上传JSON文件到频道')
        parser.add_argument('upload_count', type=int, nargs='?', default=3,
                            help='要上传的文件数量（必须是3的倍数，默认为3）')
        parser.add_argument('--source', default='fresh',
                            help='源目录名称，默认为fresh')
        args = parser.parse_args()
        
        # 检查数量是否为3的倍数
        if args.upload_count % 3 != 0:
            logger.error(f"上传数量必须是3的倍数，你输入的是 {args.upload_count}")
            sys.exit(1)
        
        if args.upload_count <= 0:
            logger.error(f"上传数量必须大于0，你输入的是 {args.upload_count}")
            sys.exit(1)
        
        return args.upload_count, args.source
    
    def get_project_groups(self, source_dir):
        """获取指定目录内所有JSON文件并按项目分组"""
        json_folder = self.base_dir / source_dir
        
        # 检查目录是否存在
        if not json_folder.exists():
            logger.error(f"找不到 {json_folder} 目录！")
            return {}
        
        if not json_folder.is_dir():
            logger.error(f"{json_folder} 不是一个目录！")
            return {}
        
        # 获取目录内的JSON文件
        try:
            json_files = [f for f in json_folder.iterdir() if f.suffix == '.json']
        except Exception as e:
            logger.error(f"无法读取 {json_folder} 目录：{e}")
            return {}
        
        if not json_files:
            logger.error(f"在 {json_folder} 目录内没有找到任何JSON文件！")
            return {}
        
        logger.info(f"在 {json_folder} 目录内找到 {len(json_files)} 个JSON文件")
        
        # 按项目分组
        groups = {}
        
        for file in json_files:
            # 匹配文件名模式，例如：proj-roble-vip-01.json
            # 提取项目前缀（去掉最后的数字部分）
            match = re.match(r'(.+)-(\d+)\.json', file.name)
            if match:
                project_prefix = match.group(1)  # 例如：proj-roble-vip
                number = match.group(2)          # 例如：01
                
                if project_prefix not in groups:
                    groups[project_prefix] = []
                groups[project_prefix].append(file)
            else:
                logger.warning(f"文件 {file.name} 不符合命名规范，跳过")
        
        # 只保留完整的组（包含3个文件的组）
        complete_groups = {}
        for project, files in groups.items():
            if len(files) == 3:
                complete_groups[project] = sorted(files)  # 排序确保顺序一致
            else:
                logger.warning(f"项目 {project} 只有 {len(files)} 个文件，需要3个文件才能构成完整组，跳过")
        
        return complete_groups
    
    def select_upload_groups(self, groups, upload_count, prefer_activated=True):
        """选择要上传的项目组"""
        if not groups:
            return []
        
        groups_needed = upload_count // 3
        available_groups = list(groups.keys())
        
        if len(available_groups) < groups_needed:
            logger.warning(f"只有 {len(available_groups)} 个完整项目组，但需要 {groups_needed} 个组")
            groups_needed = len(available_groups)
        
        # 如果偏好激活账号，优先选择带-actived的
        if prefer_activated:
            activated_groups = [g for g in available_groups if any('-actived' in f.name for f in groups[g])]
            fresh_groups = [g for g in available_groups if g not in activated_groups]
            
            selected_projects = []
            
            # 先选择激活账号
            if activated_groups and groups_needed > 0:
                take_activated = min(len(activated_groups), groups_needed)
                selected_projects.extend(random.sample(activated_groups, take_activated))
                groups_needed -= take_activated
            
            # 再选择新账号
            if fresh_groups and groups_needed > 0:
                take_fresh = min(len(fresh_groups), groups_needed)
                selected_projects.extend(random.sample(fresh_groups, take_fresh))
        else:
            # 随机选择项目组
            selected_projects = random.sample(available_groups, groups_needed)
        
        # 获取选中项目组的所有文件
        selected_files = []
        for project in selected_projects:
            selected_files.extend(groups[project])
            # 显示相对路径，更简洁
            file_names = [f.name for f in groups[project]]
            logger.info(f"选中项目组：{project} -> {file_names}")
        
        return selected_files
    
    def escape_json_content(self, file_path):
        """转义JSON文件内容"""
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        return json.dumps(json.loads(content))  # 标准JSON转义
    
    def upload_channel(self, file_path):
        """上传单个频道文件"""
        name = file_path.stem
        try:
            key_content = self.escape_json_content(file_path)
            payload = self.fixed_payload.copy()
            payload["name"] = name
            payload["key"] = key_content

            for attempt in range(1, self.max_retries + 1):
                try:
                    response = requests.post(self.api_url, headers=self.headers, json=payload, timeout=15)
                    if response.status_code == 200:
                        return (name, file_path, True, "")
                    else:
                        if attempt < self.max_retries:
                            logger.warning(f"[重试] {name} 第{attempt}次失败，状态码{response.status_code}，准备重试...")
                            time.sleep(1)
                        else:
                            return (name, file_path, False, f"状态码 {response.status_code}，返回: {response.text}")
                except Exception as e:
                    if attempt < self.max_retries:
                        logger.warning(f"[重试] {name} 第{attempt}次异常 {e}，准备重试...")
                        time.sleep(1)
                    else:
                        return (name, file_path, False, f"异常: {str(e)}")
        except Exception as e:
            return (name, file_path, False, f"解析或准备上传异常: {str(e)}")
    
    def move_uploaded_files(self, success_files, target_dir="uploaded"):
        """移动上传成功的文件到目标目录"""
        target_path = self.base_dir / target_dir
        target_path.mkdir(parents=True, exist_ok=True)
        
        moved_files = []
        failed_move_files = []
        
        for file_path in success_files:
            try:
                destination = target_path / file_path.name
                shutil.move(str(file_path), str(destination))
                moved_files.append(destination)
                logger.info(f"[移动成功] {file_path.name} -> {target_dir}/")
            except Exception as e:
                failed_move_files.append((file_path, str(e)))
                logger.error(f"[移动失败] {file_path.name}，原因：{e}")
        
        return moved_files, failed_move_files
    
    def run_upload(self, upload_count, source_dir):
        """执行上传任务"""
        logger.info("=" * 50)
        logger.info("批量上传任务开始")
        logger.info(f"本次将上传 {upload_count} 个文件（{upload_count//3} 个项目组）")
        
        # 获取项目分组
        logger.info(f"正在扫描 {source_dir} 目录内的JSON文件...")
        groups = self.get_project_groups(source_dir)
        
        if not groups:
            logger.error("没有找到完整的项目组！")
            return False
        
        logger.info(f"找到 {len(groups)} 个完整项目组：")
        for project, files in groups.items():
            file_names = [f.name for f in files]
            logger.info(f"  - {project}: {file_names}")
        
        # 选择要上传的文件
        logger.info(f"正在选择 {upload_count//3} 个项目组...")
        prefer_activated = (source_dir == "activated")
        selected_files = self.select_upload_groups(groups, upload_count, prefer_activated)
        
        if not selected_files:
            logger.error("没有可上传的文件！")
            return False
        
        logger.info(f"即将上传以下 {len(selected_files)} 个文件：")
        for file in selected_files:
            logger.info(f"  - {file.name}")
        
        # 开始上传
        logger.info("开始上传...")
        success_list = []
        fail_list = []
        success_files = []  # 用于记录成功上传的文件路径

        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = [executor.submit(self.upload_channel, file) for file in selected_files]
            for future in as_completed(futures):
                name, file_path, success, message = future.result()
                if success:
                    success_list.append(name)
                    success_files.append(file_path)
                    logger.info(f"[成功] {name}")
                else:
                    fail_list.append((name, message))
                    logger.error(f"[失败] {name}，原因：{message}")

        # 移动上传成功的文件
        if success_files:
            logger.info(f"开始移动上传成功的 {len(success_files)} 个文件...")
            moved_files, failed_move_files = self.move_uploaded_files(success_files)
        else:
            moved_files = []
            failed_move_files = []

        # 打印总结
        logger.info("====== 总结 ======")
        logger.info(f"成功上传 {len(success_list)} 个：{success_list}")
        logger.info(f"失败上传 {len(fail_list)} 个：")
        for name, reason in fail_list:
            logger.info(f"  - {name}: {reason}")
        
        if moved_files:
            moved_file_names = [f.name for f in moved_files]
            logger.info(f"成功移动 {len(moved_files)} 个文件：{moved_file_names}")
        
        if failed_move_files:
            logger.info(f"移动失败 {len(failed_move_files)} 个文件：")
            for file_path, reason in failed_move_files:
                logger.info(f"  - {file_path.name}: {reason}")

        # 保存日志
        self.save_upload_log(upload_count, selected_files, success_list, fail_list, moved_files, failed_move_files)
        
        return len(success_list) > 0
    
    def save_upload_log(self, upload_count, selected_files, success_list, fail_list, moved_files, failed_move_files):
        """保存上传日志"""
        log_path = Path("logs/upload_detailed.log")
        log_path.parent.mkdir(exist_ok=True)
        
        with open(log_path, "a", encoding="utf-8") as log_file:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            log_file.write(f"\n===== 上传日志 {timestamp} =====\n")
            log_file.write(f"上传目标数量：{upload_count} 个文件\n")
            selected_file_names = [f.name for f in selected_files]
            log_file.write(f"实际选择文件：{selected_file_names}\n\n")
            
            log_file.write(f"成功上传 {len(success_list)} 个：\n")
            for name in success_list:
                log_file.write(f"[成功] {name}\n")

            log_file.write(f"\n失败上传 {len(fail_list)} 个：\n")
            for name, reason in fail_list:
                log_file.write(f"[失败] {name}，原因：{reason}\n")
            
            if moved_files:
                log_file.write(f"\n成功移动 {len(moved_files)} 个文件：\n")
                for file_path in moved_files:
                    log_file.write(f"[移动成功] {file_path.name}\n")
            
            if failed_move_files:
                log_file.write(f"\n移动失败 {len(failed_move_files)} 个文件：\n")
                for file_path, reason in failed_move_files:
                    log_file.write(f"[移动失败] {file_path.name}，原因：{reason}\n")

def main():
    uploader = BatchUploader()
    
    try:
        upload_count, source_dir = uploader.parse_arguments()
        success = uploader.run_upload(upload_count, source_dir)
        
        if success:
            logger.info("🎉 上传任务完成!")
            sys.exit(0)
        else:
            logger.error("❌ 上传任务失败!")
            sys.exit(1)
            
    except KeyboardInterrupt:
        logger.info("上传任务被用户中断")
        sys.exit(1)
    except Exception as e:
        logger.error(f"上传任务异常: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()