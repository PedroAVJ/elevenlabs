#!/usr/bin/env python3
"""Manage ElevenLabs credentials without printing secret values."""

from __future__ import annotations

import argparse
import json
import sys

import credential_store


def _emit(payload: dict, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, indent=2))
        return
    if payload["configured"]:
        print(f"ElevenLabs is configured via {payload['source']}.")
    else:
        print("ElevenLabs is not configured.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Manage the ElevenLabs API credential in macOS Keychain."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    status_parser = sub.add_parser("status", help="show credential availability")
    status_parser.add_argument("--json", action="store_true")

    import_parser = sub.add_parser(
        "import-environment",
        help="copy ELEVENLABS_API_KEY from this process into macOS Keychain",
    )
    import_parser.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.command == "import-environment":
        try:
            credential_store.store_environment_api_key()
        except credential_store.CredentialStoreError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
    _emit(credential_store.status(), as_json=args.json)


if __name__ == "__main__":
    main()
