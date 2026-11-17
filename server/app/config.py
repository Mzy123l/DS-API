"""服务配置：全部来自环境变量，便于容器化部署。"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass


class ConfigError(RuntimeError):
    """配置不满足安全要求，服务拒绝启动。"""


@dataclass(frozen=True)
class Config:
    """运行期配置。"""

    host: str = "0.0.0.0"
    port: int = 51888
    # 上游 DeepSeek 服务（客户端可用 x-upstream-base 头覆盖）
    upstream_base: str = "https://api.deepseek.com"
    # 单次上游请求的读写超时（秒）：流式长回答可能持续很久
    upstream_timeout: float = 900.0
    # 任务完成后在内存中保留的时长（秒），用于客户端断线后补齐结果
    job_ttl_seconds: float = 1800.0
    # 生成过程中把已输出内容 checkpoint 到数据库的间隔（秒）。
    # 服务重启时内存任务会消失，但 checkpoint 过的回答仍留在会话里。
    checkpoint_interval: float = 2.0
    # 内存中最多保留的任务数（超出后先淘汰最早结束的）
    max_jobs: int = 50
    # 等待上游返回状态码的超时（秒）
    start_timeout: float = 60.0
    # 搜索/抓取接口（/v1/tools/*）的上游超时（秒）
    tools_timeout: float = 60.0
    # 请求体上限（字节）：图片附件走 base64，放宽一些
    max_body_bytes: int = 128 * 1024 * 1024
    # 会话/消息存储（SQLite）路径，实际部署时挂到宿主目录
    db_path: str = "/srv/data/relay.db"
    # 上传文件缓存：`/v1/files` 成功后留一份字节给 ocr 工具用（LRU 淘汰）
    file_cache_bytes: int = 256 * 1024 * 1024
    file_cache_files: int = 64
    # 访问口令的 SHA-256（十六进制）。服务端只保存哈希，明文只在客户端。
    # 必填：为空时服务拒绝启动（见 require_token_hash），不存在“不配口令就放行”。
    relay_token_hash: str = ""
    # TLS 证书/私钥：都配置时以 HTTPS 提供服务（自签名证书，客户端按指纹校验）
    tls_cert: str = ""
    tls_key: str = ""
    # TLS 握手超时（秒）：握手在每连接线程里做，超时就丢弃这条连接
    tls_handshake_timeout: float = 10.0
    # 单条连接的请求读写超时（秒）：半开连接最多占住一个线程这么久
    request_timeout: float = 30.0
    # 看门狗：每隔多少秒自检一次、连续失败几次就退出进程等 Docker 重启
    watchdog_interval: float = 30.0
    watchdog_failures: int = 3

    @classmethod
    def from_env(cls) -> Config:
        return cls(
            host=os.getenv("RELAY_HOST", "0.0.0.0"),
            port=int(os.getenv("RELAY_PORT", "51888")),
            upstream_base=os.getenv(
                "UPSTREAM_BASE", "https://api.deepseek.com"
            ).rstrip("/"),
            upstream_timeout=float(os.getenv("UPSTREAM_TIMEOUT", "900")),
            job_ttl_seconds=float(os.getenv("JOB_TTL_SECONDS", "1800")),
            checkpoint_interval=float(os.getenv("JOB_CHECKPOINT_INTERVAL", "2")),
            max_jobs=int(os.getenv("MAX_JOBS", "50")),
            start_timeout=float(os.getenv("START_TIMEOUT", "60")),
            tools_timeout=float(os.getenv("TOOLS_TIMEOUT", "60")),
            max_body_bytes=int(os.getenv("MAX_BODY_BYTES", str(128 * 1024 * 1024))),
            db_path=os.getenv("RELAY_DB", "/srv/data/relay.db"),
            file_cache_bytes=int(
                os.getenv("FILE_CACHE_BYTES", str(256 * 1024 * 1024))
            ),
            file_cache_files=int(os.getenv("FILE_CACHE_FILES", "64")),
            # 标准写法是 RELAY_TOKEN_HASH（只存哈希）；
            # 若只给了明文 RELAY_TOKEN，就地算哈希，同样不落盘
            relay_token_hash=_resolve_token_hash(),
            tls_cert=os.getenv("TLS_CERT", "").strip(),
            tls_key=os.getenv("TLS_KEY", "").strip(),
            tls_handshake_timeout=float(os.getenv("TLS_HANDSHAKE_TIMEOUT", "10")),
            request_timeout=float(os.getenv("REQUEST_TIMEOUT", "30")),
            watchdog_interval=float(os.getenv("WATCHDOG_INTERVAL", "30")),
            watchdog_failures=int(os.getenv("WATCHDOG_FAILURES", "3")),
        )


def _resolve_token_hash() -> str:
    """取口令哈希：优先 RELAY_TOKEN_HASH，其次把明文 RELAY_TOKEN 就地哈希。"""
    hashed = os.getenv("RELAY_TOKEN_HASH", "").strip().lower()
    if hashed:
        return hashed
    plain = os.getenv("RELAY_TOKEN", "").strip()
    if not plain:
        return ""
    return hashlib.sha256(plain.encode("utf-8")).hexdigest()


def require_token_hash(config: Config) -> str:
    """取出可用的口令哈希；没配就是配置错误，绝不退化成“放行”。

    服务默认监听 0.0.0.0，一旦无口令对外可用，任何人都能白用转发额度、
    读走 relay.db 里的全部会话。所以这里直接拒绝启动，让部署脚本和
    Docker 明确失败，而不是起一个“healthy 但对公网敞开”的容器。
    """
    token_hash = config.relay_token_hash.strip().lower()
    if not token_hash:
        raise ConfigError(
            "未配置访问口令：必须设置 RELAY_TOKEN_HASH（口令的 SHA-256）"
            "或 RELAY_TOKEN（明文，启动时就地哈希）。"
            "服务不会以“无口令放行”的方式启动。"
        )
    if len(token_hash) != 64 or any(
        ch not in "0123456789abcdef" for ch in token_hash
    ):
        raise ConfigError(
            "RELAY_TOKEN_HASH 不是合法的 SHA-256 十六进制串（应为 64 位十六进制）"
        )
    return token_hash
