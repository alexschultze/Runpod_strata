#!/usr/bin/env python3
"""MCP server with `websearch` and `webfetch` tools, modelled on opencode's tools of the same name.

websearch  Exa, Firecrawl, Parallel, Tavily or TinyFish (all usable without a key). By default ("random") one is
           picked at random and kept until it answers HTTP 429, then another takes over, like opencode.
webfetch   Fetches a URL and returns it as markdown (default), plain text or raw HTML.
           5 MB response limit, 30 s default / 120 s max timeout, retry with a plain
           User-Agent when Cloudflare challenges a browser-like one, images returned as images.

Run:  python server.py                     (stdio)
      MCP_TRANSPORT=streamable-http python server.py   (HTTP on MCP_HOST:MCP_PORT)
"""
import os
from typing import Literal

import httpx
from bs4 import BeautifulSoup
from markdownify import MarkdownConverter
from mcp.server.fastmcp import FastMCP, Image

from search_providers import Searcher, format_results

MAX_RESPONSE_SIZE = 5 * 1024 * 1024
DEFAULT_TIMEOUT = 30
MAX_TIMEOUT = 120
BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
)
ACCEPT = {
    "markdown": "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1",
    "text": "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1",
    "html": "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1",
}

mcp = FastMCP(
    "web",
    host=os.environ.get("MCP_HOST", "127.0.0.1"),
    port=int(os.environ.get("MCP_PORT", "8000")),
)


# --------------------------------------------------------------------------- websearch

searcher = Searcher(selection=os.environ.get("WEBSEARCH_PROVIDER", "random").strip().lower())
ProviderName = Literal["exa", "firecrawl", "parallel", "tavily", "tinyfish"]


@mcp.tool()
async def websearch(query: str, provider: ProviderName | None = None) -> str:
    """Search the web. Returns the top results (title, URL, published date, content excerpts).

    Use for current events, recent information and anything beyond your knowledge cutoff.
    Include the current year in queries about recent material. Follow up with webfetch to read a result.

    Args:
        query: Web search query.
        provider: Optional search provider (exa, firecrawl, parallel, tavily, tinyfish). Normally omitted:
            the server picks one (see WEBSEARCH_PROVIDER) and switches provider when one is rate limited.
    """
    used, results = await searcher.query(query, provider)
    return format_results(used, results)


# --------------------------------------------------------------------------- webfetch

_STRIP_TEXT = ["script", "style", "noscript", "iframe", "object", "embed"]


def html_to_text(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(_STRIP_TEXT):
        tag.decompose()
    return soup.get_text(separator=" ", strip=True)


def html_to_markdown(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "meta", "link"]):
        tag.decompose()
    return MarkdownConverter(heading_style="ATX", bullets="-", code_language="").convert_soup(soup).strip()


def _check_url(url: str) -> None:
    if not url.startswith(("http://", "https://")):
        raise ValueError("URL must start with http:// or https://")


async def _get(client: httpx.AsyncClient, url: str, headers: dict) -> tuple[httpx.Response, bytes]:
    """GET with a hard cap on the body size."""
    async with client.stream("GET", url, headers=headers) as resp:
        length = resp.headers.get("content-length")
        if length and length.isdigit() and int(length) > MAX_RESPONSE_SIZE:
            raise RuntimeError("Response too large (exceeds 5MB limit)")
        body = bytearray()
        async for chunk in resp.aiter_bytes():
            body += chunk
            if len(body) > MAX_RESPONSE_SIZE:
                raise RuntimeError("Response too large (exceeds 5MB limit)")
        return resp, bytes(body)


@mcp.tool(structured_output=False)
async def webfetch(
    url: str,
    format: Literal["text", "markdown", "html"] = "markdown",
    timeout: int | None = None,
) -> str | Image:
    """Fetch content from a URL and return it as markdown, plain text or raw HTML.

    Use to read a specific web page, e.g. one found with websearch. The URL must be fully formed
    (http:// or https://). Read-only; responses over 5MB fail. Images are returned as images.

    Args:
        url: The URL to fetch content from.
        format: 'markdown' (default), 'text' or 'html'.
        timeout: Optional timeout in seconds (default 30, max 120).
    """
    _check_url(url)
    seconds = min(timeout or DEFAULT_TIMEOUT, MAX_TIMEOUT)
    headers = {
        "User-Agent": BROWSER_UA,
        "Accept": ACCEPT[format],
        "Accept-Language": "en-US,en;q=0.9",
    }
    try:
        async with httpx.AsyncClient(timeout=seconds, follow_redirects=True) as client:
            resp, body = await _get(client, url, headers)
            # Cloudflare bot challenge blocks browser-like UAs that lack a real fingerprint; an honest UA passes.
            if resp.status_code == 403 and resp.headers.get("cf-mitigated") == "challenge":
                resp, body = await _get(client, url, {**headers, "User-Agent": "mcp-web"})
    except httpx.TimeoutException:
        raise RuntimeError(f"Request timed out after {seconds}s")
    if resp.status_code >= 400:
        raise RuntimeError(f"Request failed with status code: {resp.status_code}")

    content_type = resp.headers.get("content-type", "")
    mime = content_type.split(";")[0].strip().lower()
    if mime.startswith("image/") and mime != "image/svg+xml":
        return Image(data=body, format=mime.split("/", 1)[1])

    content = body.decode(resp.encoding or "utf-8", errors="replace")
    if "text/html" in content_type or "application/xhtml" in content_type:
        if format == "markdown":
            return html_to_markdown(content)
        if format == "text":
            return html_to_text(content)
    return content


if __name__ == "__main__":
    mcp.run(transport=os.environ.get("MCP_TRANSPORT", "stdio"))
