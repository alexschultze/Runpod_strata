# Issue: `/openai/v1` returns 502 Bad Gateway (handler ignores `openai_route` / `openai_input`)

**Title:** OpenAI-compatible route (`/openai/v1/...`) returns 502 Bad Gateway

## Summary
Calling the endpoint through Runpod's OpenAI-compatible URL (for example with the OpenAI SDK) fails with `502 Bad Gateway`. The native `/run` and `/runsync` requests with `messages` or `prompt` work.

## Steps to reproduce
1. Deploy the worker (default image, e.g. `HF_MODEL=unsloth/SmolLM2-135M-Instruct-GGUF`).
2. Run:
   ```
   curl https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1/chat/completions \
     -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
     -d '{"model":"unsloth/SmolLM2-135M-Instruct-GGUF","messages":[{"role":"user","content":"hello"}]}'
   ```
3. Result: `502 Bad Gateway`.

## Cause (from reading the code)
Runpod's OpenAI route hands the handler the request wrapped as the job input:

```json
{"input": {"openai_route": "/v1/chat/completions", "openai_input": {"model": "...", "messages": [...]}}}
```

`handler()` in `handler.py` only reads `input.messages` and `input.prompt`. It never looks at `openai_route` or `openai_input`, so it returns `"Provide either 'messages' (chat) or 'prompt' (completion) in input."`, which is not an OpenAI response. Ollama already serves an OpenAI-compatible API under `/v1`; the handler just doesn't forward to it.

Note: the wrapper format is taken from Runpod's documented OpenAI route behaviour and other Runpod workers, not captured from a live request. Worker logs from a failing call would confirm it.

## Proposed fix
Patch attached (`worker-ollama-openai-route.patch`, based on `1848765`):

- `handler()` detects `openai_route` and forwards to Ollama's `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings` and `/v1/models`.
- `stream: true` keeps the SSE framing (`data: ...`, `data: [DONE]`).
- A blank `model`, or one equal to `HF_MODEL` / `OLLAMA_MODEL`, uses the default model. Other names are pulled on demand.
- Errors use the OpenAI error shape; unsupported routes return a clear error.
- Native `messages` / `prompt` requests are unchanged.
- Adds `test_openai.py` (8 unit tests, run in CI), three Hub test cases, and a README section.

## Testing status
- Unit tests pass locally and in GitHub Actions (patched upstream `1848765`).
- **Not yet verified on a live Runpod endpoint.** The Hub tests (`openai_chat_completions`, `openai_chat_completions_streaming`, `openai_models`) should be run before merging.
