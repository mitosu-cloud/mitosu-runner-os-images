#!/usr/bin/env python3
"""Fetch immutable GitHub Release assets and compare every byte to a signed pack."""

import argparse
import hashlib
from pathlib import Path
import re
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request

ASSET_HOSTS = {"release-assets.githubusercontent.com", "objects.githubusercontent.com"}


def release_base_valid(url):
    parsed = urlsplit(url)
    return (
        parsed.scheme == "https" and parsed.netloc == "github.com"
        and not parsed.query and not parsed.fragment
        and re.fullmatch(r"/[A-Za-z0-9_-][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*/releases/download/[A-Za-z0-9_-][A-Za-z0-9._-]*/", parsed.path) is not None
        and parsed.path.split("/")[-2] != "latest"
    )


def redirect_allowed(url):
    parsed = urlsplit(url)
    return (
        parsed.scheme == "https" and parsed.hostname in ASSET_HOSTS
        and parsed.port in (None, 443) and not parsed.username and not parsed.password
        and not parsed.fragment
    )


class GitHubAssetRedirects(HTTPRedirectHandler):
    def __init__(self):
        self.hops = 0

    def redirect_request(self, request, response, code, message, headers, new_url):
        self.hops += 1
        if self.hops > 3 or not redirect_allowed(new_url):
            raise HTTPError(request.full_url, code, "GitHub asset redirect refused", headers, response)
        return super().redirect_request(request, response, code, message, headers, new_url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--expected-pack", type=Path, required=True)
    args = parser.parse_args()
    if not release_base_valid(args.base_url):
        raise SystemExit("error: source must be an explicit GitHub Release download directory")
    for expected in sorted(args.expected_pack.iterdir()):
        if not expected.is_file() or expected.is_symlink():
            raise SystemExit("error: GitHub Release pack must contain only flat regular files")
        expected_size = expected.stat().st_size
        digest = hashlib.sha256()
        with expected.open("rb") as source:
            while chunk := source.read(128 * 1024):
                digest.update(chunk)
        opener = build_opener(GitHubAssetRedirects())
        request = Request(urljoin(args.base_url, expected.name), headers={"Accept-Encoding": "identity"})
        actual = hashlib.sha256()
        size = 0
        with opener.open(request, timeout=60) as response:
            if response.status != 200:
                raise SystemExit("error: GitHub Release asset returned an unexpected HTTP status")
            while chunk := response.read(128 * 1024):
                size += len(chunk)
                if size > expected_size:
                    raise SystemExit("error: GitHub Release asset exceeds signed file size")
                actual.update(chunk)
        if size != expected_size or actual.digest() != digest.digest():
            raise SystemExit(f"error: published GitHub Release asset changed: {expected.name}")
    print("verified public GitHub Release asset bytes")


if __name__ == "__main__":
    main()
