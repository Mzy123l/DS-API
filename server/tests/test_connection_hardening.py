"""连接层加固：TLS 握手不许卡住 accept 循环，半开连接不许占死线程。

2026-09-22 线上事故：监听 socket 被 wrap 成 SSL 后，握手是在 accept 所在的
主线程里同步做的，一个连上却不完成握手的客户端把整个服务卡死。
"""

from __future__ import annotations

import hashlib
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request

import pytest

from app.config import Config
from app.main import HealthWatchdog, RelayServer, build_server
from app.store import ChatStore

# 服务端要求必须配口令：测试统一用这个口令与它的哈希
TEST_TOKEN = "test-relay-token"
TEST_TOKEN_HASH = hashlib.sha256(TEST_TOKEN.encode("utf-8")).hexdigest()


class FakeTlsContext:
    """假 TLS context：记录握手次数，可让第一次握手“卡住”。"""

    def __init__(self, stall_first: bool = False) -> None:
        self.stall_first = stall_first
        self.calls = 0
        self.stall_started = threading.Event()

    def wrap_socket(self, sock: socket.socket, server_side: bool = False):
        self.calls += 1
        if self.stall_first and self.calls == 1:
            # 模拟“连上但不发 ClientHello”的客户端
            self.stall_started.set()
            time.sleep(1.5)
        return sock


class FlakyTlsContext:
    """第一次握手直接失败，之后正常。"""

    def __init__(self) -> None:
        self.calls = 0

    def wrap_socket(self, sock: socket.socket, server_side: bool = False):
        self.calls += 1
        if self.calls == 1:
            raise ssl.SSLError("handshake timed out")
        return sock


class ServerHarness:
    """后台线程里跑一个 RelayServer，方便用原始 socket 做连接级测试。"""

    def __init__(
        self,
        config: Config | None = None,
        tls_context=None,
    ) -> None:
        self.server = RelayServer(
            ("127.0.0.1", 0),
            config or Config(relay_token_hash=TEST_TOKEN_HASH),
            store=ChatStore(":memory:"),
            tls_context=tls_context,
        )
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            daemon=True,
        )
        self.thread.start()
        self.host, self.port = self.server.server_address[:2]

    def get(self, path: str, timeout: float = 5.0, token: str | None = None):
        request = urllib.request.Request(
            f"http://{self.host}:{self.port}{path}"
        )
        # 服务端要求必须配口令；URL 里已带 ?token= 的用例不额外加头，
        # 否则头会优先命中，测不到 URL 鉴权那条路。
        if token is None and "token=" not in path:
            token = TEST_TOKEN
        if token:
            request.add_header("x-relay-token", token)
        return urllib.request.urlopen(request, timeout=timeout)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server.store.close()
        self.thread.join(timeout=5)


def test_listener_socket_is_not_tls_wrapped() -> None:
    """监听 socket 保持明文：握手留到各连接自己的线程里做。"""
    context = FakeTlsContext()
    harness = ServerHarness(tls_context=context)
    try:
        assert not isinstance(harness.server.socket, ssl.SSLSocket)
        assert harness.server.tls_context is context
        # 只是监听、还没人连上来：不该发生任何握手
        assert context.calls == 0
    finally:
        harness.close()


def test_build_server_keeps_listener_plain_with_tls() -> None:
    """配置了 TLS 时，监听 socket 依然不能是 SSL（线上事故的回归防线）。"""
    context = FakeTlsContext()
    config = Config(
        host="127.0.0.1",
        port=0,
        db_path=":memory:",
        relay_token_hash=TEST_TOKEN_HASH,
        tls_cert="/tmp/relay.crt",
        tls_key="/tmp/relay.key",
    )
    server, used = build_server(config, tls_context=context)
    try:
        assert used is context
        assert server.tls_context is context
        assert not isinstance(server.socket, ssl.SSLSocket)
        # 组装阶段不该发生任何握手（旧实现会在这里 wrap 监听 socket）
        assert context.calls == 0
    finally:
        server.server_close()
        server.store.close()


