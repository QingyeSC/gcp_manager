#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GCP账号管理辅助工具
提供批量导入、验证、统计等功能
"""

import os
import json
import shutil
import argparse
from pathlib import Path
from datetime import datetime
import re

class AccountUtils:
    def __init__(self):
        self.base_dir = Path(__file__).parent.parent
        self.accounts_dir = self.base_dir / "accounts"
        
        # 确保目录存在
        for subdir in ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]:
            (self.accounts_dir / subdir).mkdir(parents=True, exist_ok=True)
    
    def validate_json_file(self, file_path):
        """验证JSON文件是否为有效的GCP服务账号密钥"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            # 检查必要字段
            required_fields = [
                'type', 'project_id', 'private_key_id', 'private_key', 
                'client_email', 'client_id', 'auth_uri', 'token_uri'
            ]
            
            for field in required_fields:
                if field not in data:
                    return False, f"缺少必要字段: {field}"
            
            # 检查类型是否为service_account
            if data.get('type') != 'service_account':
                return False, f"类型不正确: {data.get('type')}, 应为 service_account"
            
            # 检查私钥格式
            private_key = data.get('private_key', '')
            if not private_key.startswith('-----BEGIN PRIVATE KEY-----'):
                return False, "私钥格式不正确"
            
            return True, "验证通过"
            
        except json.JSONDecodeError as e:
            return False, f"JSON格式错误: {e}"
        except Exception as e:
            return False, f"验证失败: {e}"
    
    def validate_account_group(self, group_prefix, directory):
        """验证账号组的完整性"""
        dir_path = self.accounts_dir / directory
        
        missing_files = []
        invalid_files = []
        
        for suffix in ['01', '02', '03']:
            filename = f"{group_prefix}-{suffix}.json"
            file_path = dir_path / filename
            
            if not file_path.exists():
                missing_files.append(filename)
                continue
            
            is_valid, message = self.validate_json_file(file_path)
            if not is_valid:
                invalid_files.append(f"{filename}: {message}")
        
        is_complete = len(missing_files) == 0 and len(invalid_files) == 0
        
        return {
            'complete': is_complete,
            'missing_files': missing_files,
            'invalid_files': invalid_files
        }
    
    def import_account_files(self, source_directory, target_directory="fresh", 
                           validate=True, rename_pattern=None):
        """批量导入账号文件"""
        source_path = Path(source_directory)
        target_path = self.accounts_dir / target_directory
        
        if not source_path.exists():
            print(f"❌ 源目录不存在: {source_path}")
            return
        
        json_files = list(source_path.glob("*.json"))
        if not json_files:
            print(f"❌ 源目录中没有JSON文件: {source_path}")
            return
        
        print(f"📁 发现 {len(json_files)} 个JSON文件")
        
        imported_count = 0
        failed_count = 0
        
        for file_path in json_files:
            try:
                # 验证文件
                if validate:
                    is_valid, message = self.validate_json_file(file_path)
                    if not is_valid:
                        print(f"❌ {file_path.name}: {message}")
                        failed_count += 1
                        continue
                
                # 确定目标文件名
                if rename_pattern:
                    # 使用重命名模式
                    target_filename = rename_pattern.format(
                        original_name=file_path.stem,
                        timestamp=datetime.now().strftime("%Y%m%d%H%M%S")
                    ) + ".json"
                else:
                    target_filename = file_path.name
                
                target_file_path = target_path / target_filename
                
                # 检查目标文件是否已存在
                if target_file_path.exists():
                    print(f"⚠️ 文件已存在，跳过: {target_filename}")
                    continue
                
                # 复制文件
                shutil.copy2(file_path, target_file_path)
                print(f"✓ 导入成功: {file_path.name} -> {target_filename}")
                imported_count += 1
                
            except Exception as e:
                print(f"❌ 导入失败 {file_path.name}: {e}")
                failed_count += 1
        
        print(f"\n📊 导入完成:")
        print(f"  成功: {imported_count} 个")
        print(f"  失败: {failed_count} 个")
    
    def check_account_groups(self, directory="fresh"):
        """检查账号组的完整性"""
        dir_path = self.accounts_dir / directory
        
        if not dir_path.exists():
            print(f"❌ 目录不存在: {dir_path}")
            return
        
        # 获取所有JSON文件
        json_files = list(dir_path.glob("*.json"))
        
        if not json_files:
            print(f"📁 目录中没有JSON文件: {dir_path}")
            return
        
        # 按前缀分组
        groups = {}
        for file_path in json_files:
            # 提取前缀 (去掉-01/-02/-03和-actived后缀)
            name = file_path.stem
            if name.endswith('-actived'):
                name = name[:-8]  # 去掉-actived
            
            parts = name.split('-')
            if len(parts) >= 4:
                prefix = '-'.join(parts[:-1])
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append(file_path)
        
        print(f"📊 {directory} 目录中的账号组:")
        print("=" * 60)
        
        complete_groups = 0
        incomplete_groups = 0
        
        for prefix, files in groups.items():
            file_count = len(files)
            status = "✓ 完整" if file_count == 3 else f"❌ 不完整 ({file_count}/3)"
            
            if file_count == 3:
                complete_groups += 1
            else:
                incomplete_groups += 1
            
            print(f"{prefix:<30} {status}")
            
            # 显示文件详情
            for file_path in sorted(files):
                size_kb = file_path.stat().st_size / 1024
                modified = datetime.fromtimestamp(file_path.stat().st_mtime).strftime('%Y-%m-%d %H:%M')
                print(f"  └─ {file_path.name:<25} ({size_kb:.1f}KB, {modified})")
        
        print("=" * 60)
        print(f"总计: {complete_groups} 个完整组, {incomplete_groups} 个不完整组")
    
    def cleanup_incomplete_groups(self, directory="fresh", action="move"):
        """清理不完整的账号组"""
        dir_path = self.accounts_dir / directory
        
        if not dir_path.exists():
            print(f"❌ 目录不存在: {dir_path}")
            return
        
        # 获取所有JSON文件并分组
        json_files = list(dir_path.glob("*.json"))
        groups = {}
        
        for file_path in json_files:
            name = file_path.stem
            if name.endswith('-actived'):
                name = name[:-8]
            
            parts = name.split('-')
            if len(parts) >= 4:
                prefix = '-'.join(parts[:-1])
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append(file_path)
        
        # 找出不完整的组
        incomplete_groups = {prefix: files for prefix, files in groups.items() if len(files) != 3}
        
        if not incomplete_groups:
            print("✓ 所有账号组都是完整的")
            return
        
        print(f"发现 {len(incomplete_groups)} 个不完整的账号组:")
        
        # 创建清理目录
        if action == "move":
            cleanup_dir = self.accounts_dir / "cleanup" / datetime.now().strftime("%Y%m%d_%H%M%S")
            cleanup_dir.mkdir(parents=True, exist_ok=True)
        
        cleaned_count = 0
        for prefix, files in incomplete_groups.items():
            print(f"  {prefix} ({len(files)}/3 个文件)")
            
            for file_path in files:
                if action == "move":
                    target_path = cleanup_dir / file_path.name
                    shutil.move(str(file_path), str(target_path))
                    print(f"    移动: {file_path.name} -> {target_path}")
                elif action == "delete":
                    file_path.unlink()
                    print(f"    删除: {file_path.name}")
                
                cleaned_count += 1
        
        if action == "move":
            print(f"\n✓ 已将 {cleaned_count} 个不完整文件移动到: {cleanup_dir}")
        else:
            print(f"\n✓ 已删除 {cleaned_count} 个不完整文件")
    
    def generate_statistics(self):
        """生成账号统计报告"""
        print("📊 GCP账号管理统计报告")
        print("=" * 60)
        print(f"生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print()
        
        directories = ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]
        total_groups = 0
        total_files = 0
        
        for directory in directories:
            dir_path = self.accounts_dir / directory
            
            if not dir_path.exists():
                continue
            
            json_files = list(dir_path.glob("*.json"))
            file_count = len(json_files)
            
            # 统计完整组数
            groups = {}
            for file_path in json_files:
                name = file_path.stem
                if name.endswith('-actived'):
                    name = name[:-8]
                
                parts = name.split('-')
                if len(parts) >= 4:
                    prefix = '-'.join(parts[:-1])
                    if prefix not in groups:
                        groups[prefix] = []
                    groups[prefix].append(file_path)
            
            complete_groups = len([g for g in groups.values() if len(g) == 3])
            incomplete_groups = len(groups) - complete_groups
            
            # 计算总大小
            total_size = sum(f.stat().st_size for f in json_files)
            total_size_mb = total_size / (1024 * 1024)
            
            # 如果有数据库记录，也显示使用额度信息
            conn = self.get_db_connection() if hasattr(self, 'get_db_connection') else None
            total_quota_dollars = 0
            if conn:
                try:
                    cursor = conn.cursor()
                    file_names = [f.stem for f in json_files]
                    if file_names:
                        placeholders = ','.join(['?' for _ in file_names])
                        cursor.execute(f'''
                            SELECT SUM(used_quota) as total_quota 
                            FROM account_status 
                            WHERE account_name IN ({placeholders})
                        ''', file_names)
                        result = cursor.fetchone()
                        if result and result[0]:
                            total_quota_dollars = result[0] / 500000
                    cursor.close()
                    conn.close()
                except:
                    pass
            
            quota_str = f"  ${total_quota_dollars:.2f}" if total_quota_dollars > 0 else ""
            print(f"{directory:<15} {complete_groups:>3} 完整组  {incomplete_groups:>3} 不完整组  {file_count:>3} 文件  {total_size_mb:>6.1f}MB{quota_str}")
            
            total_groups += complete_groups
            total_files += file_count
        
        print("-" * 60)
        print(f"{'总计':<15} {total_groups:>3} 完整组  {total_files:>18} 文件")
        print()
        
        # 系统建议
        fresh_groups = len([g for g in self.get_groups("fresh") if len(g) == 3])
        activated_groups = len([g for g in self.get_groups("activated") if len(g) == 3])
        pending_groups = len([g for g in self.get_groups("exhausted_300") if len(g) == 3])
        
        print("💡 系统建议:")
        if fresh_groups < 5:
            print("  ⚠️ 新账号池不足，建议补充新账号")
        if pending_groups > 0:
            print(f"  ⚠️ 有 {pending_groups} 个账号组待激活")
        if activated_groups > 0:
            print(f"  ✓ 有 {activated_groups} 个已激活账号可用")
    
    def get_groups(self, directory):
        """获取目录中的账号组"""
        dir_path = self.accounts_dir / directory
        
        if not dir_path.exists():
            return {}
        
        json_files = list(dir_path.glob("*.json"))
        groups = {}
        
        for file_path in json_files:
            name = file_path.stem
            if name.endswith('-actived'):
                name = name[:-8]
            
            parts = name.split('-')
            if len(parts) >= 4:
                prefix = '-'.join(parts[:-1])
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append(file_path)
        
        return groups

