#!/usr/bin/env python3
"""Resolve the ElevenLabs API key without persisting it in plugin files."""

from __future__ import annotations

import os
import subprocess


KEYCHAIN_SERVICE = os.environ.get(
    "ELEVENLABS_KEYCHAIN_SERVICE", "com.pedroavj.apps.elevenlabs"
)
KEYCHAIN_ACCOUNT = os.environ.get("ELEVENLABS_KEYCHAIN_ACCOUNT", "api-key")
SECURITY = "/usr/bin/security"


class CredentialStoreError(RuntimeError):
    pass


def environment_api_key() -> str | None:
    value = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    return value or None


def keychain_api_key() -> str | None:
    try:
        result = subprocess.run(
            [
                SECURITY,
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def keychain_configured() -> bool:
    try:
        result = subprocess.run(
            [
                SECURITY,
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def resolve_api_key() -> tuple[str | None, str | None]:
    configured = environment_api_key()
    if configured:
        return configured, "environment"
    configured = keychain_api_key()
    if configured:
        return configured, "keychain"
    return None, None


def store_environment_api_key() -> None:
    configured = environment_api_key()
    if not configured:
        raise CredentialStoreError(
            "ELEVENLABS_API_KEY is not available in this process; run the import "
            "from a shell where it is already configured"
        )
    try:
        result = subprocess.run(
            [
                SECURITY,
                "add-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
                configured,
                "-U",
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise CredentialStoreError("macOS Keychain is unavailable") from exc
    if result.returncode != 0:
        raise CredentialStoreError("macOS Keychain rejected the ElevenLabs credential")


def status() -> dict:
    environment_configured = environment_api_key() is not None
    keychain_is_configured = keychain_configured()
    source = "environment" if environment_configured else (
        "keychain" if keychain_is_configured else None
    )
    return {
        "configured": environment_configured or keychain_is_configured,
        "source": source,
        "environment_configured": environment_configured,
        "keychain_configured": keychain_is_configured,
        "keychain_service": KEYCHAIN_SERVICE,
        "keychain_account": KEYCHAIN_ACCOUNT,
    }
