#!/usr/bin/env python3
"""Check how long one search can refresh every 2 minutes before Apple throttles it.

Sends what one ReadyForPickup search sends per refresh
(FulfillmentModel.fetchInventory): the product's models in the country, 20
per pickup-message request, with the store's location, the buy page as
Referer and the app's User-Agent. It refreshes every --interval seconds
(default 120, the app's fastest auto-refresh), logs each request's HTTP
status with a timestamp, and stops at the first 429 or 541 (how Apple
throttles) or block page, after --hours, or after 5 failed refreshes in a
row. The connection itself is Python's (HTTP/1.1, OpenSSL), not the app's
URLSession, so Apple's bot detection may still tell the two apart.

The requests go out from this Mac's address, and a block stops every client
on the network, ReadyForPickup and the iPhone app included, for up to half an
hour. Apple seems to count this script's calls apart from the app's, though:
on 2026-10-21 both were refused when the app had made its own 31st call in
about 94 minutes, with 22 of the probe's calls in between, and the app alone
every 2 minutes got 31 answers before each of four later blocks. To measure
the app itself, read its log, where CFNetwork records every response status:
    /usr/bin/log show --style compact --last 6h --predicate \
        'process == "ReadyForPickup" AND eventMessage CONTAINS "received response, status"'

Usage (Python 3.9+, standard library only):
    Scripts/probe-throttle.py --dry-run           # print the requests, send nothing
    Scripts/probe-throttle.py --log ~/probe.log   # SoHo, iPhone 18 Pro, up to 6 hours
    Scripts/probe-throttle.py --store R095 --product iPhoneDuo --hours 2

Exit status: 0 if Apple never throttled the run, 3 if it did, 1 after 5
failed refreshes in a row, 130 if stopped (Ctrl-C or SIGTERM).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import plistlib
import re
import signal
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_FILE = HERE.parent / "ReadyForPickup.xcodeproj" / "project.pbxproj"
CFNETWORK_PLIST = Path("/System/Library/Frameworks/CFNetwork.framework/Resources/Info.plist")
MIN_INTERVAL = 120          # seconds: the app's fastest auto-refresh
MAX_FAILURES = 5            # failed refreshes in a row before giving up


def _load_catalog_tool():
    """update-catalog.py has the app's pickup request shape, and loads the
    shared paced Apple client from update-store-list.py."""
    sys.dont_write_bytecode = True      # no __pycache__ in Scripts/
    spec = importlib.util.spec_from_file_location("update_catalog", HERE / "update-catalog.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog_tool = _load_catalog_tool()
store_tool = catalog_tool.store_tool


def app_headers() -> dict:
    """The headers the app's URLSession sends that the paced client's
    differ from: "ReadyForPickup/<CFBundleVersion> CFNetwork/<version>
    Darwin/<kernel>" and Accept */*."""
    match = re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", PROJECT_FILE.read_text(encoding="utf-8"))
    try:
        with CFNETWORK_PLIST.open("rb") as file:
            cfnetwork = plistlib.load(file)["CFBundleVersion"]
    except (OSError, KeyError, plistlib.InvalidFileException):
        cfnetwork = "0"
    version = match.group(1) if match else "0"
    return {"User-Agent": f"ReadyForPickup/{version} CFNetwork/{cfnetwork} Darwin/{platform.release()}",
            "Accept": "*/*"}


def search_requests(country_code: str, store_id: str, product: str) -> tuple:
    """(description, Referer, pickup URLs) for one search's refresh."""
    catalog = json.loads(catalog_tool.CATALOG_FILE.read_text(encoding="utf-8"))
    country = next((c for c in catalog["countries"] if c["code"] == country_code), None)
    if country is None:
        raise SystemExit(f"error: no country {country_code} in {catalog_tool.CATALOG_FILE.name}")
    models = country["products"].get(product)
    if not models:
        raise SystemExit(f"error: no {product} in {country_code}; it has {', '.join(country['products'])}")
    skus = list(dict.fromkeys(model["sku"] for model in models))
    stores = catalog_tool.load_stores().get(country["locale"], [])
    store = next((s for s in stores if s["id"] == store_id), None)
    if store is None:
        raise SystemExit(f"error: no store {store_id} for {country['locale']} in {catalog_tool.STORE_FILE.name}")
    host, path = country["storeHost"], country["storePath"]
    location = catalog_tool.app_location(store)
    urls = [catalog_tool.pickup_url(host, path, location, skus[start:start + catalog_tool.CHUNK])
            for start in range(0, len(skus), catalog_tool.CHUNK)]
    description = f"{product} ({len(skus)} models) at {store_id} {store['name']} ({location})"
    return description, catalog_tool.storefront_url(host, path, "shop/buy-iphone/"), urls


