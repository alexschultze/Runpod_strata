import asyncio
import json
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402

REAL_CLIENT = httpx.AsyncClient


def mock(handler):
    """Route every httpx.AsyncClient created by server through a MockTransport."""
    def factory(*a, **kw):
        kw["transport"] = httpx.MockTransport(handler)
        return REAL_CLIENT(*a, **kw)
    return factory


@pytest.fixture
def patch(monkeypatch):
    def _patch(handler):
        monkeypatch.setattr(server.httpx, "AsyncClient", mock(handler))
    return _patch


def run(coro):
    return asyncio.run(coro)


HTML = "<html><head><title>T</title><style>p{}</style><script>x()</script></head><body><h1>Hi</h1><p>a <b>bold</b> <a href='/x'>l</a></p></body></html>"


def test_tools_registered():
    names = {t.name for t in run(server.mcp.list_tools())}
    assert names == {"websearch", "webfetch"}


def test_fetch_markdown(patch):
    patch(lambda r: httpx.Response(200, text=HTML, headers={"content-type": "text/html"}))
    out = run(server.webfetch("https://x.test/"))
    assert "# Hi" in out and "**bold**" in out and "x()" not in out and "p{}" not in out


def test_fetch_text(patch):
    patch(lambda r: httpx.Response(200, text=HTML, headers={"content-type": "text/html"}))
    assert run(server.webfetch("https://x.test/", format="text")) == "T Hi a bold l"


def test_fetch_html_raw(patch):
    patch(lambda r: httpx.Response(200, text=HTML, headers={"content-type": "text/html"}))
    assert run(server.webfetch("https://x.test/", format="html")) == HTML


def test_fetch_non_html_passthrough(patch):
    patch(lambda r: httpx.Response(200, text="# md", headers={"content-type": "text/markdown"}))
    assert run(server.webfetch("https://x.test/")) == "# md"


def test_fetch_bad_scheme():
    with pytest.raises(ValueError):
        run(server.webfetch("ftp://x"))


def test_fetch_status_error(patch):
    patch(lambda r: httpx.Response(404))
    with pytest.raises(RuntimeError, match="404"):
        run(server.webfetch("https://x.test/"))


def test_fetch_too_large(patch):
    patch(lambda r: httpx.Response(200, content=b"a" * (server.MAX_RESPONSE_SIZE + 1)))
    with pytest.raises(RuntimeError, match="too large"):
        run(server.webfetch("https://x.test/"))


def test_fetch_cloudflare_retry(patch):
    uas = []

    def handler(req):
        uas.append(req.headers["user-agent"])
        if len(uas) == 1:
            return httpx.Response(403, headers={"cf-mitigated": "challenge"})
        return httpx.Response(200, text="ok", headers={"content-type": "text/plain"})

    patch(handler)
    assert run(server.webfetch("https://x.test/")) == "ok"
    assert uas == [server.BROWSER_UA, "mcp-web"]


def test_fetch_image(patch):
    patch(lambda r: httpx.Response(200, content=b"\x89PNG", headers={"content-type": "image/png"}))
    img = run(server.webfetch("https://x.test/a.png"))
    assert img.to_image_content().mimeType == "image/png"
