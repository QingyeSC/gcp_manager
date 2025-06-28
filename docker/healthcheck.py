# docker/healthcheck.py
#!/usr/bin/env python3
import requests
import sys
import os

def check_health():
    try:
        # 检查Web应用健康状态
        port = os.getenv('WEB_PORT', '5000')
        response = requests.get(f'http://localhost:{port}/health', timeout=5)
        
        if response.status_code == 200:
            data = response.json()
            if data.get('status') == 'healthy':
                print("应用健康检查通过")
                return True
        
        print(f"健康检查失败: {response.status_code}")
        return False
        
    except Exception as e:
        print(f"健康检查异常: {e}")
        return False

if __name__ == "__main__":
    if check_health():
        sys.exit(0)
    else:
        sys.exit(1)