def outcome(resp, store_id: str) -> tuple:
    """("ok", "throttled" or "failed", note) for one pickup response."""
    if resp.status in (429, 541):
        return "throttled", "throttled"
    if resp.status == 403 and b"access denied" in resp.body[:4000].lower():
        return "throttled", "Access Denied page"
    parsed, error = catalog_tool.parse_pickup(resp)
    if resp.status == 200 and error == "response is not JSON":
        return "throttled", "not JSON, probably a block page"
    if not parsed:
        return "failed", error
    stores = dict(parsed)
    if store_id not in stores:
        return "ok", f"{plural(len(stores), 'store')}, not {store_id}"
    available = sum(1 for display, _ in stores[store_id].values() if display == "available")
    return "ok", f"{plural(len(stores), 'store')}; {store_id} has {available} of {len(stores[store_id])} models available"


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}{'' if count == 1 else 's'}"


def duration(seconds: float) -> str:
    hours, minutes = divmod(round(seconds / 60), 60)
    return f"{hours} h {minutes} min" if hours else f"{minutes} min"


class Log:
    """Prints each line, and appends it to `path` too if given."""

    def __init__(self, path: Path | None):
        self.file = path.expanduser().open("a", encoding="utf-8") if path else None

    def __call__(self, line: str = "") -> None:
        print(line, flush=True)
        if self.file:
            self.file.write(line + "\n")
            self.file.flush()


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--country", default="US", help="ProductCatalog.json country code (default US)")
    parser.add_argument("--store", default="R032", help="store number (default R032, SoHo, the app's first search)")
    parser.add_argument("--product", default="iPhonePro18", help="ProductType raw value (default iPhonePro18)")
    parser.add_argument("--interval", type=float, default=MIN_INTERVAL,
                        help=f"seconds between refreshes, at least {MIN_INTERVAL} (default {MIN_INTERVAL})")
    parser.add_argument("--hours", type=float, default=6.0, help="stop after this long (default 6)")
    parser.add_argument("--log", type=Path, help="also append every line to this file")
    parser.add_argument("--dry-run", action="store_true", help="print the requests without sending them")
    args = parser.parse_args()
    if args.interval < MIN_INTERVAL:
        parser.error(f"--interval must be at least {MIN_INTERVAL} seconds, the app's fastest auto-refresh")
    if args.hours <= 0:
        parser.error("--hours must be more than 0")

    description, referer, urls = search_requests(args.country.upper(), args.store.upper(), args.product)
    headers = app_headers()
    refreshes = max(1, round(args.hours * 3600 / args.interval))
    log = Log(args.log)
    log(f"Refreshing {description} every {args.interval:g} s, at most {refreshes} times, "
        f"{plural(len(urls), 'request')} each, until Apple throttles")
    for url in urls:
        log(f"  GET {url}")
    log(f"  Referer: {referer}")
    log(f"  User-Agent: {headers['User-Agent']}")
    if args.dry_run:
        log("dry run: nothing sent")
        return 0

    client = store_tool.AppleClient(log=open(os.devnull, "w", encoding="utf-8"), headers=headers,
                                    max_requests=refreshes * len(urls))
    signal.signal(signal.SIGTERM, _interrupt)
    first = None
    answered = failures = 0
    result = "ended"
    try:
        for refresh in range(1, refreshes + 1):
            verdict = "ok"
            for index, url in enumerate(urls):
                wait = args.interval if refresh > 1 and index == 0 else 0.0
                try:
                    resp = client.fetch(url, referer=referer, expect_json=True, min_interval=wait)
                    code = f"HTTP {resp.status}"
                    verdict, note = outcome(resp, args.store.upper())
                except store_tool.AppleError as error:
                    code, verdict, note = "no answer", "failed", str(error)
                now = datetime.now().astimezone()
                first = first or now
                log(f"{now:%Y-%m-%d %H:%M:%S %z}  #{client.requests:<4} {code}  {note}")
                if verdict != "ok":
                    break
                answered += 1
            if verdict == "throttled":
                result = "throttled"
                break
            failures = failures + 1 if verdict == "failed" else 0
            if failures >= MAX_FAILURES:
                result = "failed"
                break
    except KeyboardInterrupt:
        result = "stopped"

    span = duration((datetime.now().astimezone() - first).total_seconds()) if first else "0 min"
    sent = client.requests
    if result == "throttled":
        log(f"Throttled at request {sent}, {span} after the first; Apple answered {answered} before it.")
        return 3
    if result == "failed":
        log(f"Gave up after {MAX_FAILURES} failed refreshes in a row: {sent} requests over {span}, "
            f"{answered} answered, none throttled.")
        return 1
    log(f"{'Stopped' if result == 'stopped' else 'Done'}: {sent} requests over {span}, "
        f"{answered} answered, none throttled.")
    return 130 if result == "stopped" else 0


if __name__ == "__main__":
    sys.exit(main())
