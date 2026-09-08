import importlib.util
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = PLUGIN_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location(
    "elevenlabs_credential_store", SCRIPTS / "credential_store.py"
)
CREDENTIALS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CREDENTIALS)


class ElevenLabsCredentialStoreTests(unittest.TestCase):
    def test_environment_override_is_preferred_without_reading_keychain(self):
        with (
            mock.patch.dict(os.environ, {"ELEVENLABS_API_KEY": "environment-key"}),
            mock.patch.object(CREDENTIALS, "keychain_api_key") as keychain,
        ):
            value, source = CREDENTIALS.resolve_api_key()

        self.assertEqual(value, "environment-key")
        self.assertEqual(source, "environment")
        keychain.assert_not_called()

    def test_keychain_is_the_default_when_the_environment_is_empty(self):
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(
                CREDENTIALS,
                "subprocess",
            ) as subprocess_module,
        ):
            subprocess_module.run.return_value = subprocess.CompletedProcess(
                [], 0, "keychain-key\n", ""
            )
            value, source = CREDENTIALS.resolve_api_key()

        self.assertEqual(value, "keychain-key")
        self.assertEqual(source, "keychain")
        self.assertNotIn("keychain-key", subprocess_module.run.call_args.args[0])

    def test_status_reports_availability_without_reading_or_returning_the_key(self):
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(CREDENTIALS, "keychain_configured", return_value=True),
            mock.patch.object(CREDENTIALS, "keychain_api_key") as keychain_read,
        ):
            result = CREDENTIALS.status()

        self.assertTrue(result["configured"])
        self.assertEqual(result["source"], "keychain")
        self.assertTrue(result["keychain_configured"])
        keychain_read.assert_not_called()

    def test_import_stores_the_environment_key_without_echoing_it(self):
        secret = "never-echo-this"
        with (
            mock.patch.dict(os.environ, {"ELEVENLABS_API_KEY": secret}),
            mock.patch.object(CREDENTIALS, "subprocess") as subprocess_module,
        ):
            subprocess_module.run.return_value = subprocess.CompletedProcess(
                [], 0, "", ""
            )
            CREDENTIALS.store_environment_api_key()

        command = subprocess_module.run.call_args.args[0]
        self.assertEqual(command[-2:], [secret, "-U"])


if __name__ == "__main__":
    unittest.main()
