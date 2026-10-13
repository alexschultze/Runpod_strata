Fix for runpod-workers/worker-ollama (OpenAI route returns 502).

    git clone https://github.com/<you>/worker-ollama   # your fork
    cd worker-ollama
    git checkout -b fix/openai-route
    git am /path/to/worker-ollama-openai-route.patch
    git push -u origin fix/openai-route

Then open the PR using PR_DESCRIPTION.md. The patch is based on upstream commit 1848765.
