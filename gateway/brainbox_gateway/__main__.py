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
    hp = sub.add_parser("hermes-proxy", help="run the secure Hermes API proxy (device tokens, allow-list, audit)")
    hp.add_argument("--config", required=True)
    hc = sub.add_parser("hermes-proxy-check", help="validate a hermes-proxy config without starting it")
    hc.add_argument("--config", required=True)
    nd = sub.add_parser("new-device", help="generate a device token for the Hermes proxy")
    nd.add_argument("--name", required=True)
    sub.add_parser("hash-token", help="hash a token you type (not echoed)")
    args = parser.parse_args(argv)

    if args.cmd == "new-token":
        token = secrets.token_urlsafe(32)
        print("Access token (paste into the app, Settings → Connection; shown once):")
        print(f"  {token}")
        print("Put this in the gateway config [auth]:")
        print(f'  token_sha256 = "{config.hash_token(token)}"')
        return 0
    if args.cmd == "new-device":
        token = secrets.token_urlsafe(32)
        print("Device token (paste into the app, Settings → Hermes; shown once):")
        print(f"  {token}")
        print("Add this to the hermes-proxy config:")
        print("  [[devices]]")
        print(f'  name = "{args.name}"')
        print(f'  token_sha256 = "{config.hash_token(token)}"')
        print("  admin = false")
        return 0
    if args.cmd in ("hermes-proxy", "hermes-proxy-check"):
        from . import hermes_proxy
        try:
            pcfg = hermes_proxy.load_config(args.config)
        except (OSError, ValueError, KeyError) as exc:
            print(f"config error: {exc}", file=sys.stderr)
            return 2
        if args.cmd == "hermes-proxy-check":
            key = hermes_proxy.resolve_hermes_key(pcfg)
            loose = [f for f in (args.config, pcfg.hermes_key_file, pcfg.hermes_env_file)
                     if f and hermes_proxy.insecure_permissions(f)]
            for f in loose:
                print(f"error: {f} is readable by group/others — run: chmod 600 {f}", file=sys.stderr)
            if loose:
                return 1
            print(f"OK · listen={pcfg.host}:{pcfg.port}{pcfg.prefix} upstream={pcfg.hermes_url} devices={len(pcfg.devices)} "
                  f"hermes_key={'found' if key else 'MISSING'} multiplex={pcfg.multiplex_profiles} "
                  f"profile_admin={pcfg.profile_admin_enabled} job_delivery={','.join(pcfg.allowed_deliver)}")
            return 0 if key else 1
        hermes_proxy.serve(pcfg)
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
