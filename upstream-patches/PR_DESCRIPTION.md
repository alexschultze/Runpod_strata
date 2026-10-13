# Support Runpod's OpenAI-compatible route (fixes 502 Bad Gateway on `/openai/v1`)

## Problem
Calling the endpoint through `https://api.runpod.ai/v2/<ID>/openai/v1/...` (e.g. with the OpenAI SDK) returns **502 Bad Gateway**.

Runpod's OpenAI gateway does not forward the client's body as-is. It wraps it as the job input:

```json
{"input": {"openai_route": "/v1/chat/completions", "openai_input": {"model": "...", "messages": [...]}}}
```

`handler.py` only reads `input.messages` / `input.prompt`. It never looked at `openai_route`, so every OpenAI call hit "Provide either 'messages' or 'prompt'" and the gateway turned the non-OpenAI error into a 502. Ollama itself already serves an OpenAI-compatible API under `/v1`; it just was never wired up.

## Fix
- `handler()` detects `openai_route` and delegates to `handle_openai()`.
- Forwards `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings` (POST) and `/v1/models` (GET) to Ollama's `/v1/*`.
- `stream: true` keeps the SSE framing (`data: ...\n\n`, `data: [DONE]`) the OpenAI SDKs parse.
- `model` blank, or equal to the configured `HF_MODEL` / `OLLAMA_MODEL`, resolves to the default model; other names are pulled on demand like the native API. (Clients must send a model name, and the HF repo id is not the name Ollama registered.)
- Errors use the OpenAI error shape; unsupported routes return a 404-style error instead of a crash.
- Native `messages`/`prompt` requests are untouched.

## Tests
- New `test_openai.py` (8 unit tests, no GPU/network), added to the CI `test` job.
- New Hub cases in `.runpod/tests.json`: `openai_chat_completions`, `openai_chat_completions_streaming`, `openai_models`.
- `pytest test_openai.py test_selection.py test_warmup.py`: 121 passed.
- Not run on a real GPU endpoint (no Runpod access from this environment); please run the Hub tests before merging.

## README
Adds an "OpenAI-compatible API" section with SDK usage.
