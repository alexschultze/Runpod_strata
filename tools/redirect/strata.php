<?php
/*
 * Opens the Strata website of a Runpod Serverless worker in the browser, without the Runpod key ever leaving this server.
 *
 *   https://your-server.example/strata.php?t=<ACCESS_TOKEN>
 *
 * It starts a job {"input": {"path": "/api_direct"}} on the queue endpoint (this starts a worker when none is running: a cold start takes
 * minutes), shows a status page that reloads every 5 seconds, and redirects (302) to the worker's URL https://<worker id>-8080.proxy.runpod.net/
 * as soon as the job has answered. On that page you log in with the Strata key (STRATA_API_KEY), not with anything from here.
 *
 * Settings (environment variables of the web server, or a file strata-config.php next to this one that returns an array):
 *   RUNPOD_API_KEY      the Runpod API key (keep it on the server; a key restricted to this endpoint is best)
 *   RUNPOD_ENDPOINT_ID  the queue endpoint
 *   ACCESS_TOKEN        your own secret for the link above (long and random; change it to revoke every old link)
 *   RUNPOD_API_BASE     optional, default https://api.runpod.ai/v2
 * Needs the PHP curl extension. The token is part of the URL: it shows up in access logs and the browser history, so use https.
 */
declare(strict_types=1);

function cfg(string $k, ?string $default = null): ?string
{
    static $file = null;
    if ($file === null) {
        $p = __DIR__ . '/strata-config.php';
        $file = is_file($p) ? (array) include $p : [];
    }
    $v = getenv($k);
    if ($v !== false && $v !== '') return $v;
    return isset($file[$k]) && $file[$k] !== '' ? (string) $file[$k] : $default;
}

function page(int $code, string $title, string $body, int $refresh = 0, string $url = ''): void
{
    http_response_code($code);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    header('Referrer-Policy: no-referrer');
    $meta = $refresh > 0 ? '<meta http-equiv="refresh" content="' . $refresh . ';url=' . htmlspecialchars($url, ENT_QUOTES) . '">' : '';
    echo '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' . $meta
        . '<title>' . htmlspecialchars($title) . '</title><body style="font-family:sans-serif;max-width:40em;margin:3em auto;padding:0 1em">'
        . '<h2>' . htmlspecialchars($title) . '</h2>' . $body;
    exit;
}

function runpod(string $method, string $path, ?array $json = null): array
{
    $ch = curl_init(rtrim((string) cfg('RUNPOD_API_BASE', 'https://api.runpod.ai/v2'), '/') . '/' . cfg('RUNPOD_ENDPOINT_ID') . $path);
    $opt = [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20, CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . cfg('RUNPOD_API_KEY'), 'Content-Type: application/json']];
    if ($json !== null) $opt[CURLOPT_POSTFIELDS] = json_encode($json);
    curl_setopt_array($ch, $opt);
    $raw = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($raw === false) page(502, 'Runpod is not reachable', '<p>' . htmlspecialchars($err) . '</p>');
    $data = json_decode((string) $raw, true);
    if ($code >= 400 || !is_array($data)) page(502, 'Runpod answered with an error', '<p>HTTP ' . $code . '</p>');
    return $data;
}

foreach (['RUNPOD_API_KEY', 'RUNPOD_ENDPOINT_ID', 'ACCESS_TOKEN'] as $k) {
    if (cfg($k) === null) page(500, 'Not configured', '<p>' . $k . ' is missing on the server.</p>');
}
if (!hash_equals((string) cfg('ACCESS_TOKEN'), (string) ($_GET['t'] ?? ''))) page(403, 'Forbidden', '<p>Wrong or missing token.</p>');

$token = (string) $_GET['t'];
$self = strtok($_SERVER['REQUEST_URI'] ?? '/', '?');
$job = (string) ($_GET['job'] ?? '');
$since = max(0, (int) ($_GET['since'] ?? 0));

if ($job === '') {   // start the job; the worker may have to be started first
    $r = runpod('POST', '/run', ['input' => ['path' => '/api_direct']]);
    if (empty($r['id'])) page(502, 'Runpod did not return a job id', '');
    $next = $self . '?t=' . rawurlencode($token) . '&job=' . rawurlencode((string) $r['id']) . '&since=' . time();
    page(200, 'Starting the worker ...', '<p>The first start after a pause takes a few minutes (on new hardware up to 15-20 minutes).</p>', 3, $next);
}
if (!preg_match('/^[A-Za-z0-9-]{1,100}$/', $job)) page(400, 'Bad job id', '');

$s = runpod('GET', '/status/' . $job);
$status = (string) ($s['status'] ?? '');
if ($status === 'COMPLETED') {
    $out = $s['output'] ?? null;
    if (is_array($out) && isset($out[0])) $out = $out[0];     // a generator handler's output arrives as a list
    $url = is_array($out) ? (string) ($out['url'] ?? '') : '';
    if (!preg_match('#^https://[A-Za-z0-9-]+-\d+\.proxy\.runpod\.net/#', $url)) {
        $msg = is_array($out) && isset($out['error']) ? json_encode($out['error']) : 'no worker URL in the answer';
        page(502, 'The worker did not return its URL', '<p>' . htmlspecialchars((string) $msg) . '</p>');
    }
    header('Cache-Control: no-store');
    header('Location: ' . $url, true, 302);
    exit;
}
if (in_array($status, ['FAILED', 'CANCELLED', 'TIMED_OUT'], true)) {
    page(502, 'The job ended: ' . $status, '<p><a href="' . htmlspecialchars($self . '?t=' . rawurlencode($token)) . '">Try again</a></p>');
}
$wait = $since > 0 ? time() - $since : 0;
$next = $self . '?t=' . rawurlencode($token) . '&job=' . rawurlencode($job) . '&since=' . ($since ?: time());
page(200, 'Starting the worker ...', '<p>Status: ' . htmlspecialchars($status ?: 'unknown') . ($wait ? ', waiting ' . intdiv($wait, 60) . ' min ' . ($wait % 60) . ' s' : '') . '</p>'
    . '<p>This page reloads by itself and opens the website when the worker is ready.</p>', 5, $next);
