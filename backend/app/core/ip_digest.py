"""IP 带密钥摘要(TASK-13,2026-11-27):HMAC-SHA256 单一事实源。

服务端不得存明文 IP(隐私政策「不保存原始 IP」):免费配额桶 / 问事限铸 /
章末反馈去重等全部经 ip_digest() 落库。密钥直用 JWT_SECRET_KEY 原键
(feedback 2026-11-24 批起的既有口径,改派生子键 = 存量摘要全部失效重洗,
不做);轮换 JWT 密钥 = 轮换摘要密钥,轮换后旧摘要不再与新摘要相撞,防滥用
窗口最多损失当日计数,可接受。

purpose 进消息前缀:各用途间域分隔(同 IP 不同 purpose 互不碰撞);purpose
命名带 -v1 版本尾,升级口径时递增版本而非改语义。
"""
from __future__ import annotations

import hashlib
import hmac

from ..config import JWT_SECRET_KEY

# 落库 purpose 单一事实源(2026-11-27 review):调用点(interpret/daily_ask)
# 与存量迁移表(quota/store._BUCKET_PURPOSE)共用,防两侧漂移——漂移 =
# 存量行被迁去与新写入不同的摘要,计数孤儿化且无护栏报警。测试用字面量
# 作独立锚(与实现分离,漂移即红)。
FREE_QUOTA_IP_PURPOSE = "free-quota-ip-v1"
ASK_IP_PURPOSE = "ask-ip-v1"
ASK_MINT_IP_PURPOSE = "ask-mint-ip-v1"


def ip_digest(ip: str, purpose: str) -> str:
    """ip → purpose 域分隔的 HMAC-SHA256 摘要(十六进制)。

    调用方负责先做 _normalize_client_ip(IPv6 /64 归并等归一化)再摘要;
    本函数不做归一(保持纯函数,归一语义归调用层)。
    """
    return hmac.new(
        JWT_SECRET_KEY.encode("utf-8"),
        f"{purpose}:{ip}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
