"""Command line: serve / new-token / hash-token / check."""
from __future__ import annotations

import argparse
import asyncio
import getpass
import secrets
import sys

from . import __version__, config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="brainbox-gateway", description="Brainbox Agent Protocol v1 gateway")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run the gateway")
    s.add_argument("--config", required=True)
    c = sub.add_parser("check", help="validate a config file")
    c.add_argument("--config", required=True)
    sub.add_parser("new-token", help="generate a random access token and print it with its hash")
    sub.add_parser("hash-token", help="hash a token you type (not echoed)")
    args = parser.parse_args(argv)

    if args.cmd == "new-token":
        token = secrets.token_urlsafe(32)
        print("Access token (paste into the app, Settings → Connection; shown once):")
        print(f"  {token}")
        print("Put this in the gateway config [auth]:")
        print(f'  token_sha256 = "{config.hash_token(token)}"')
        return 0
    if args.cmd == "hash-token":
        token = getpass.getpass("Token: ")
        print(config.hash_token(token.strip()))
        return 0

    try:
        cfg = config.load(args.config)
    except (OSError, ValueError) as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2
    if args.cmd == "check":
        print(f"OK · adapter={cfg.adapter} hermes.mode={cfg.hermes.mode} verified={cfg.hermes.verified} "
              f"listen={cfg.host}:{cfg.port}{cfg.path} roots={[r.path for r in cfg.file_roots]} "
              f"services={cfg.services} terminal={'on' if cfg.terminal_enabled else 'off'}")
        return 0

    from .server import Gateway
    try:
        asyncio.run(Gateway(cfg).serve())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
