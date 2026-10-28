# mcp-web

MCP server providing `websearch` and `webfetch`, copied from the behaviour of the tools in [opencode](https://github.com/sst/opencode).

| Tool | Behaviour |
|---|---|
| `websearch(query, num_results=8, livecrawl="fallback", type="auto", context_max_characters=None)` | Exa's hosted MCP endpoint (`web_search_exa`), no key needed; SSE reply parsed; 25 s timeout. |
| `webfetch(url, format="markdown", timeout=30)` | GET with browser UA and format-specific `Accept`; redirects followed; `markdown`/`text` conversion of HTML (script/style/etc. dropped), other types returned as is; max 5 MB; timeout max 120 s; retry with a plain UA on a Cloudflare challenge; images returned as image content. |

## Run

```bash
pip install -r requirements.txt
python server.py                                   # stdio
MCP_TRANSPORT=streamable-http python server.py     # http://127.0.0.1:8000/mcp (MCP_HOST, MCP_PORT)
```

Client config (stdio), e.g. Claude Code: `claude mcp add web -- python /path/to/mcp-web/server.py`

Optional env: `EXA_API_KEY` (higher Exa rate limits), `EXA_MCP_URL` (override endpoint).

## Test

```bash
pip install pytest && python -m pytest tests
```

Not copied from opencode: its permission prompts, and the 10000-char default is Exa's, not enforced here.
