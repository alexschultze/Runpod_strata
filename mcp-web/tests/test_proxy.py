import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import http_client  # noqa: E402


def test_default_is_no_proxy():
    assert http_client.WEB_PROXY == "none" and http_client.proxy_url() is None


@pytest.mark.parametrize("value,expected", [("none", None), ("None", None), ("", None), ("http://p:3128", "http://p:3128")])
def test_proxy_url(monkeypatch, value, expected):
    monkeypatch.setattr(http_client, "WEB_PROXY", value)
    assert http_client.proxy_url() == expected


def test_environment_proxy_is_ignored(monkeypatch):
    monkeypatch.setenv("HTTPS_PROXY", "http://env-proxy:1")
    monkeypatch.setenv("ALL_PROXY", "http://env-proxy:1")
    client = http_client.new_client()
    assert client._mounts == {}  # no proxy transports picked up from the environment


def test_custom_proxy_is_mounted(monkeypatch):
    monkeypatch.setattr(http_client, "WEB_PROXY", "http://p:3128")
    assert http_client.new_client()._mounts  # proxy transports are mounted for http:// and https://


def test_all_web_calls_use_new_client():
    root = Path(__file__).resolve().parent.parent
    for f in ("server.py", "search_providers.py"):
        assert "httpx.AsyncClient(" not in (root / f).read_text(), f
