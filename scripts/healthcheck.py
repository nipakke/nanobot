#!/usr/bin/env python3
"""Docker healthcheck for the nanobot gateway.

Uses only the venv Python and stdlib; no curl dependency. Exits nonzero on any
exception, including a non-200 response.
"""

import os
import sys
import urllib.request


def main() -> int:
    port = os.environ.get("NANOBOT_HEALTH_PORT", "18790")
    url = f"http://127.0.0.1:{port}/health"
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            if response.status == 200:
                return 0
            print(f"healthcheck: unexpected status {response.status}", file=sys.stderr)
            return 1
    except Exception as exc:  # noqa: BLE001 - healthcheck must fail closed
        print(f"healthcheck: {url} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
