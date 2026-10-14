# Open the Strata website of a Serverless worker with one link

`strata.php` runs on your own web server (PHP with the curl extension). The Runpod API key stays on that server; the browser only gets a link with
your own access token.

```
https://your-server.example/strata.php?t=<ACCESS_TOKEN>
```

What it does: starts the job `{"input": {"path": "/api_direct"}}` on your queue endpoint (a worker starts if none runs; the first start after a pause
takes minutes), shows a status page that reloads every 5 seconds, and redirects (302) to `https://<worker id>-8080.proxy.runpod.net/` when the worker
answered. Log in on the Strata page with the Strata key (`STRATA_API_KEY`).

## Setup

1. Copy `strata.php` to the web server. Put the three settings either into the web server's environment or into `strata-config.php` next to it
   (copy `strata-config.example.php`; the file is in `.gitignore`):
   - `RUNPOD_API_KEY` (best: a key restricted to this one endpoint), `RUNPOD_ENDPOINT_ID`
   - `ACCESS_TOKEN`: your own long random secret (`openssl rand -hex 24`). Changing it revokes every old link.
2. Serve it over https (the token is part of the URL: it appears in access logs and the browser history).
3. Open the link, bookmark it.

Notes: the worker still stops after the endpoint's idle timeout, opening the website does not keep it alive. The redirect only ever goes to
`https://<id>-<port>.proxy.runpod.net/`. Tested with PHP's built-in server and a fake Runpod API (`tests/test_redirect.py`), not against a real
Runpod endpoint.
