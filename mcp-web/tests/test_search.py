import asyncio
import json
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import search_providers as sp  # noqa: E402
import server  # noqa: E402

REAL_CLIENT = httpx.AsyncClient
ALL = ["exa", "firecrawl", "parallel", "tavily", "tinyfish"]


def run(coro):
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def no_keys(monkeypatch):
    for k in ("EXA", "PARALLEL", "FIRECRAWL", "TAVILY", "TINYFISH"):
        monkeypatch.delenv(f"{k}_API_KEY", raising=False)


@pytest.fixture
def net(monkeypatch):
    def _net(handler):
        def factory(*a, **kw):
            kw["transport"] = httpx.MockTransport(handler)
            return REAL_CLIENT(*a, **kw)
        monkeypatch.setattr(sp.httpx, "AsyncClient", factory)
    return _net


def rpc(result, sse=True):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": result})
    return httpx.Response(200, text=f"event: message\ndata: {body}\n\n" if sse else body)


def text(t):
    return {"content": [{"type": "text", "text": t}]}


EXA_TEXT = (
    "Title: A\nURL: https://a.test\nPublished: 2026-01-02T00:00:00Z\nHighlights:\nhello\nworld"
    "\n\n---\n\nTitle: N/A\nURL: https://b.test\nPublished: N/A\nText:\nbody"
    "\n\n---\n\nTitle: no url"
)


def test_providers_registered():
    assert list(sp.PROVIDERS) == ALL


def test_exa(net):
    seen = {}

    def h(req):
        seen["url"] = str(req.url)
        seen["body"] = json.loads(req.content)
        return rpc(text(EXA_TEXT))

    net(h)
    s = sp.Searcher(selection="exa")
    pid, res = run(s.query("q"))
    assert pid == "exa" and [r.url for r in res] == ["https://a.test", "https://b.test"]
    assert res[0].title == "A" and res[0].content == "hello\nworld" and res[0].published == 1767312000000
    assert res[1].title is None and res[1].published is None
    assert seen["body"]["params"] == {"name": "web_search_exa", "arguments": {"query": "q", "numResults": 8}}
    assert "exaApiKey" not in seen["url"]


def test_exa_key(net, monkeypatch):
    monkeypatch.setenv("EXA_API_KEY", "k1")
    seen = {}
    net(lambda req: (seen.update(url=str(req.url)), rpc(text("")))[1])
    run(sp.Searcher(selection="exa").query("q"))
    assert seen["url"].endswith("?exaApiKey=k1")


def test_parallel(net, monkeypatch):
    monkeypatch.setenv("PARALLEL_API_KEY", "pk")
    seen = {}

    def h(req):
        seen["auth"] = req.headers.get("authorization")
        seen["args"] = json.loads(req.content)["params"]
        return rpc({"content": [], "structuredContent": {"results": [
            {"url": "https://p.test", "title": "P", "publish_date": None, "excerpts": ["x", "y"]}]}}, sse=False)

    net(h)
    _, res = run(sp.Searcher(selection="parallel").query("q"))
    assert seen["auth"] == "Bearer pk"
    assert seen["args"] == {"name": "web_search", "arguments": {"objective": "q", "search_queries": ["q"]}}
    assert res[0].content == "x\n\ny"


def test_firecrawl(net):
    payload = {"success": True, "data": {"web": [{"url": "https://f.test", "title": "F", "description": "d"}]}}
    net(lambda req: rpc(text(json.dumps(payload))))
    _, res = run(sp.Searcher(selection="firecrawl").query("q"))
    assert (res[0].url, res[0].title, res[0].content) == ("https://f.test", "F", "d")


def test_tavily_keyless_and_keyed(net, monkeypatch):
    seen = {}

    def h(req):
        seen["h"] = dict(req.headers)
        seen["body"] = json.loads(req.content)
        return httpx.Response(200, json={"results": [{"title": "T", "url": "https://t.test", "content": "c"}]})

    net(h)
    _, res = run(sp.Searcher(selection="tavily").query("q"))
    assert seen["h"]["x-tavily-access-mode"] == "keyless" and "authorization" not in seen["h"]
    assert seen["body"]["max_results"] == 8 and res[0].content == "c"
    monkeypatch.setenv("TAVILY_API_KEY", "tk")
    run(sp.Searcher(selection="tavily").query("q"))
    assert seen["h"]["authorization"] == "Bearer tk" and "x-tavily-access-mode" not in seen["h"]


def test_tinyfish_keyless_and_keyed(net, monkeypatch):
    calls = []

    def h(req):
        body = json.loads(req.content)
        calls.append((body.get("method"), req.headers.get("mcp-session-id"), req.headers.get("x-api-key"),
                      req.headers.get("x-tinyfish-access-mode")))
        if body["method"] == "initialize":
            return httpx.Response(200, text="{}", headers={"mcp-session-id": "S1"})
        if body["method"] == "notifications/initialized":
            return httpx.Response(202)
        return rpc(text(json.dumps({"results": [{"url": "https://tf.test", "title": "TF", "snippet": "s"}]})))

    net(h)
    _, res = run(sp.Searcher(selection="tinyfish").query("q"))
    assert calls == [("tools/call", None, None, "keyless")] and res[0].content == "s"
    calls.clear()
    monkeypatch.setenv("TINYFISH_API_KEY", "tfk")
    run(sp.Searcher(selection="tinyfish").query("q"))
    assert [c[:3] for c in calls] == [("initialize", None, "tfk"), ("notifications/initialized", "S1", "tfk"),
                                      ("tools/call", "S1", "tfk")]


