import hashlib
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import merjs
from merjs import install


BINARY = b"#!/bin/sh\necho mer\n"
ASSET = "mer-linux-x86_64"
CHECKSUMS = f"{hashlib.sha256(BINARY).hexdigest()}  {ASSET}\n".encode()


class Response:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return CHECKSUMS


class InstallerTests(unittest.TestCase):
    def platform_patches(self):
        return (
            mock.patch("merjs.platform.system", return_value="Linux"),
            mock.patch("merjs.platform.machine", return_value="x86_64"),
        )

    def fake_download(self, _url, destination):
        destination.write_bytes(BINARY)

    def test_cache_path_is_version_and_platform_specific(self):
        with tempfile.TemporaryDirectory() as cache, \
                mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache}, clear=False), \
                self.platform_patches()[0], self.platform_patches()[1]:
            path = merjs.get_binary_cache_path("1.2.3")
        self.assertEqual(
            path,
            Path(cache) / "merjs" / "1.2.3" / "linux-x86_64" / "mer",
        )

    def test_install_succeeds_with_read_only_package_directory(self):
        with tempfile.TemporaryDirectory() as root:
            package_dir = Path(root) / "site-packages" / "merjs"
            package_dir.mkdir(parents=True)
            package_dir.chmod(0o555)
            cache = Path(root) / "cache"
            try:
                with mock.patch.object(merjs, "__file__", str(package_dir / "__init__.py")), \
                        mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(cache)}, clear=False), \
                        self.platform_patches()[0], self.platform_patches()[1], \
                        mock.patch.object(install, "download", side_effect=self.fake_download), \
                        mock.patch.object(install.urllib.request, "urlopen", return_value=Response()):
                    path = install.ensure_binary(version="1.2.3")
                self.assertTrue(path.is_file())
                self.assertTrue(path.stat().st_mode & stat.S_IXUSR)
                self.assertEqual(list(package_dir.iterdir()), [])
            finally:
                package_dir.chmod(0o755)

    def test_concurrent_first_use_downloads_once(self):
        with tempfile.TemporaryDirectory() as cache, \
                mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache}, clear=False), \
                self.platform_patches()[0], self.platform_patches()[1], \
                mock.patch.object(install.urllib.request, "urlopen", return_value=Response()):
            calls = []
            calls_lock = threading.Lock()

            def slow_download(_url, destination):
                with calls_lock:
                    calls.append(destination)
                time.sleep(0.05)
                destination.write_bytes(BINARY)

            paths = []
            errors = []

            def first_use():
                try:
                    paths.append(install.ensure_binary(version="1.2.3"))
                except Exception as e:
                    errors.append(e)

            with mock.patch.object(install, "download", side_effect=slow_download):
                threads = [threading.Thread(target=first_use) for _ in range(4)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()

            self.assertEqual(errors, [])
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(set(paths)), 1)
            self.assertEqual(paths[0].read_bytes(), BINARY)

    def test_checksum_failure_removes_partial_download(self):
        bad_checksums = b"0" * 64 + b"  " + ASSET.encode() + b"\n"
        response = Response()
        response.read = lambda: bad_checksums
        with tempfile.TemporaryDirectory() as cache, \
                mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache}, clear=False), \
                self.platform_patches()[0], self.platform_patches()[1], \
                mock.patch.object(install, "download", side_effect=self.fake_download), \
                mock.patch.object(install.urllib.request, "urlopen", return_value=response):
            path = merjs.get_binary_cache_path("1.2.3")
            with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                install.ensure_binary(version="1.2.3")
            self.assertFalse(path.exists())
            self.assertEqual(list(path.parent.glob(".mer-download-*")), [])

    def test_missing_and_malformed_checksums_remove_partial_download(self):
        failures = (
            (f"{'0' * 64}  mer-linux-aarch64\n".encode(), "Checksum not found"),
            (f"not-a-checksum  {ASSET}\n".encode(), "Invalid checksum"),
        )
        for checksums, message in failures:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as cache, \
                    mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache}, clear=False), \
                    self.platform_patches()[0], self.platform_patches()[1], \
                    mock.patch.object(install, "download", side_effect=self.fake_download):
                response = Response()
                response.read = lambda value=checksums: value
                with mock.patch.object(install.urllib.request, "urlopen", return_value=response):
                    path = merjs.get_binary_cache_path("1.2.3")
                    with self.assertRaisesRegex(RuntimeError, message):
                        install.ensure_binary(version="1.2.3")
                self.assertFalse(path.exists())
                self.assertEqual(list(path.parent.glob(".mer-download-*")), [])

    def test_download_failures_remove_partial_download(self):
        failures = (
            (urllib.error.URLError("network failure"), "Checksum download failed"),
            (None, "binary download failed"),
        )
        for url_error, message in failures:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                bin_path = Path(directory) / "mer"
                if url_error is not None:
                    download = self.fake_download
                    urlopen = mock.patch.object(
                        install.urllib.request, "urlopen", side_effect=url_error
                    )
                else:
                    def download(_url, destination):
                        destination.write_bytes(b"partial")
                        raise RuntimeError(message)
                    urlopen = mock.patch.object(install.urllib.request, "urlopen")

                with mock.patch.object(install, "download", side_effect=download), urlopen:
                    with self.assertRaisesRegex(RuntimeError, message):
                        install.install_binary(
                            bin_path, "binary-url", "checksums-url", ASSET
                        )
                self.assertFalse(bin_path.exists())
                self.assertEqual(list(Path(directory).glob(".mer-download-*")), [])

    def test_unwritable_cache_error_is_actionable(self):
        with tempfile.TemporaryDirectory() as root:
            cache_file = Path(root) / "not-a-directory"
            cache_file.write_text("occupied")
            with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(cache_file)}, clear=False), \
                    self.platform_patches()[0], self.platform_patches()[1]:
                with self.assertRaisesRegex(RuntimeError, "Set XDG_CACHE_HOME to a writable directory"):
                    install.ensure_binary(version="1.2.3")


if __name__ == "__main__":
    unittest.main()