def main():
    parser = argparse.ArgumentParser(description='GCP账号管理辅助工具')
    subparsers = parser.add_subparsers(dest='command', help='可用命令')
    
    # 导入命令
    import_parser = subparsers.add_parser('import', help='批量导入账号文件')
    import_parser.add_argument('source', help='源目录路径')
    import_parser.add_argument('--target', default='fresh', help='目标目录 (默认: fresh)')
    import_parser.add_argument('--no-validate', action='store_true', help='跳过文件验证')
    import_parser.add_argument('--rename', help='重命名模式 (如: proj-{original_name})')
    
    # 检查命令
    check_parser = subparsers.add_parser('check', help='检查账号组完整性')
    check_parser.add_argument('--directory', default='fresh', help='检查目录 (默认: fresh)')
    
    # 清理命令
    cleanup_parser = subparsers.add_parser('cleanup', help='清理不完整的账号组')
    cleanup_parser.add_argument('--directory', default='fresh', help='清理目录 (默认: fresh)')
    cleanup_parser.add_argument('--action', choices=['move', 'delete'], default='move', 
                               help='清理动作: move(移动) 或 delete(删除)')
    
    # 统计命令
    subparsers.add_parser('stats', help='生成统计报告')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    utils = AccountUtils()
    
    if args.command == 'import':
        utils.import_account_files(
            args.source, 
            args.target, 
            validate=not args.no_validate,
            rename_pattern=args.rename
        )
    elif args.command == 'check':
        utils.check_account_groups(args.directory)
    elif args.command == 'cleanup':
        utils.cleanup_incomplete_groups(args.directory, args.action)
    elif args.command == 'stats':
        utils.generate_statistics()

if __name__ == "__main__":
    main()