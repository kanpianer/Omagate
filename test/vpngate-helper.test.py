#!/usr/bin/env python3
"""Security regression tests for the VPN Gate relay-directory helper.

Run with: python3 test/vpngate-helper.test.py
"""

import base64
import gzip
import importlib.machinery
import importlib.util
import json
import os
import ssl
import stat
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER_PATH = os.path.join(PROJECT_ROOT, "vpngate-helper")
with open(HELPER_PATH, "r", encoding="utf-8") as helper_file:
    HELPER_SOURCE = helper_file.read()

# Loading the extensionless helper through SourceFileLoader would otherwise
# leave a __pycache__ directory in the repository.
sys.dont_write_bytecode = True


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vpngate_helper_under_test", HELPER_PATH)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def make_node(ip="8.8.8.8", port=443, name=None):
    return {
        "name": name or f"#US {ip}",
        "ip": ip,
        "port": port,
        "hostname": "public-vpn-1.opengw.net",
        "country": "United States",
        "countryCode": "US",
        "flag": "\U0001F1FA\U0001F1F8",
        "ping": 12,
        "speed": 1000000,
        "speedText": "1.0 Mbps",
        "sessions": 3,
        "uptime": 1000,
        "uptimeText": "16m",
        "operator": "test",
    }


def make_row(hostname, ip, port=None, country="Japan", code="JP"):
    b64 = ""
    if port is not None:
        b64 = base64.b64encode(f"remote {ip} {port}\ntls-client\n".encode()).decode()
    fields = [
        hostname, ip, "1", "10", "1000000", country, code, "5",
        "1000", "10", "100", "2weeks", "operator", "", b64,
    ]
    return ",".join(fields)


class HelperTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env_backup = {key: os.environ.get(key) for key in ("XDG_RUNTIME_DIR", "HOME")}
        os.environ["XDG_RUNTIME_DIR"] = os.path.join(self.temp.name, "run")
        os.environ["HOME"] = os.path.join(self.temp.name, "home")
        os.makedirs(os.environ["XDG_RUNTIME_DIR"], mode=0o700, exist_ok=True)
        os.makedirs(os.environ["HOME"], mode=0o700, exist_ok=True)

        def restore_environment():
            for key, value in self.env_backup.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        self.addCleanup(restore_environment)

    def test_directory_is_fetched_over_verified_tls_only(self):
        helper = self.helper
        self.assertTrue(helper.is_allowed_fetch_url(helper.VPNGATE_FETCH_URL))
        for url in (
            "http://www.vpngate.net/api/iphone/",
            "https://www.vpngate.net.evil.example/api/iphone/",
            "https://evil.example/api/iphone/",
            "https://www.vpngate.net:8443/api/iphone/",
            "https://user:pass@www.vpngate.net/api/iphone/",
            "https://www.vpngate.net@evil.example/api/iphone/",
            "ftp://www.vpngate.net/api/iphone/",
        ):
            self.assertFalse(helper.is_allowed_fetch_url(url), url)

    def test_no_plaintext_fetch_url_remains_in_source(self):
        self.assertNotIn("http://", HELPER_SOURCE)

    def test_tls_context_requires_certificate_and_hostname_checks(self):
        context = self.helper.tls_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        self.assertGreaterEqual(context.minimum_version, ssl.TLSVersion.TLSv1_2)

    def test_redirect_handler_refuses_downgrades_and_foreign_hosts(self):
        handler = self.helper.HttpsOnlyRedirectHandler()
        for target in (
            "http://www.vpngate.net/api/iphone/",
            "https://evil.example/api/iphone/",
        ):
            with self.assertRaises(urllib.error.HTTPError):
                handler.redirect_request(None, None, 302, "Found", {}, target)

        request = urllib.request.Request(self.helper.VPNGATE_FETCH_URL)
        redirected = handler.redirect_request(
            request, None, 302, "Found", {}, self.helper.VPNGATE_FETCH_URL)
        self.assertEqual(redirected.full_url, self.helper.VPNGATE_FETCH_URL)

    def test_parse_nodes_keeps_only_public_endpoints(self):
        content = "\n".join([
            "*vpn_servers",
            "#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,"
            "NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,"
            "Message,OpenVPN_ConfigData_Base64",
            make_row("public-vpn-1", "8.8.8.8", 8443),
            make_row("public-vpn-2", "10.0.0.1", 443),
            make_row("public-vpn-3", "127.0.0.1", 443),
            make_row("public-vpn-4", "8.8.8.8", 443),
            make_row("bad host!", "1.1.1.1", 99999),
        ])
        nodes = self.helper.parse_nodes(content)
        self.assertEqual([node["ip"] for node in nodes], ["8.8.8.8", "1.1.1.1"])
        self.assertEqual(nodes[0]["port"], 8443)
        self.assertEqual(nodes[0]["name"], "#JP 8.8.8.8")
        self.assertEqual(nodes[1]["port"], 443)
        self.assertEqual(nodes[1]["hostname"], "")

    def runtime_cache(self):
        return self.helper.get_cache_paths()[0]

    def remove_home_cache(self):
        home_cache = self.helper.get_cache_paths()[1]
        if os.path.exists(home_cache):
            os.unlink(home_cache)

    def test_cache_round_trip_is_private_and_versioned(self):
        helper = self.helper
        nodes = [make_node()]
        helper.save_cached_nodes(nodes)
        path = self.runtime_cache()
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        loaded = helper.load_cached_nodes()
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded[0]["ip"], "8.8.8.8")

        self.remove_home_cache()
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(nodes, handle)
        os.chmod(path, 0o600)
        self.assertIsNone(helper.load_cached_nodes(), "legacy plaintext-era cache was trusted")

        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "source": helper.VPNGATE_FETCH_URL, "nodes": nodes}, handle)
        os.chmod(path, 0o600)
        self.assertIsNone(helper.load_cached_nodes(), "unexpected cache version was trusted")

    def test_cache_rejects_unsafe_files(self):
        helper = self.helper
        helper.save_cached_nodes([make_node()])
        self.remove_home_cache()
        path = self.runtime_cache()

        os.chmod(path, 0o644)
        self.assertIsNone(helper.load_cached_nodes(), "world-readable cache was trusted")
        os.chmod(path, 0o600)

        linked = os.path.join(self.temp.name, "linked-cache.json")
        os.link(path, linked)
        self.assertIsNone(helper.load_cached_nodes(), "hardlinked cache was trusted")
        os.unlink(linked)

        os.unlink(path)
        target = os.path.join(self.temp.name, "target.json")
        with open(target, "w", encoding="utf-8") as handle:
            json.dump({"version": 2, "source": helper.VPNGATE_FETCH_URL,
                       "nodes": [make_node()]}, handle)
        os.chmod(target, 0o600)
        os.symlink(target, path)
        self.assertIsNone(helper.load_cached_nodes(), "symlinked cache was trusted")

    def test_endpoint_validation_rejects_non_public_and_malformed_values(self):
        helper = self.helper
        self.assertEqual(helper.normalize_endpoint("8.8.8.8", "443"), ("8.8.8.8", 443))
        for ip, port in (
            ("127.0.0.1", "443"),
            ("10.0.0.1", "443"),
            ("169.254.1.1", "443"),
            ("224.0.0.1", "443"),
            ("0.0.0.0", "443"),
            ("::1", "443"),
            ("8.8.8.8", "0"),
            ("8.8.8.8", "65536"),
            ("8.8.8.8", "abc"),
            ("8.8.8.8", "443/../../"),
            ("", "443"),
        ):
            self.assertIsNone(helper.normalize_endpoint(ip, port), (ip, port))

    def test_account_names_cannot_smuggle_control_characters_or_options(self):
        helper = self.helper
        self.assertTrue(helper.valid_account_name("#US 8.8.8.8"))
        self.assertFalse(helper.valid_account_name("#US 8.8.8.8\n/SERVER:evil:443"))
        self.assertFalse(helper.valid_account_name("/SERVER:evil:443"))
        self.assertFalse(helper.valid_account_name("-SERVER:evil:443"))
        self.assertFalse(helper.valid_account_name("x" * 129))

    def test_invalid_endpoints_never_reach_vpncmd(self):
        helper = self.helper
        calls = []

        def forbidden_run(*args, **kwargs):
            calls.append(args)
            raise AssertionError("vpncmd was invoked for an invalid endpoint")

        original_run = helper.subprocess.run
        helper.subprocess.run = forbidden_run
        try:
            self.assertEqual(helper.add_node("127.0.0.1", "443", "#XX 127.0.0.1"), 1)
            self.assertEqual(helper.add_node("8.8.8.8", "443", "/SERVER:evil:443"), 1)
            self.assertEqual(helper.direct_node("10.0.0.1", "443"), 1)
            self.assertEqual(helper.direct_node("8.8.8.8", "0"), 1)
        finally:
            helper.subprocess.run = original_run
        self.assertEqual(calls, [])

    def test_valid_endpoint_is_normalized_before_vpncmd(self):
        helper = self.helper
        calls = []

        class Result:
            returncode = 0
            stdout = ""
            stderr = ""

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return Result()

        original_run = helper.subprocess.run
        helper.subprocess.run = fake_run
        try:
            self.assertEqual(helper.add_node("8.8.8.8", "443", "#US 8.8.8.8"), 0)
        finally:
            helper.subprocess.run = original_run
        self.assertIn("/SERVER:8.8.8.8:443", calls[0])

    def test_fetch_uses_validated_cache_when_https_is_blocked(self):
        helper = self.helper
        helper.save_cached_nodes([make_node()])

        def blocked():
            raise RuntimeError("network blocked by on-path attacker")

        helper.fetch_remote_content = blocked
        nodes = helper.fetch_vpngate_nodes(force=True)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["ip"], "8.8.8.8")

    def test_fetch_never_falls_back_to_a_plaintext_source(self):
        helper = self.helper
        for path in helper.get_cache_paths():
            if os.path.exists(path):
                os.unlink(path)

        def blocked():
            raise RuntimeError("network blocked")

        helper.fetch_remote_content = blocked
        self.assertEqual(helper.fetch_vpngate_nodes(force=True), [])

    def test_response_from_untrusted_final_url_is_rejected(self):
        helper = self.helper

        class FakeResponse:
            def __init__(self, url, payload):
                self.url = url
                self.payload = payload

            def geturl(self):
                return self.url

            def read(self, size=-1):
                return self.payload

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        class FakeOpener:
            def __init__(self, response):
                self.response = response

            def open(self, request, timeout=None):
                return self.response

        original_build_opener = urllib.request.build_opener
        try:
            urllib.request.build_opener = lambda *args, **kwargs: FakeOpener(
                FakeResponse("http://www.vpngate.net/api/iphone/", b"*vpn_servers\n"))
            with self.assertRaises(ValueError):
                helper.fetch_remote_content()

            urllib.request.build_opener = lambda *args, **kwargs: FakeOpener(
                FakeResponse(helper.VPNGATE_FETCH_URL, gzip.compress(b"*vpn_servers\n")))
            self.assertEqual(helper.fetch_remote_content(), "*vpn_servers\n")
        finally:
            urllib.request.build_opener = original_build_opener


if __name__ == "__main__":
    unittest.main(verbosity=2)
