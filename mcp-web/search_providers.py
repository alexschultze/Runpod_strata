"""Web search providers and their selection, ported from opencode (packages/core/src/websearch.ts and
packages/core/src/plugin/websearch/*.ts): Exa, Firecrawl, Parallel, Tavily, TinyFish.

All five work without a key (rate limited); an API key in the environment is used when set.
"""
import json
import os
import random
import re
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Awaitable, Callable

import httpx

TIMEOUT = 25.0
MAX_RESPONSE_BYTES = 256 * 1024
NUM_RESULTS = 8
USER_AGENT = "mcp-web"
DEFAULT_COOLDOWN = 60.0


@dataclass
class Result:
    url: str
    title: str | None = None
    content: str | None = None
    published: float | None = None  # ms since epoch


def _key(name: str) -> str | None:
    return os.environ.get(name) or None


def _published_ms(text: str | None) -> float | None:
    if not text or text == "N/A":
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


async def _post(client: httpx.AsyncClient, url: str, payload: dict, headers: dict) -> httpx.Response:
    resp = await client.post(url, json=payload, headers=headers)
    resp.raise_for_status()
    if len(resp.content) > MAX_RESPONSE_BYTES:
        raise RuntimeError(f"response exceeded {MAX_RESPONSE_BYTES} bytes")
    return resp


def parse_mcp_result(body: str) -> dict | None:
    """The `result` of a JSON-RPC reply that is either plain JSON or SSE ('data: {...}' lines)."""
    for raw in [body.strip(), *(l[6:] for l in body.split("\n") if l.startswith("data: "))]:
        if not raw.strip().startswith("{"):
            continue
        try:
            result = json.loads(raw).get("result")
        except ValueError:
            continue
        if result is not None:
            return result
    return None


async def mcp_call(client: httpx.AsyncClient, url: str, tool: str, arguments: dict, headers: dict | None = None) -> dict | None:
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}
    hdrs = {"accept": "application/json, text/event-stream", "content-type": "application/json", **(headers or {})}
    resp = await _post(client, url, payload, hdrs)
    result = parse_mcp_result(resp.text)
    if (result or {}).get("isError"):
        raise RuntimeError(((_first_text(result) or "tool returned an error").strip())[:500])
    return result


def _first_text(result: dict | None) -> str | None:
    for item in (result or {}).get("content") or []:
        if item.get("text"):
            return item["text"]
    return None


def _bearer(key: str | None) -> dict:
    return {"Authorization": f"Bearer {key}"} if key else {}


# ------------------------------------------------------------------------------------------ providers

async def exa(client: httpx.AsyncClient, query: str) -> list[Result]:
    url = "https://mcp.exa.ai/mcp"
    if key := _key("EXA_API_KEY"):
        url += f"?exaApiKey={key}"
    result = await mcp_call(client, url, "web_search_exa", {"query": query, "numResults": NUM_RESULTS})
    text = _first_text(result)
    out = []
    for block in re.split(r"\n\n---\n\n", text or ""):
        def field_(name: str) -> str | None:
            m = re.search(rf"^{name}:\s*(.+)$", block, re.M)
            return m.group(1).strip() if m else None
        url_ = field_("URL")
        if not url_:
            continue
        title = field_("Title")
        m = re.search(r"^(?:Highlights|Text):\s*\n?([\s\S]*)$", block, re.M)
        out.append(Result(
            url=url_,
            title=title if title and title != "N/A" else None,
            content=m.group(1).strip() or None if m else None,
            published=_published_ms(field_("Published")),
        ))
    return out


async def parallel(client: httpx.AsyncClient, query: str) -> list[Result]:
    result = await mcp_call(
        client, "https://search.parallel.ai/mcp", "web_search",
        {"objective": query, "search_queries": [query]},
        {"User-Agent": USER_AGENT, **_bearer(_key("PARALLEL_API_KEY"))},
    )
    items = ((result or {}).get("structuredContent") or {}).get("results") or []
    return [
        Result(
            url=i["url"],
            title=i.get("title") or None,
            content="\n\n".join(i.get("excerpts") or []) or None,
            published=_published_ms(i.get("publish_date")),
        )
        for i in items
    ]


async def firecrawl(client: httpx.AsyncClient, query: str) -> list[Result]:
    result = await mcp_call(
        client, "https://mcp.firecrawl.dev/v2/mcp", "firecrawl_search",
        {"query": query, "limit": NUM_RESULTS},
        {"User-Agent": USER_AGENT, **_bearer(_key("FIRECRAWL_API_KEY"))},
    )
    text = _first_text(result)
    try:
        web = json.loads(text)["data"]["web"] if text else []
    except (ValueError, KeyError, TypeError):
        web = []
    return [Result(url=i["url"], title=i.get("title") or None, content=i.get("description") or None) for i in web]


async def tavily(client: httpx.AsyncClient, query: str) -> list[Result]:
    key = _key("TAVILY_API_KEY")
    headers = {
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
        "X-Client-Name": "mcp-web",
        **(_bearer(key) if key else {"X-Tavily-Access-Mode": "keyless"}),
    }
    resp = await _post(
        client, "https://api.tavily.com/search",
        {"query": query, "search_depth": "basic", "chunks_per_source": 3, "max_results": NUM_RESULTS},
        headers,
    )
    return [Result(url=i["url"], title=i.get("title"), content=i.get("content") or None) for i in resp.json()["results"]]


TINYFISH_URL = "https://agent.tinyfish.ai/mcp"