def test_slow_handshake_does_not_block_other_clients() -> None:
    """一个卡住的握手只占住它自己的线程，别的客户端照常被服务。"""
    context = FakeTlsContext(stall_first=True)
    harness = ServerHarness(tls_context=context)
    try:
        # 第一个客户端：连上就吊着（握手被假 context 挂住）
        stalled = socket.create_connection(
            (harness.host, harness.port),
            timeout=5,
        )
        assert context.stall_started.wait(2), "第一个握手没有开始"

        started = time.monotonic()
        with harness.get("/healthz") as res:
            body = res.read()
        elapsed = time.monotonic() - started

        assert res.status == 200
        assert b'"status": "ok"' in body
        # 旧实现下这里要等第一个握手结束（约 1.5s）
        assert elapsed < 1.0, f"第二个客户端被握手拖住了 {elapsed:.2f}s"
        stalled.close()
    finally:
        harness.close()


def test_half_open_connection_is_dropped_after_timeout() -> None:
    """连上却不发请求的连接会在 request_timeout 后被关掉，服务照常。"""
    harness = ServerHarness(
        config=Config(request_timeout=0.4, relay_token_hash=TEST_TOKEN_HASH)
    )
    try:
        sock = socket.create_connection((harness.host, harness.port), timeout=5)
        sock.settimeout(3)
        try:
            data = sock.recv(64)
        except ConnectionResetError:
            data = b""
        assert data == b"", "半开连接没有被服务端关闭"
        sock.close()

        with harness.get("/healthz") as res:
            assert res.status == 200
    finally:
        harness.close()


def test_handshake_failure_only_drops_that_connection() -> None:
    """握手失败（例如超时）只丢这一条连接，不影响后面的请求。"""
    harness = ServerHarness(tls_context=FlakyTlsContext())
    try:
        sock = socket.create_connection((harness.host, harness.port), timeout=5)
        sock.settimeout(3)
        try:
            data = sock.recv(64)
        except ConnectionResetError:
            data = b""
        assert data == b"", "握手失败的连接没有被关掉"
        sock.close()

        with harness.get("/healthz") as res:
            assert res.status == 200
    finally:
        harness.close()


def test_healthz_is_not_written_to_access_log(capsys) -> None:
    """健康检查（Docker/看门狗高频访问）不写访问日志，免得刷屏。"""
    harness = ServerHarness()
    try:
        with harness.get("/healthz"):
            pass
        with harness.get("/v1/conversations?limit=1"):
            pass
        err = capsys.readouterr().err
        assert "GET /healthz" not in err
        assert "/v1/conversations" in err
    finally:
        harness.close()


def test_query_token_never_reaches_access_log(capsys) -> None:
    """`?token=<明文口令>` 能鉴权通过，但绝不能出现在访问日志里。

    媒体播放器带不了自定义请求头，只能走 URL 鉴权；而默认的访问日志
    requestline 含完整查询串，会把口令原样写进 docker logs。
    """
    token = "s3cret-url-token"
    harness = ServerHarness(
        config=Config(
            relay_token_hash=hashlib.sha256(token.encode("utf-8")).hexdigest()
        )
    )
    try:
        # 只带查询参数（不带 x-relay-token 头）也要能通过鉴权
        with harness.get(f"/v1/conversations?token={token}") as res:
            assert res.status == 200
        # 带错口令被拒，同样不能把口令写进日志
        with pytest.raises(urllib.error.HTTPError) as error:
            harness.get("/v1/conversations?token=wrong-secret-value")
        assert error.value.code == 401
        # 健康检查带查询串时仍走静默分支（判断用的是剥掉 query 的 path）
        with harness.get(f"/healthz?token={token}"):
            pass
        err = capsys.readouterr().err
        assert token not in err
        assert "wrong-secret-value" not in err
        assert "token=" not in err
        # 静默逻辑没被破坏，普通请求照常记录（只记 path）
        assert "GET /healthz" not in err
        assert "GET /v1/conversations" in err
    finally:
        harness.close()


def test_watchdog_probe_sees_healthy_server() -> None:
    harness = ServerHarness()
    try:
        watchdog = HealthWatchdog(
            port=harness.port,
            interval=1.0,
            failures_allowed=3,
            use_tls=False,
        )
        assert watchdog.probe() is True
    finally:
        harness.close()


def test_watchdog_exits_after_consecutive_failures() -> None:
    """探测一直失败时，看门狗退出进程（由 Docker 重启）。"""
    exits: list[int] = []
    watchdog = HealthWatchdog(
        port=1,  # 必然连不上
        interval=1.0,
        failures_allowed=2,
        use_tls=False,
        exit_process=exits.append,
    )
    watchdog.start()
    watchdog.join(timeout=10)
    assert exits == [1]
