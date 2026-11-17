"""端到端冒烟：起假上游 + 真实中转，逐个打通全家桶接口。

用法（在 server/ 下）：python tools/smoke_family.py

覆盖：/healthz capabilities、/v1/files 上传与列表、/v1/tools/{ocr,asr,tts}、
服务端执行的联网搜索（steps/sources 解析）、以及中转执行的 ocr 函数工具。
不依赖任何 API Key，也不访问外网。
"""

from __future__ import annotations

import json
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import Config  # noqa: E402
from app.main import RelayServer  # noqa: E402
from app.store import ChatStore  # noqa: E402
from tests.fake_upstream import (  # noqa: E402
    FAKE_WAV,
    FakeUpstream,
    anthropic_ocr_tool_use_script,
    anthropic_script,
    anthropic_server_search_script,
)

BOUNDARY = "----smokeboundary"


def multipart(fields, files) -> tuple[bytes, str]:
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(
            (
                f"--{BOUNDARY}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            ).encode()
        )
        chunks.append(value.encode())
        chunks.append(b"\r\n")
    for name, filename, ctype, data in files:
        chunks.append(
            (
                f"--{BOUNDARY}\r\n"
                f'Content-Disposition: form-data; name="{name}"; '
                f'filename="{filename}"\r\nContent-Type: {ctype}\r\n\r\n'
            ).encode()
        )
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(f"--{BOUNDARY}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={BOUNDARY}"


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))
        if not ok:
            failures.append(name)

    with FakeUpstream(scripts=[anthropic_ocr_tool_use_script(), anthropic_script("完成")]) as up:
        server = RelayServer(
            ("127.0.0.1", 0),
            Config(upstream_base=up.base_url, checkpoint_interval=0.0),
            store=ChatStore(":memory:"),
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()
        host, port = server.server_address[:2]
        base = f"http://{host}:{port}"
        auth = {"Authorization": "Bearer sk-smoke"}

        try:
            with urllib.request.urlopen(f"{base}/healthz", timeout=10) as res:
                health = json.loads(res.read())
            check(
                "healthz capabilities",
                set(health["capabilities"]) >= {"files", "ocr", "asr", "tts"},
                ",".join(health["capabilities"]),
            )

            body, ctype = multipart(
                [("purpose", "text_recognition")],
                [("file", "a.pdf", "application/pdf", b"%PDF-1.7 smoke")],
            )
            req = urllib.request.Request(
                f"{base}/v1/files",
                data=body,
                headers={"Content-Type": ctype, **auth},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                uploaded = json.loads(res.read())
            check("POST /v1/files", uploaded["id"] == "file-api-123", uploaded["id"])
            check(
                "upload cached",
                server.file_cache.get(uploaded["id"]) is not None,
            )

            req = urllib.request.Request(f"{base}/v1/files", headers=auth)
            with urllib.request.urlopen(req, timeout=10) as res:
                listing = json.loads(res.read())
            check("GET /v1/files", listing["object"] == "list")

            body, ctype = multipart(
                [("purpose", "rich_layout_recognition")],
                [("file", "scan.png", "image/png", b"\x89PNG smoke")],
            )
            req = urllib.request.Request(
                f"{base}/v1/tools/ocr",
                data=body,
                headers={"Content-Type": ctype, **auth},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                ocr = json.loads(res.read())
            check("POST /v1/tools/ocr", ocr["page_count"] == 2)

            body, ctype = multipart([], [("file", "v.wav", "audio/wav", FAKE_WAV)])
            req = urllib.request.Request(
                f"{base}/v1/tools/asr",
                data=body,
                headers={"Content-Type": ctype, **auth},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                asr = json.loads(res.read())
            check("POST /v1/tools/asr", asr["text"] == "识别出来的话")

            req = urllib.request.Request(
                f"{base}/v1/tools/tts",
                data=json.dumps({"text": "你好", "voice_id": "stella"}).encode(),
                headers={"Content-Type": "application/json", **auth},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                audio = res.read()
                billed = res.headers.get("X-Billed-Chars")
            check("POST /v1/tools/tts 二进制透传", audio == FAKE_WAV, f"{len(audio)}B")
            check("TTS X-Billed-Chars 透传", billed == "42", str(billed))

            # 服务端执行的联网搜索：一次上游请求，steps/sources 进快照
            up.scripts = None
            up.lines = anthropic_server_search_script(content="搜索完成")
            chat = {
                "protocol": "anthropic",
                "payload": {
                    "model": "m",
                    "stream": True,
                    "messages": [],
                    "tools": [
                        {"type": "deepseek_web_search", "name": "deepseek_web_search"}
                    ],
                },
            }
            req = urllib.request.Request(
                f"{base}/v1/chat",
                data=json.dumps(chat).encode(),
                headers={"Content-Type": "application/json", "x-api-key": "sk-smoke"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                stream = res.read().decode()
            job_id = json.loads(
                [line for line in stream.split("\n") if line.startswith("data: ")][0][6:]
            )["job_id"]
            with urllib.request.urlopen(f"{base}/v1/jobs/{job_id}", timeout=10) as res:
                snapshot = json.loads(res.read())
            check(
                "服务端搜索 → steps",
                snapshot["steps"][0]["kind"] == "search"
                and snapshot["steps"][0]["status"] == "done",
            )
            check(
                "服务端搜索 → sources 新字段",
                snapshot["sources"][0].get("site_name") == "示例站点",
            )

            # 中转执行的 ocr 函数工具（复用之前上传的缓存）
            up.scripts = [anthropic_ocr_tool_use_script(), anthropic_script("完成")]
            up._script_index = 0
            chat["payload"]["tools"] = [{"type": "function", "name": "ocr"}]
            req = urllib.request.Request(
                f"{base}/v1/chat",
                data=json.dumps(chat).encode(),
                headers={"Content-Type": "application/json", "x-api-key": "sk-smoke"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                res.read()
            check(
                "ocr 函数工具调用上游",
                any(item["path"] == "/v1/tools/ocr" for item in up.requests),
            )
            second = [
                item for item in up.requests if item["path"].endswith("/messages")
            ][-1]["body"]
            filled = [
                block
                for message in second["messages"]
                if message.get("role") == "user"
                for block in (
                    message["content"] if isinstance(message["content"], list) else []
                )
                if isinstance(block, dict) and block.get("type") == "tool_result"
            ]
            check(
                "ocr 结果回填逐页文本",
                bool(filled) and "第一页内容" in filled[0]["content"],
            )
        except urllib.error.HTTPError as exc:  # pragma: no cover - 冒烟脚本
            check("HTTP 请求", False, f"{exc.code} {exc.read()[:200]}")
        finally:
            server.shutdown()
            server.server_close()
            server.store.close()

    print()
    if failures:
        print(f"失败 {len(failures)} 项：{failures}")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