async def _tinyfish_session(client: httpx.AsyncClient, headers: dict) -> str:
    init = {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-web", "version": "1.0"}},
    }
    base = {"accept": "application/json, text/event-stream", "content-type": "application/json", **headers}
    resp = await _post(client, TINYFISH_URL, init, base)
    session = resp.headers.get("mcp-session-id")
    if session is None:
        raise RuntimeError("TinyFish MCP initialize did not return an Mcp-Session-Id header")
    await _post(client, TINYFISH_URL, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {**base, "Mcp-Session-Id": session})
    return session


async def tinyfish(client: httpx.AsyncClient, query: str) -> list[Result]:
    key = _key("TINYFISH_API_KEY")
    headers = {"User-Agent": USER_AGENT, **({"X-API-Key": key} if key else {"X-TinyFish-Access-Mode": "keyless"})}
    # Keyed requests are rejected without the Mcp-Session-Id returned by initialize; keyless ones are not.
    if key:
        headers["Mcp-Session-Id"] = await _tinyfish_session(client, headers)
    result = await mcp_call(client, TINYFISH_URL, "search", {"query": query}, headers)
    text = _first_text(result)
    try:
        items = json.loads(text)["results"] if text else []
    except (ValueError, KeyError, TypeError):
        items = []
    return [Result(url=i["url"], title=i.get("title"), content=i.get("snippet") or None) for i in items]


PROVIDERS: dict[str, tuple[str, Callable[[httpx.AsyncClient, str], Awaitable[list[Result]]]]] = {
    "exa": ("Exa", exa),
    "firecrawl": ("Firecrawl", firecrawl),
    "parallel": ("Parallel", parallel),
    "tavily": ("Tavily", tavily),
    "tinyfish": ("TinyFish", tinyfish),
}


# ------------------------------------------------------------------------------------------ selection

class SearchError(RuntimeError):
    def __init__(self, provider: str, cause: Exception):
        super().__init__(f"{PROVIDERS[provider][0]} web search failed: {cause}")
        self.provider = provider
        self.cause = cause


def _cooldown_seconds(retry_after: str | None, now: float) -> float:
    if not retry_after or not retry_after.strip():
        return DEFAULT_COOLDOWN
    try:
        seconds = float(retry_after)
        return seconds if seconds >= 0 else DEFAULT_COOLDOWN
    except ValueError:
        pass
    try:
        from email.utils import parsedate_to_datetime
        return max(0.0, parsedate_to_datetime(retry_after).timestamp() - now)
    except (TypeError, ValueError):
        return DEFAULT_COOLDOWN


@dataclass
class Searcher:
    """selection: a provider id, 'random' (spread over all providers, fail over on HTTP 429) or 'off'."""
    selection: str = "random"
    clock: Callable[[], float] = time.time
    pick: Callable[[list[str]], str] = random.choice
    _cooldowns: dict[str, tuple[float, SearchError]] = field(default_factory=dict)
    _affinity: str | None = None  # the provider this session keeps using until it cools down

    def _random_provider(self, attempted: set[str]) -> str | None:
        now = self.clock()
        self._cooldowns = {k: v for k, v in self._cooldowns.items() if v[0] > now}
        cur = self._affinity
        if cur and cur not in self._cooldowns and cur not in attempted:
            return cur
        available = [p for p in PROVIDERS if p not in self._cooldowns and p not in attempted]
        if not available:
            return None
        self._affinity = self.pick(available)
        return self._affinity

    async def query(self, query: str, provider: str | None = None) -> tuple[str, list[Result]]:
        if provider is not None:
            if provider not in PROVIDERS:
                raise ValueError(f"Unknown web search provider '{provider}'. Available: {', '.join(PROVIDERS)}")
            randomize = False
        elif self.selection == "off":
            raise RuntimeError("Web search is disabled")
        elif self.selection == "random":
            randomize = True
        elif self.selection in PROVIDERS:
            provider, randomize = self.selection, False
        else:
            raise ValueError(f"Invalid WEBSEARCH_PROVIDER '{self.selection}'. Use one of: {', '.join(PROVIDERS)}, random, off")

        attempted: set[str] = set()
        if randomize:
            provider = self._random_provider(attempted)
        while True:
            cooldown = self._cooldowns.get(provider) if randomize else None
            if cooldown is None or cooldown[0] <= self.clock():
                attempted.add(provider)
                try:
                    async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True) as client:
                        return provider, await PROVIDERS[provider][1](client, query)
                except httpx.TimeoutException as e:
                    error = SearchError(provider, RuntimeError("request timed out"))
                    cause = e
                except Exception as e:  # noqa: BLE001 - any provider failure is reported with the provider name
                    error = SearchError(provider, e)
                    cause = e
                is_429 = isinstance(cause, httpx.HTTPStatusError) and cause.response.status_code == 429
                if not randomize or not is_429:
                    raise error from cause
                now = self.clock()
                cooldown = (now + _cooldown_seconds(cause.response.headers.get("retry-after"), now), error)
                self._cooldowns[provider] = cooldown
            provider = self._random_provider(attempted)
            if provider is None:
                raise cooldown[1]


def format_results(provider: str, results: list[Result]) -> str:
    if not results:
        return "No search results found. Please try a different query."
    blocks = []
    for r in results:
        lines = [f"Title: {r.title or 'N/A'}", f"URL: {r.url}"]
        if r.published is not None:
            lines.append("Published: " + datetime.fromtimestamp(r.published / 1000).astimezone().date().isoformat())
        if r.content:
            lines += ["Content:", r.content]
        blocks.append("\n".join(lines))
    return "\n\n---\n\n".join(blocks)
