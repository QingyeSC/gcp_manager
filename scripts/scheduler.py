#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
定时调度脚本
负责执行定期清理、备份、统计等任务
"""

import os
import time
import json
import logging
import schedule
import shutil
from datetime import datetime, timedelta
from pathlib import Path
import mysql.connector

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/scheduler.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class SchedulerService:
    def __init__(self, config_path="config/settings.json"):
        """初始化调度服务"""
        self.load_config(config_path)
        self.base_dir = Path("accounts")
        self.log_dir = Path("logs")
        
        # 确保必要目录存在
        self.base_dir.mkdir(exist_ok=True)
        self.log_dir.mkdir(exist_ok=True)
        
    def load_config(self, config_path):
        """加载配置文件"""
        if Path(config_path).exists():
            try:
                with open(config_path, 'r', encoding='utf-8') as f:
                    self.config = json.load(f)
            except Exception as e:
                logger.warning(f"配置文件加载失败: {e}，使用默认配置")
                self.config = self.get_default_config()
        else:
            logger.info("配置文件不存在，使用默认配置")
            self.config = self.get_default_config()
    
    def get_default_config(self):
        """获取默认配置"""
        return {
            "database": {
                "host": os.getenv('DB_HOST', 'mysql'),
                "port": int(os.getenv('DB_PORT', 3306)),
                "user": os.getenv('DB_USER', 'gcp_user'),
                "password": os.getenv('DB_PASSWORD', 'gcp_password_123'),
                "name": os.getenv('DB_NAME', 'gcp_accounts'),
                "charset": "utf8mb4"
            },
            "logging": {
                "retention_days": 30
            },
            "archive": {
                "retention_days": 30
            },
            "backup": {
                "backup_database": True,
                "retention_days": 7
            }
        }
    
    def get_db_connection(self):
        """获取数据库连接"""
        try:
            return mysql.connector.connect(
                host=self.config['database']['host'],
                port=self.config['database']['port'],
                user=self.config['database']['user'],
                password=self.config['database']['password'],
                database=self.config['database']['name'],
                charset='utf8mb4'
            )
        except Exception as e:
            logger.error(f"数据库连接失败: {e}")
            return None
    
    def cleanup_old_logs(self):
        """清理旧日志文件"""
        try:
            logger.info("开始清理旧日志文件...")
            retention_days = self.config.get('logging', {}).get('retention_days', 30)
            cutoff_date = datetime.now() - timedelta(days=retention_days)
            
            if not self.log_dir.exists():
                logger.info("日志目录不存在，跳过清理")
                return
            
            log_files = list(self.log_dir.glob("*.log"))
            cleaned_count = 0
            
            for log_file in log_files:
                try:
                    if log_file.stat().st_mtime < cutoff_date.timestamp():
                        # 创建备份目录
                        backup_dir = self.log_dir / "archive"
                        backup_dir.mkdir(exist_ok=True)
                        
                        # 备份文件名
                        backup_name = f"{log_file.stem}_{datetime.fromtimestamp(log_file.stat().st_mtime).strftime('%Y%m%d')}.log"
                        backup_path = backup_dir / backup_name
                        
                        shutil.move(str(log_file), str(backup_path))
                        cleaned_count += 1
                        logger.info(f"日志文件已归档: {log_file.name} -> {backup_name}")
                except Exception as e:
                    logger.error(f"处理日志文件失败 {log_file}: {e}")
            
            logger.info(f"日志清理完成，共处理 {cleaned_count} 个文件")
            
        except Exception as e:
            logger.error(f"清理日志文件失败: {e}")
    
    def cleanup_old_accounts(self):
        """清理旧的归档账号文件"""
        try:
            logger.info("开始清理旧的归档账号...")
            archive_dir = self.base_dir / "archive"
            
            if not archive_dir.exists():
                logger.info("归档目录不存在，跳过清理")
                return
            
            retention_days = self.config.get('archive', {}).get('retention_days', 30)
            cutoff_date = datetime.now() - timedelta(days=retention_days)
            
            archived_files = list(archive_dir.glob("*.json"))
            cleaned_count = 0
            
            for file_path in archived_files:
                try:
                    if file_path.stat().st_mtime < cutoff_date.timestamp():
                        file_path.unlink()
                        cleaned_count += 1
                        logger.info(f"已删除旧归档文件: {file_path.name}")
                except Exception as e:
                    logger.error(f"删除归档文件失败 {file_path}: {e}")
            
            logger.info(f"归档文件清理完成，共删除 {cleaned_count} 个文件")
            
        except Exception as e:
            logger.error(f"清理归档文件失败: {e}")
    
    def backup_database(self):
        """备份数据库"""
        try:
            if not self.config.get('backup', {}).get('backup_database', True):
                logger.info("数据库备份已禁用")
                return
                
            logger.info("开始备份数据库...")
            backup_dir = Path("backups")
            backup_dir.mkdir(exist_ok=True)
            
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = backup_dir / f"gcp_accounts_{timestamp}.sql"
            
            # 检查数据库连接
            conn = self.get_db_connection()
            if not conn:
                logger.error("无法连接数据库，跳过备份")
                return
            conn.close()
            
            # 使用mysqldump进行备份
            import subprocess
            cmd = [
                "mysqldump",
                f"--host={self.config['database']['host']}",
                f"--port={self.config['database']['port']}",
                f"--user={self.config['database']['user']}",
                f"--password={self.config['database']['password']}",
                "--single-transaction",
                "--routines",
                "--triggers",
                self.config['database']['name']
            ]
            
            with open(backup_file, 'w') as f:
                result = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, text=True)
            
            if result.returncode == 0:
                logger.info(f"数据库备份成功: {backup_file}")
                
                # 清理旧备份
                self.cleanup_old_backups(backup_dir)
            else:
                logger.error(f"数据库备份失败: {result.stderr}")
                # 删除失败的备份文件
                if backup_file.exists():
                    backup_file.unlink()
                
        except Exception as e:
            logger.error(f"数据库备份异常: {e}")
    
    def cleanup_old_backups(self, backup_dir):
        """清理旧的备份文件"""
        try:
            retention_days = self.config.get('backup', {}).get('retention_days', 7)
            cutoff_date = datetime.now() - timedelta(days=retention_days)
            
            backup_files = list(backup_dir.glob("*.sql"))
            cleaned_count = 0
            
            for backup_file in backup_files:
                try:
                    if backup_file.stat().st_mtime < cutoff_date.timestamp():
                        backup_file.unlink()
                        cleaned_count += 1
                        logger.info(f"已删除旧备份: {backup_file.name}")
                except Exception as e:
                    logger.error(f"删除备份文件失败 {backup_file}: {e}")
            
            if cleaned_count > 0:
                logger.info(f"备份清理完成，共删除 {cleaned_count} 个旧备份")
                
        except Exception as e:
            logger.error(f"清理备份文件失败: {e}")
    
    def generate_daily_report(self):
        """生成每日统计报告"""
        try:
            logger.info("生成每日统计报告...")
            
            conn = self.get_db_connection()
            if not conn:
                logger.error("无法连接数据库，跳过报告生成")
                return
            
            cursor = conn.cursor(dictionary=True)
            
            # 统计各种状态的账号数量
            cursor.execute("SELECT current_status, COUNT(*) as count FROM account_status GROUP BY current_status")
            status_stats = {row['current_status']: row['count'] for row in cursor.fetchall()}
            
            # 统计今日激活的账号
            cursor.execute("""
                SELECT COUNT(*) as count FROM account_status 
                WHERE activation_date >= CURDATE()
            """)
            today_activated = cursor.fetchone()['count']
            
            # 统计总使用额度
            cursor.execute("SELECT SUM(used_quota) as total_quota FROM account_status")
            total_quota = cursor.fetchone()['total_quota'] or 0
            
            cursor.close()
            conn.close()
            
            # 统计文件系统中的账号组
            file_stats = {}
            for directory in ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]:
                dir_path = self.base_dir / directory
                if dir_path.exists():
                    file_count = len(list(dir_path.glob("*.json")))
                    file_stats[directory] = file_count
                else:
                    file_stats[directory] = 0
            
            # 生成报告
            report = {
                "date": datetime.now().strftime("%Y-%m-%d"),
                "database_stats": status_stats,
                "file_stats": file_stats,
                "today_activated": today_activated,
                "total_quota_dollars": total_quota / 500000 if total_quota else 0,
                "generated_at": datetime.now().isoformat()
            }
            
            # 保存报告
            reports_dir = Path("reports")
            reports_dir.mkdir(exist_ok=True)
            
            report_file = reports_dir / f"daily_report_{datetime.now().strftime('%Y%m%d')}.json"
            with open(report_file, 'w', encoding='utf-8') as f:
                json.dump(report, f, indent=2, ensure_ascii=False)
            
            logger.info(f"每日报告生成完成: {report_file}")
            logger.info(f"今日激活账号: {today_activated} 个")
            logger.info(f"总使用额度: ${report['total_quota_dollars']:.2f}")
            
        except Exception as e:
            logger.error(f"生成每日报告失败: {e}")
    
    def check_system_health(self):
        """检查系统健康状态"""
        try:
            logger.info("检查系统健康状态...")
            
            # 检查磁盘空间
            try:
                import shutil
                total, used, free = shutil.disk_usage('/')
                free_percent = free / total * 100
                
                if free_percent < 10:
                    logger.warning(f"磁盘空间不足: 剩余 {free_percent:.1f}%")
                else:
                    logger.info(f"磁盘空间正常: 剩余 {free_percent:.1f}%")
            except Exception as e:
                logger.error(f"检查磁盘空间失败: {e}")
            
            # 检查数据库连接
            try:
                conn = self.get_db_connection()
                if conn:
                    conn.close()
                    logger.info("数据库连接正常")
                else:
                    logger.warning("数据库连接失败")
            except Exception as e:
                logger.error(f"数据库连接检查失败: {e}")
            
            # 检查关键目录
            for directory in ["fresh", "uploaded", "exhausted_300", "activated"]:
                dir_path = self.base_dir / directory
                if not dir_path.exists():
                    logger.warning(f"关键目录不存在: {directory}")
                    try:
                        dir_path.mkdir(parents=True, exist_ok=True)
                        logger.info(f"已创建目录: {directory}")
                    except Exception as e:
                        logger.error(f"创建目录失败 {directory}: {e}")
            
            logger.info("系统健康检查完成")
            
        except Exception as e:
            logger.error(f"系统健康检查失败: {e}")
    
    def run_scheduler(self):
        """运行调度器"""
        logger.info("调度器服务启动")
        
        # 设置定时任务
        try:
            schedule.every().day.at("02:00").do(self.cleanup_old_logs)
            schedule.every().day.at("02:30").do(self.cleanup_old_accounts)
            schedule.every().day.at("03:00").do(self.backup_database)
            schedule.every().day.at("23:30").do(self.generate_daily_report)
            schedule.every().hour.do(self.check_system_health)
            
            logger.info("定时任务已设置:")
            logger.info("- 每日 02:00: 清理旧日志")
            logger.info("- 每日 02:30: 清理旧归档")
            logger.info("- 每日 03:00: 备份数据库")
            logger.info("- 每日 23:30: 生成每日报告")
            logger.info("- 每小时: 系统健康检查")
            
            # 执行首次健康检查
            self.check_system_health()
            
            logger.info("调度器开始运行，等待定时任务...")
            
            # 开始调度循环
            while True:
                try:
                    schedule.run_pending()
                    time.sleep(60)  # 每分钟检查一次
                except KeyboardInterrupt:
                    logger.info("调度器停止")
                    break
                except Exception as e:
                    logger.error(f"调度器异常: {e}")
                    time.sleep(60)
                    
        except Exception as e:
            logger.error(f"调度器设置失败: {e}")
            raise

def main():
    """主函数"""
    try:
        scheduler = SchedulerService()
        scheduler.run_scheduler()
    except Exception as e:
        logger.error(f"调度器启动失败: {e}")
        exit(1)

if __name__ == "__main__":
    main()