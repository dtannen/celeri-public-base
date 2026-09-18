#!/usr/bin/env python3
"""Exercise the installed Nginx asset policy using synthetic files and loopback.

Run in an isolated base-image container with --network none. No FPM, application,
workers, or external services are started; all fixtures live in a temporary root.
"""

import gzip
import http.client
import pathlib
import subprocess
import tempfile
import time


def main():
    build = subprocess.run(["nginx", "-V"], capture_output=True, text=True, check=True)
    assert "--with-http_gzip_static_module" in build.stderr, "gzip_static is required"

    with tempfile.TemporaryDirectory(prefix="celeri-nginx-assets-") as directory:
        temporary = pathlib.Path(directory)
        temporary.chmod(0o755)
        root = temporary / "public"
        root.mkdir()
        generation = "a" * 64
        asset_root = root / "nova-static" / generation
        asset_root.mkdir(parents=True)
        source = ("/* synthetic asset */\nconst marker = 'asset-check';\n" * 100).encode()

        def fixture(relative, contents=source, compressed=False):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            if compressed:
                pathlib.Path(str(path) + ".gz").write_bytes(gzip.compress(contents, mtime=0))
            return "/" + relative

        prefix = f"nova-static/{generation}/"
        scripted = fixture(prefix + "nova-components/Example/dist/js/tool.js", compressed=True)
        styled = fixture(prefix + "public/vendor/nova/app.css", compressed=True)
        svg = fixture(prefix + "nova/resources/icon.svg", compressed=True)
        source_map = fixture(prefix + "public/vendor/nova/app.js.map", b'{"version":3}')
        license_notice = fixture(prefix + "public/vendor/nova/app.js.LICENSE.txt", b"Synthetic license notice")
        fallback = fixture(prefix + "public/js/fallback.js")
        fonts = [fixture(prefix + "fonts/sample." + suffix, b"font-fixture")
                 for suffix in ("woff", "woff2", "ttf", "otf", "eot")]
        images = [fixture(prefix + "images/sample." + suffix, b"image-fixture")
                  for suffix in ("png", "jpg", "jpeg", "gif", "webp", "avif", "ico")]
        refused = [fixture(prefix + "private." + suffix, b"must-not-be-served")
                   for suffix in ("php", "html", "json", "gz", "txt")]
        unhashed = fixture("nova-static/tool.js")
        short_hash = fixture("nova-static/" + "a" * 63 + "/tool.js")
        uppercase_hash = fixture("nova-static/" + "A" * 64 + "/tool.js")
        unrelated_js = fixture("vendor/nova/app.js")
        html = fixture("page.html", b"<p>Uncached page</p>")
        json = fixture("api/example.json", b'{"fixture": true}')

        site = pathlib.Path("/etc/nginx/sites-available/homestead").read_text()
        site = site.replace("listen 80 default_server;", "listen 127.0.0.1:18080 default_server;")
        site = site.replace("root /var/www/html/app/public;", f"root {root};")
        site = site.replace("/var/log/nginx/app-error.log", str(temporary / "site-error.log"))
        (temporary / "site.conf").write_text(site)
        (temporary / "fastcgi_params").write_text(pathlib.Path("/etc/nginx/fastcgi_params").read_text())
        config = temporary / "nginx.conf"
        config.write_text(
            f"pid {temporary}/nginx.pid;\nerror_log {temporary}/error.log;\n"
            "events { worker_connections 64; }\n"
            "http { include /etc/nginx/mime.types; default_type application/octet-stream;\n"
            # Compression must come from the asset location, not a global default.
            f"gzip off; include {temporary}/site.conf; }}\n"
        )
        subprocess.run(["nginx", "-t", "-c", str(config)], check=True)
        server = subprocess.Popen(["nginx", "-c", str(config), "-g", "daemon off;"])
        checks = 0

        def request(url, encoding=None, headers=None, method="GET"):
            connection = http.client.HTTPConnection("127.0.0.1", 18080, timeout=3)
            try:
                sent = dict(headers or {})
                if encoding is not None:
                    sent["Accept-Encoding"] = encoding
                connection.request(method, url, headers=sent)
                response = connection.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                connection.close()

        def check(url, *, status=200, immutable=False, encoding=None, body=None,
                  content_type=None, compressed=False, headers=None, method="GET"):
            nonlocal checks
            actual, received, payload = request(url, encoding, headers, method)
            assert actual == status, (url, actual, status)
            assert ("immutable" in received.get("Cache-Control", "")) == immutable, (url, received)
            if immutable:
                assert received["Cache-Control"] == "public, max-age=31536000, immutable"
                assert received["X-Frame-Options"] == "SAMEORIGIN"
                assert received["X-Content-Type-Options"] == "nosniff"
                assert received["X-XSS-Protection"] == "1; mode=block"
            if content_type:
                assert received.get("Content-Type", "").startswith(content_type), received
            assert (received.get("Content-Encoding") == "gzip") == compressed, (url, received)
            if body is not None:
                assert (gzip.decompress(payload) if compressed else payload) == body, url
            checks += 1
            return received, payload

        try:
            for attempt in range(50):
                try:
                    request(html)
                    break
                except ConnectionRefusedError:
                    if server.poll() is not None:
                        raise RuntimeError("Nginx exited before accepting requests")
                    time.sleep(0.02)
            else:
                raise RuntimeError("Nginx did not start")

            for url, mime in ((scripted, "application/javascript"), (styled, "text/css"),
                              (svg, "image/svg+xml")):
                headers, _ = check(url, immutable=True, body=source, content_type=mime)
                assert "Accept-Encoding" in headers.get("Vary", ""), headers
                compressed_headers, payload = check(url, immutable=True, encoding="gzip", body=source,
                                                    content_type=mime, compressed=True)
                assert "Accept-Encoding" in compressed_headers.get("Vary", ""), compressed_headers
                assert payload == pathlib.Path(str(root / url.lstrip("/")) + ".gz").read_bytes(), \
                    "Nginx must serve the precompressed sibling"
                check(url, immutable=True, encoding="gzip;q=0", body=source)

            headers, _ = check(fallback, immutable=True, encoding="gzip", body=source, compressed=True)
            assert "Accept-Encoding" in headers.get("Vary", ""), headers
            check(scripted + "?id=legacy", immutable=True, body=source)
            check(scripted, immutable=True, method="HEAD", body=b"")
            plain_headers, _ = check(scripted, immutable=True)
            check(scripted, status=304, immutable=True, headers={"If-None-Match": plain_headers["ETag"]})
            check(scripted, status=206, immutable=True, headers={"Range": "bytes=0-5"}, body=source[:6])
            for url in fonts + images:
                check(url, immutable=True, encoding="gzip")
            check(source_map, immutable=True, content_type="application/json", body=b'{"version":3}')
            check(license_notice, immutable=True, content_type="text/plain", body=b"Synthetic license notice")
            for url in refused + [unhashed, short_hash, uppercase_hash, "/nova-static", "/nova-static/",
                                  "/" + prefix + "missing.js", scripted + ".gz", "/" + prefix]:
                check(url, status=404, encoding="gzip")
            # A compressed orphan must not turn a missing source into a cached hit.
            fixture(prefix + "orphan.js.gz", gzip.compress(source, mtime=0))
            check("/" + prefix + "orphan.js", status=404, encoding="gzip")
            for url in (unrelated_js, html, json):
                headers, _ = check(url, encoding="gzip")
                assert "Cache-Control" not in headers, headers
            print(f"Nginx static assets: {checks} HTTP checks passed (offline)")
        finally:
            server.terminate()
            server.wait(timeout=5)


if __name__ == "__main__":
    main()
