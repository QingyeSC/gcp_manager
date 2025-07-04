from flask import Flask, render_template, request, jsonify, redirect, url_for, session
import mysql.connector
from mysql.connector import pooling
import json
import shutil
import requests  # 添加缺失的导入
from pathlib import Path
from datetime import datetime
import os
import redis
import logging

# 配置日志
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)


class PanelManager:
    """GCP账号管理面板主要业务逻辑类"""
    
    def __init__(self):
        """初始化面板管理器"""
        self.base_dir = Path("accounts")
        self.load_config()
        self.init_database_pool()
        self.init_redis()
        
    def load_config(self):
        """加载配置文件"""
        config_path = Path("config/settings.json")
        if config_path.exists():
            with open(config_path, 'r', encoding='utf-8') as f:
                self.config = json.load(f)
        else:
            # 使用环境变量作为备选
            self.config = {
                "database": {
                    "host": os.getenv('DB_HOST', 'mysql'),
                    "port": int(os.getenv('DB_PORT', 3306)),
                    "name": os.getenv('DB_NAME', 'gcp_accounts'),
                    "user": os.getenv('DB_USER', 'gcp_user'),
                    "password": os.getenv('DB_PASSWORD', 'gcp_password_123'),
                    "charset": "utf8mb4"
                },
                "web_panel": {
                    "secret_key": os.getenv('SECRET_KEY', 'your-secret-key-change-this')
                },
                "new_api": {
                    "base_url": os.getenv('NEW_API_BASE_URL', 'http://152.53.166.175:3058'),
                    "api_key": os.getenv('NEW_API_TOKEN', ''),
                    "search_path": os.getenv('NEW_API_SEARCH_PATH', '/api/channel/search'),
                    "search_params": os.getenv('NEW_API_SEARCH_PARAMS', 'keyword=&group=vertex&model=&id_sort=true&tag_mode=false')
                }
            }
        
        app.secret_key = self.config['web_panel']['secret_key']
    
    def init_database_pool(self):
        """初始化MySQL连接池"""
        try:
            self.db_pool = pooling.MySQLConnectionPool(
                pool_name="gcp_pool",
                pool_size=self.config['database'].get('pool_size', 10),
                pool_reset_session=True,
                host=self.config['database']['host'],
                port=self.config['database']['port'],
                database=self.config['database']['name'],
                user=self.config['database']['user'],
                password=self.config['database']['password'],
                charset=self.config['database']['charset']
            )
            logger.info("MySQL连接池初始化成功")
        except Exception as e:
            logger.error(f"MySQL连接池初始化失败: {e}")
            raise
    
    def init_redis(self):
        """初始化Redis连接"""
        try:
            if 'redis' in self.config:
                self.redis_client = redis.Redis(
                    host=self.config['redis']['host'],
                    port=self.config['redis']['port'],
                    password=self.config['redis'].get('password'),
                    db=self.config['redis'].get('db', 0),
                    decode_responses=True
                )
                # 测试连接
                self.redis_client.ping()
                logger.info("Redis连接初始化成功")
            else:
                self.redis_client = None
        except Exception as e:
            logger.warning(f"Redis连接失败: {e}")
            self.redis_client = None
    
    def get_db_connection(self):
        """获取数据库连接"""
        return self.db_pool.get_connection()
    
    def get_account_statistics(self):
        """获取账号统计信息"""
        conn = self.get_db_connection()
        cursor = conn.cursor(dictionary=True)
        
        try:
            stats = {
                'total_accounts': 0,
                'active_channels': 0,
                'disabled_channels': 0,
                'pending_activation': 0,
                'exhausted_100': 0,
                'fresh_groups': 0,
                'activated_groups': 0
            }
            
            # 统计数据库中的账号
            cursor.execute("SELECT current_status, COUNT(*) as count FROM account_status GROUP BY current_status")
            for row in cursor.fetchall():
                if row['current_status'] == 'active':
                    stats['active_channels'] = row['count']
                elif row['current_status'] == 'disabled':
                    stats['disabled_channels'] = row['count']
            
            # 统计文件夹中的账号组
            stats['fresh_groups'] = len(self.get_account_groups('fresh'))
            stats['activated_groups'] = len(self.get_account_groups('activated'))
            stats['pending_activation'] = len(self.get_account_groups('exhausted_300'))
            stats['exhausted_100'] = len(self.get_account_groups('exhausted_100'))
            
            return stats
            
        finally:
            cursor.close()
            conn.close()
    
    def get_account_groups(self, directory):
        """获取目录中的账号组"""
        dir_path = self.base_dir / directory
        if not dir_path.exists():
            return {}
            
        files = list(dir_path.glob("*.json"))
        groups = {}
        
        for file in files:
            name_parts = file.stem.split('-')
            if len(name_parts) >= 4:
                prefix = '-'.join(name_parts[:-1])
                # 处理激活账号的情况
                if prefix.endswith('-actived'):
                    prefix = prefix.replace('-actived', '')
                
                if prefix not in groups:
                    groups[prefix] = []
                groups[prefix].append({
                    'file': file.name,
                    'path': str(file),
                    'size': file.stat().st_size,
                    'modified': datetime.fromtimestamp(file.stat().st_mtime).strftime('%Y-%m-%d %H:%M:%S')
                })
        
        # 只返回有3个文件的完整组
        return {prefix: files for prefix, files in groups.items() if len(files) == 3}
    
    def get_all_account_pools(self):
        """获取所有账号池的信息"""
        pools = {}
        directories = ["fresh", "uploaded", "exhausted_300", "activated", "exhausted_100", "archive"]
        
        for directory in directories:
            pools[directory] = self.get_account_groups(directory)
        
        return pools
    
    def get_pending_activation_accounts(self):
        """获取待激活的账号详情"""
        groups = self.get_account_groups('exhausted_300')
        
        # 获取数据库中的使用情况信息
        conn = self.get_db_connection()
        cursor = conn.cursor(dictionary=True)
        
        try:
            result = []
            for prefix, files in groups.items():
                # 查询该账号组的使用情况
                file_names = [f['file'].replace('.json', '') for f in files]
                placeholders = ','.join(['%s'] * len(file_names))
                
                cursor.execute(f'''
                    SELECT account_name, used_quota, last_updated 
                    FROM account_status 
                    WHERE account_name IN ({placeholders})
                ''', file_names)
                
                usage_info = {row['account_name']: row for row in cursor.fetchall()}
                
                # 计算总使用量
                total_quota = sum(usage_info.get(name, {}).get('used_quota', 0) for name in file_names)
                
                result.append({
                    'prefix': prefix,
                    'files': files,
                    'total_quota': total_quota,
                    'quota_formatted': f"${total_quota / 500000:.2f}" if total_quota else "$0.00",
                    'file_count': len(files),
                    'last_updated': max([usage_info.get(name, {}).get('last_updated', '') for name in file_names], default='')
                })
            
            return result
            
        finally:
            cursor.close()
            conn.close()
    
    def get_exhausted_100_accounts(self):
        """获取100刀用完的账号"""
        groups = self.get_account_groups('exhausted_100')
        
        result = []
        for prefix, files in groups.items():
            result.append({
                'prefix': prefix,
                'files': files,
                'file_count': len(files)
            })
        
        return result
    
    def get_channel_data(self):
        """获取New API的所有渠道状态 - 增强版本"""
        try:
            # 检查配置
            config = self.config.get('new_api', {})
            api_key = config.get('api_key')
            base_url = config.get('base_url')
            
            if not api_key:
                logger.error("NEW_API_TOKEN 未配置")
                return []
            
            if not base_url:
                logger.error("NEW_API_BASE_URL 未配置")
                return []
            
            # 构建完整的API URL
            search_path = config.get('search_path', '/api/channel/search')
            search_params = config.get('search_params', 'keyword=&group=vertex&model=&id_sort=true&tag_mode=false')
            
            api_url = f"{base_url}{search_path}?{search_params}"
            
            headers = {
                "accept": "application/json, text/plain, */*",
                "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
                "cache-control": "no-store",
                "new-api-user": "1",
                "authorization": f"Bearer {api_key}",
                "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            
            logger.info(f"请求New API: {api_url}")
            
            response = requests.get(api_url, headers=headers, timeout=30)
            
            logger.info(f"New API响应状态: {response.status_code}")
            
            if response.status_code == 200:
                try:
                    data = response.json()
                    logger.info(f"New API返回数据结构: success={data.get('success')}")
                    
                    if data.get('success', False):
                        items = data.get('data', {}).get('items', [])
                        logger.info(f"成功从New API获取 {len(items)} 个渠道")
                        
                        # 记录每个渠道的基本信息用于调试
                        for item in items[:3]:  # 只记录前3个
                            logger.info(f"渠道: {item.get('name')} status={item.get('status')} quota={item.get('used_quota')}")
                        
                        return items
                    else:
                        error_msg = data.get('message', '未知错误')
                        logger.error(f"New API返回失败: {error_msg}")
                        return []
                        
                except json.JSONDecodeError as e:
                    logger.error(f"New API返回数据JSON解析失败: {e}")
                    logger.error(f"响应内容: {response.text[:500]}")
                    return []
            else:
                logger.error(f"New API请求失败: HTTP {response.status_code}")
                logger.error(f"响应内容: {response.text[:500]}")
                return []
                
        except requests.exceptions.Timeout:
            logger.error("New API请求超时")
            return []
        except requests.exceptions.ConnectionError as e:
            logger.error(f"New API连接失败: {e}")
            return []
        except Exception as e:
            logger.error(f"New API请求异常: {e}")
            return []
    
    def activate_account_group(self, account_prefix):
        """激活账号组"""
        source_dir = self.base_dir / "exhausted_300"
        target_dir = self.base_dir / "activated"
        target_dir.mkdir(exist_ok=True)
        
        # 移动并重命名文件
        moved_files = []
        for suffix in ['01', '02', '03']:
            source_file = source_dir / f"{account_prefix}-{suffix}.json"
            target_file = target_dir / f"{account_prefix}-{suffix}-actived.json"
            
            if source_file.exists():
                shutil.move(str(source_file), str(target_file))
                moved_files.append(str(target_file))
        
        if len(moved_files) == 3:
            # 记录激活日志和数据库
            self.log_activation(account_prefix)
            self.update_activation_in_db(account_prefix)
            return True
        else:
            # 如果失败，回滚已移动的文件
            for file_path in moved_files:
                if Path(file_path).exists():
                    original_name = Path(file_path).name.replace('-actived', '')
                    original_path = source_dir / original_name
                    shutil.move(file_path, str(original_path))
            return False
    
    def update_activation_in_db(self, account_prefix):
        """在数据库中更新激活状态"""
        conn = self.get_db_connection()
        cursor = conn.cursor()
        
        try:
            # 更新账号的激活状态
            for suffix in ['01', '02', '03']:
                account_name = f"{account_prefix}-{suffix}"
                cursor.execute('''
                    UPDATE account_status 
                    SET is_activated = TRUE, activation_date = %s 
                    WHERE account_name = %s
                ''', (datetime.now(), account_name))
            
            conn.commit()
            
        finally:
            cursor.close()
            conn.close()
    
    def cleanup_exhausted_100_account(self, account_prefix, action='archive'):
        """清理100刀用完的账号"""
        source_dir = self.base_dir / "exhausted_100"
        
        if action == 'archive':
            target_dir = self.base_dir / "archive"
            target_dir.mkdir(exist_ok=True)
            
            # 重命名并移动到归档
            for suffix in ['01', '02', '03']:
                source_file = source_dir / f"{account_prefix}-{suffix}-actived.json"
                target_file = target_dir / f"{account_prefix}-{suffix}-used.json"
                
                if source_file.exists():
                    shutil.move(str(source_file), str(target_file))
        
        elif action == 'delete':
            # 直接删除
            for suffix in ['01', '02', '03']:
                source_file = source_dir / f"{account_prefix}-{suffix}-actived.json"
                if source_file.exists():
                    source_file.unlink()
        
        return True
    
    def log_activation(self, account_prefix):
        """记录激活日志"""
        log_path = Path("logs/panel.log")
        log_path.parent.mkdir(exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(log_path, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] 账号组已激活: {account_prefix}\n")
    
    def log_json_upload(self, filename, project_id):
        """记录JSON上传日志"""
        log_path = Path("logs/json_upload.log")
        log_path.parent.mkdir(exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(log_path, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] JSON文件上传: {filename}, 项目ID: {project_id}\n")


# 创建全局面板管理器实例
panel_manager = PanelManager()


# ===== 网页模板路由 =====

@app.route('/api/debug/new-api')
def debug_new_api():
    """调试New API连接"""
    try:
        config = panel_manager.config.get('new_api', {})
        
        debug_info = {
            'config': {
                'base_url': config.get('base_url', '未配置'),
                'has_token': bool(config.get('api_key')),
                'search_path': config.get('search_path', '未配置'),
                'search_params': config.get('search_params', '未配置')
            },
            'test_result': None,
            'channels_count': 0,
            'sample_channels': []
        }
        
        # 测试API调用
        try:
            channels = panel_manager.get_channel_data()
            debug_info['test_result'] = 'SUCCESS'
            debug_info['channels_count'] = len(channels)
            debug_info['sample_channels'] = channels[:3] if channels else []
            
        except Exception as e:
            debug_info['test_result'] = f'FAILED: {str(e)}'
        
        return jsonify(debug_info)
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/health')
def health_check():
    """健康检查端点"""
    try:
        # 检查数据库连接
        conn = panel_manager.get_db_connection()
        conn.close()
        
        # 检查Redis连接（如果启用）
        if panel_manager.redis_client:
            panel_manager.redis_client.ping()
        
        return jsonify({'status': 'healthy', 'timestamp': datetime.now().isoformat()})
    except Exception as e:
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 500


@app.route('/')
def dashboard():
    """仪表板页面"""
    stats = panel_manager.get_account_statistics()
    return render_template('dashboard.html', stats=stats)


@app.route('/pending-activation')
def pending_activation():
    """待激活账号页面"""
    accounts = panel_manager.get_pending_activation_accounts()
    return render_template('pending_activation.html', accounts=accounts)


@app.route('/exhausted-100')
def exhausted_100():
    """100刀用完账号页面"""
    accounts = panel_manager.get_exhausted_100_accounts()
    return render_template('exhausted_100.html', accounts=accounts)


@app.route('/account-pools')
def account_pools():
    """账号池管理页面"""
    # 获取URL参数中的池类型筛选
    pool_type = request.args.get('type', 'all')
    return render_template('account_pools.html', pool_type=pool_type)


@app.route('/channels')
def channels():
    """渠道管理页面"""
    # 获取URL参数中的状态筛选
    status_filter = request.args.get('status', 'all')
    return render_template('channels.html', status_filter=status_filter)


# ===== API 数据接口 =====

@app.route('/api/activate', methods=['POST'])
def activate_account():
    """激活账号API"""
    data = request.get_json()
    account_prefix = data.get('account_prefix')
    
    if not account_prefix:
        return jsonify({'success': False, 'message': '账号前缀不能为空'})
    
    success = panel_manager.activate_account_group(account_prefix)
    
    if success:
        return jsonify({'success': True, 'message': f'账号组 {account_prefix} 已成功激活'})
    else:
        return jsonify({'success': False, 'message': '激活失败，请检查文件是否完整'})


@app.route('/api/cleanup', methods=['POST'])
def cleanup_account():
    """清理用完的账号API"""
    data = request.get_json()
    account_prefix = data.get('account_prefix')
    action = data.get('action', 'archive')  # 'archive' or 'delete'
    
    if not account_prefix:
        return jsonify({'success': False, 'message': '账号前缀不能为空'})
    
    success = panel_manager.cleanup_exhausted_100_account(account_prefix, action)
    
    if success:
        action_text = '归档' if action == 'archive' else '删除'
        return jsonify({'success': True, 'message': f'账号组 {account_prefix} 已{action_text}'})
    else:
        return jsonify({'success': False, 'message': '操作失败'})


@app.route('/api/stats')
def get_stats():
    """获取统计信息API"""
    stats = panel_manager.get_account_statistics()
    return jsonify(stats)


@app.route('/api/account-pools')
def get_account_pools():
    """获取账号池数据API"""
    try:
        pools_data = panel_manager.get_all_account_pools()
        return jsonify({
            'success': True,
            'data': pools_data,
            'message': '获取账号池数据成功'
        })
    except Exception as e:
        logger.error(f"获取账号池数据失败: {e}")
        return jsonify({
            'success': False,
            'message': f'获取账号池数据失败: {str(e)}'
        }), 500


@app.route('/api/channels')
def get_channels():
    """获取渠道数据API - 直接从New API获取真实数据"""
    try:
        # 直接调用 New API 获取最新数据
        channels_data = panel_manager.get_channel_data()
        
        if channels_data is None:
            return jsonify({
                'success': False,
                'message': '无法从New API获取渠道数据，请检查API配置',
                'data': []
            }), 500
        
        logger.info(f"成功从New API获取 {len(channels_data)} 个渠道数据")
        
        return jsonify({
            'success': True,
            'data': channels_data,
            'message': f'成功获取 {len(channels_data)} 个渠道数据',
            'source': 'New API (实时数据)'
        })
        
    except Exception as e:
        logger.error(f"获取渠道数据失败: {e}")
        return jsonify({
            'success': False,
            'message': f'获取渠道数据失败: {str(e)}',
            'data': []
        }), 500


@app.route('/api/upload-json', methods=['POST'])
def upload_json():
    """JSON文件上传API - 供脚本调用"""
    try:
        # 检查是否有文件上传
        if 'file' not in request.files:
            return jsonify({'success': False, 'message': '没有上传文件'}), 400
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({'success': False, 'message': '没有选择文件'}), 400
        
        # 检查文件扩展名
        if not file.filename.lower().endswith('.json'):
            return jsonify({'success': False, 'message': '只能上传JSON文件'}), 400
        
        # 读取文件内容
        try:
            file_content = file.read().decode('utf-8')
            json_data = json.loads(file_content)
        except json.JSONDecodeError:
            return jsonify({'success': False, 'message': 'JSON文件格式错误'}), 400
        except Exception as e:
            return jsonify({'success': False, 'message': f'文件读取失败: {str(e)}'}), 400
        
        # 验证JSON是否为GCP服务账号密钥
        required_fields = ['type', 'project_id', 'private_key_id', 'private_key', 'client_email']
        for field in required_fields:
            if field not in json_data:
                return jsonify({'success': False, 'message': f'缺少必要字段: {field}'}), 400
        
        if json_data.get('type') != 'service_account':
            return jsonify({'success': False, 'message': '不是有效的服务账号密钥文件'}), 400
        
        # 保存文件到fresh目录
        fresh_dir = panel_manager.base_dir / "fresh"
        fresh_dir.mkdir(exist_ok=True)
        
        # 使用原始文件名或者生成文件名
        filename = file.filename
        if not filename:
            filename = f"{json_data.get('project_id', 'unknown')}.json"
        
        file_path = fresh_dir / filename
        
        # 检查文件是否已存在
        if file_path.exists():
            return jsonify({'success': False, 'message': f'文件 {filename} 已存在'}), 409
        
        # 保存文件
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(json_data, f, indent=2, ensure_ascii=False)
        
        # 记录上传日志
        panel_manager.log_json_upload(filename, json_data.get('project_id'))
        
        logger.info(f"JSON文件上传成功: {filename}, 项目ID: {json_data.get('project_id')}")
        
        return jsonify({
            'success': True, 
            'message': f'文件 {filename} 上传成功',
            'filename': filename,
            'project_id': json_data.get('project_id'),
            'client_email': json_data.get('client_email')
        })
        
    except Exception as e:
        logger.error(f"JSON文件上传异常: {e}")
        return jsonify({'success': False, 'message': f'上传失败: {str(e)}'}), 500


@app.route('/api/batch-upload-json', methods=['POST'])
def batch_upload_json():
    """批量JSON文件上传API"""
    try:
        # 获取上传的文件列表
        files = request.files.getlist('files')
        if not files:
            return jsonify({'success': False, 'message': '没有上传文件'}), 400
        
        results = []
        success_count = 0
        
        for file in files:
            if file.filename == '':
                continue
                
            if not file.filename.lower().endswith('.json'):
                results.append({
                    'filename': file.filename,
                    'success': False,
                    'message': '只能上传JSON文件'
                })
                continue
            
            try:
                # 读取文件内容
                file_content = file.read().decode('utf-8')
                json_data = json.loads(file_content)
                
                # 验证JSON
                required_fields = ['type', 'project_id', 'private_key_id', 'private_key', 'client_email']
                missing_fields = [field for field in required_fields if field not in json_data]
                
                if missing_fields:
                    results.append({
                        'filename': file.filename,
                        'success': False,
                        'message': f'缺少必要字段: {", ".join(missing_fields)}'
                    })
                    continue
                
                if json_data.get('type') != 'service_account':
                    results.append({
                        'filename': file.filename,
                        'success': False,
                        'message': '不是有效的服务账号密钥文件'
                    })
                    continue
                
                # 保存文件
                fresh_dir = panel_manager.base_dir / "fresh"
                fresh_dir.mkdir(exist_ok=True)
                
                file_path = fresh_dir / file.filename
                
                if file_path.exists():
                    results.append({
                        'filename': file.filename,
                        'success': False,
                        'message': '文件已存在'
                    })
                    continue
                
                # 保存文件
                with open(file_path, 'w', encoding='utf-8') as f:
                    json.dump(json_data, f, indent=2, ensure_ascii=False)
                
                results.append({
                    'filename': file.filename,
                    'success': True,
                    'message': '上传成功',
                    'project_id': json_data.get('project_id'),
                    'client_email': json_data.get('client_email')
                })
                
                success_count += 1
                
                # 记录日志
                panel_manager.log_json_upload(file.filename, json_data.get('project_id'))
                
            except json.JSONDecodeError:
                results.append({
                    'filename': file.filename,
                    'success': False,
                    'message': 'JSON格式错误'
                })
            except Exception as e:
                results.append({
                    'filename': file.filename,
                    'success': False,
                    'message': f'处理失败: {str(e)}'
                })
        
        return jsonify({
            'success': True,
            'message': f'批量上传完成: {success_count}/{len(files)} 个文件成功',
            'total': len(files),
            'success_count': success_count,
            'results': results
        })
        
    except Exception as e:
        logger.error(f"批量JSON文件上传异常: {e}")
        return jsonify({'success': False, 'message': f'批量上传失败: {str(e)}'}), 500


# ===== 错误处理 =====

@app.errorhandler(500)
def internal_error(error):
    """处理500内部服务器错误"""
    logger.error(f"内部服务器错误: {error}")
    return jsonify({'error': '内部服务器错误'}), 500


@app.errorhandler(404)
def not_found(error):
    """处理404页面未找到错误"""
    return jsonify({'error': '页面未找到'}), 404


if __name__ == '__main__':
    # 从环境变量获取运行配置
    host = os.getenv('WEB_HOST', '0.0.0.0')
    port = int(os.getenv('WEB_PORT', 5000))
    debug = os.getenv('WEB_DEBUG', 'false').lower() == 'true'
    
    # 启动Flask应用
    app.run(host=host, port=port, debug=debug)