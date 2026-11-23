#!/usr/bin/env python3
"""Docker healthcheck for the nanobot gateway.

Uses only the root-owned system Python and stdlib; no curl or venv dependency.
Drops privileges to the nanobot user when invoked as root and exits nonzero on
any exception, including a non-200 response.
"""

import os
import pwd
import sys
import urllib.request


def _drop_privileges() -> None:
    if os.geteuid() != 0:
        return
    pw = pwd.getpwnam("nanobot")
    os.initgroups(pw.pw_name, pw.pw_gid)
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)


def main() -> int:
    port = os.environ.get("NANOBOT_HEALTH_PORT") or "18790"
    url = f"http://127.0.0.1:{port}/health"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        _drop_privileges()
        with opener.open(url, timeout=3) as response:
            if response.status == 200:
                return 0
            print(f"healthcheck: unexpected status {response.status}", file=sys.stderr)
            return 1
    except Exception as exc:  # noqa: BLE001 - healthcheck must fail closed
        print(f"healthcheck: {url} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
