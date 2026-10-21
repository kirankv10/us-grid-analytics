"""Small client for the EIA Open Data API (v2) with paging and retries."""

import logging
import time

import requests

BASE_URL = "https://api.eia.gov/v2"
PAGE_SIZE = 5000                      # EIA v2 returns at most 5,000 rows per request
RETRYABLE_STATUS = {429, 500, 502, 503, 504}

log = logging.getLogger(__name__)


class EIAClient:
    def __init__(self, api_key, max_retries=4, pause_seconds=0.25, session=None):
        if not api_key:
            raise ValueError("EIA_API_KEY is missing. Add it to your .env file.")
        self.api_key = api_key
        self.max_retries = max_retries
        self.pause_seconds = pause_seconds
        self.session = session or requests.Session()

    def _get(self, url, params):
        """GET with exponential back-off on network errors and retryable status codes."""
        for attempt in range(1, self.max_retries + 1):
            try:
                response = self.session.get(url, params=params, timeout=60)
                if response.status_code in RETRYABLE_STATUS:
                    raise requests.HTTPError(
                        f"Retryable status {response.status_code}", response=response
                    )
                response.raise_for_status()
                payload = response.json()
                if "error" in payload:
                    raise RuntimeError(f"EIA API error: {payload['error']}")
                return payload
            except (requests.ConnectionError, requests.Timeout, requests.HTTPError) as exc:
                status = exc.response.status_code if exc.response is not None else None
                retryable = status is None or status in RETRYABLE_STATUS
                if not retryable or attempt == self.max_retries:
                    raise
                wait = 2 ** attempt
                log.warning("Request failed (%s). Retry %d in %ds", exc, attempt, wait)
                time.sleep(wait)

    def fetch_all(self, route, params):
        """Download every row for a query, following EIA's offset-based paging.

        route  e.g. "electricity/rto/region-data"
        params list of (key, value) tuples, so array keys like
               "facets[respondent][]" can repeat.
        """
        url = f"{BASE_URL}/{route.strip('/')}/data/"
        rows, offset, total = [], 0, None

        while True:
            page_params = list(params) + [
                ("api_key", self.api_key),
                ("offset", offset),
                ("length", PAGE_SIZE),
            ]
            payload = self._get(url, page_params)
            body = payload.get("response", {})
            data = body.get("data", [])
            if total is None:
                total = int(body.get("total", 0) or 0)

            rows.extend(data)
            offset += len(data)
            log.info("  %s: %d / %d rows", route, offset, total)

            if not data or offset >= total:
                break
            time.sleep(self.pause_seconds)

        return rows
