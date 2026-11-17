"""本地假上游：用于验证中转服务，无需真实 API Key。

用法：python3 mock_upstream.py [端口]
"""

from __future__ import annotations

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class MockUpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802 - 框架约定
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            for index in range(1, 4):
                event = {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": f"第{index}段回答。"},
                }
                self.wfile.write(
                    f"data: {json.dumps(event, ensure_ascii=False)}\n\n".encode(
                        "utf-8"
                    )
                )
                self.wfile.flush()
                time.sleep(0.5)
            self.wfile.write(b'data: {"type":"message_stop"}\n\n')
            self.wfile.flush()
        except OSError:
            pass

    def log_message(self, format: str, *args: Any) -> None:
        """静默：验证脚本自己打印结果。"""


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    server = ThreadingHTTPServer(("0.0.0.0", port), MockUpstreamHandler)
    server.daemon_threads = True
    print(f"mock upstream listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