def test_mcp_tool_error_is_raised(net):
    net(lambda req: rpc({"isError": True, "content": [{"type": "text", "text": "daily limit reached"}]}))
    with pytest.raises(sp.SearchError, match="daily limit reached"):
        run(sp.Searcher(selection="firecrawl").query("q"))


def stub_providers(monkeypatch, behaviours):
    """Replace providers with stubs; behaviours: id -> callable(query) -> list[Result] | raises."""
    calls = []

    def make(pid):
        async def fn(client, query):
            calls.append(pid)
            return behaviours[pid](query)
        return (pid.title(), fn)

    monkeypatch.setattr(sp, "PROVIDERS", {p: make(p) for p in behaviours})
    return calls


def too_many(retry_after=None):
    def f(q):
        req = httpx.Request("POST", "https://x")
        raise httpx.HTTPStatusError("429", request=req, response=httpx.Response(
            429, request=req, headers={"retry-after": retry_after} if retry_after else {}))
    return f


def ok(url):
    return lambda q: [sp.Result(url=url)]


def test_random_sticks_to_provider(monkeypatch):
    calls = stub_providers(monkeypatch, {"a": ok("A"), "b": ok("B"), "c": ok("C")})
    s = sp.Searcher(pick=lambda xs: xs[1])
    for _ in range(3):
        assert run(s.query("q"))[0] == "b"
    assert calls == ["b", "b", "b"]


def test_random_fails_over_on_429_and_cools_down(monkeypatch):
    now = [1000.0]
    calls = stub_providers(monkeypatch, {"a": too_many("30"), "b": ok("B")})
    s = sp.Searcher(clock=lambda: now[0], pick=lambda xs: xs[0])
    assert run(s.query("q"))[0] == "b"
    assert calls == ["a", "b"]
    calls.clear()
    assert run(s.query("q"))[0] == "b" and calls == ["b"]
    now[0] += 31  # a is available again, but the session keeps b
    assert run(s.query("q"))[0] == "b"


def test_random_all_rate_limited_raises_last(monkeypatch):
    stub_providers(monkeypatch, {"a": too_many(), "b": too_many()})
    s = sp.Searcher(pick=lambda xs: xs[0])
    with pytest.raises(sp.SearchError, match="B web search failed"):
        run(s.query("q"))


def test_random_other_errors_do_not_fail_over(monkeypatch):
    def boom(q):
        raise RuntimeError("boom")
    calls = stub_providers(monkeypatch, {"a": boom, "b": ok("B")})
    s = sp.Searcher(pick=lambda xs: xs[0])
    with pytest.raises(sp.SearchError, match="boom"):
        run(s.query("q"))
    assert calls == ["a"]


def test_fixed_provider_does_not_fail_over_on_429(monkeypatch):
    calls = stub_providers(monkeypatch, {"a": too_many(), "b": ok("B")})
    with pytest.raises(sp.SearchError):
        run(sp.Searcher(selection="a").query("q"))
    assert calls == ["a"]


def test_explicit_provider_overrides_selection(monkeypatch):
    stub_providers(monkeypatch, {"a": ok("A"), "b": ok("B")})
    assert run(sp.Searcher(selection="a").query("q", provider="b"))[0] == "b"
    with pytest.raises(ValueError, match="Unknown"):
        run(sp.Searcher().query("q", provider="zzz"))


def test_off_and_invalid_selection(monkeypatch):
    stub_providers(monkeypatch, {"a": ok("A")})
    with pytest.raises(RuntimeError, match="disabled"):
        run(sp.Searcher(selection="off").query("q"))
    with pytest.raises(ValueError, match="Invalid WEBSEARCH_PROVIDER"):
        run(sp.Searcher(selection="nope").query("q"))


def test_cooldown_parsing():
    assert sp._cooldown_seconds(None, 0) == 60
    assert sp._cooldown_seconds("5", 0) == 5
    assert sp._cooldown_seconds("-1", 0) == 60
    assert sp._cooldown_seconds("garbage", 0) == 60
    assert sp._cooldown_seconds("Thu, 01 Jan 1970 00:01:40 GMT", 40) == 60


def test_websearch_tool_output(monkeypatch):
    stub_providers(monkeypatch, {"a": lambda q: [sp.Result(url="https://x", title="T", content="c", published=0)]})
    monkeypatch.setattr(server, "searcher", sp.Searcher(selection="a"))
    out = run(server.websearch("q"))
    assert out.startswith("Title: T\nURL: https://x\nPublished: 19") and out.endswith("Content:\nc")
    stub_providers(monkeypatch, {"a": lambda q: []})
    assert "No search results" in run(server.websearch("q"))
