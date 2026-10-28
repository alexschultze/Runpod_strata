# mcp-web

MCP server providing `websearch` and `webfetch`, copied from the behaviour of the tools in [opencode](https://github.com/sst/opencode).

| Tool | Behaviour |
|---|---|
| `websearch(query, provider=None)` | Five providers as in opencode (`packages/core/src/plugin/websearch`): Exa, Firecrawl, Parallel, Tavily, TinyFish, 8 results, 25 s timeout. All work without a key (rate limited by the provider); a key in the environment is used when set. |
| `webfetch(url, format="markdown", timeout=30)` | GET with browser UA and format-specific `Accept`; redirects followed; `markdown`/`text` conversion of HTML (script/style/etc. dropped), other types returned as is; max 5 MB; timeout max 120 s; retry with a plain UA on a Cloudflare challenge; images returned as image content. |

## Search provider selection (`WEBSEARCH_PROVIDER`)

| Value | Behaviour |
|---|---|
| `random` (default) | One provider is picked at random and kept. When it answers HTTP 429 it goes on cooldown (`Retry-After`, default 60 s) and another provider takes over; when all are cooling down the last 429 error is returned. Other errors are returned as they are, without switching. |
| `exa`, `firecrawl`, `parallel`, `tavily`, `tinyfish` | Always that provider, no failover. |
| `off` | `websearch` is disabled. |

The tool's optional `provider` argument overrides the setting for one call. Keys: `EXA_API_KEY`, `FIRECRAWL_API_KEY`, `PARALLEL_API_KEY`, `TAVILY_API_KEY`, `TINYFISH_API_KEY`. Note: Firecrawl's keyless quota is small and often used up (reported as an error), so set its key or choose another provider.

## Proxy

Every outbound call (both tools, all providers) is made through `http_client.new_client()`, which uses `WEB_PROXY` from `http_client.py`. It is hard coded to `"none"`: no proxy, and `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` in the environment are ignored. Set it to a proxy URL (e.g. `"http://host:3128"`) to route all web calls through it.

## Run

```bash
pip install -r requirements.txt
python server.py                                   # stdio
MCP_TRANSPORT=streamable-http python server.py     # http://127.0.0.1:8000/mcp (MCP_HOST, MCP_PORT)
```

Client config (stdio), e.g. Claude Code: `claude mcp add web -- python /path/to/mcp-web/server.py`

## Test

```bash
pip install pytest && python -m pytest tests
```

Not copied from opencode: its permission prompts and the per-user provider choice stored in its KV store (here: `WEBSEARCH_PROVIDER`).
