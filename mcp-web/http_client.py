"""Single place that creates the HTTP client for every outbound web call (websearch and webfetch)."""
import httpx

# Proxy for all web calls: "none" (no proxy, and HTTP(S)_PROXY/ALL_PROXY in the environment are ignored)
# or a proxy URL such as "http://host:3128". Hard coded for now.
WEB_PROXY = "none"


def proxy_url() -> str | None:
    value = WEB_PROXY.strip()
    return None if value.lower() in ("", "none") else value


def new_client(**kwargs) -> httpx.AsyncClient:
    return httpx.AsyncClient(proxy=proxy_url(), trust_env=False, **kwargs)
