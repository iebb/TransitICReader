import unittest
from importlib.util import find_spec

from tools.release.macos_signing import decrypt_bundle, encrypt_bundle


@unittest.skipUnless(find_spec("cryptography"), "cryptography is installed by the macOS release workflow")
class MacSigningBackupTests(unittest.TestCase):
    def test_private_material_round_trips_without_plaintext(self):
        files = {"key.pem": b"synthetic private signing material", "certificate-id": b"synthetic-id"}
        encrypted = encrypt_bundle(files, "synthetic password")
        self.assertNotIn(files["key.pem"], encrypted)
        self.assertEqual(decrypt_bundle(encrypted, "synthetic password"), files)
        self.assertNotEqual(encrypted, encrypt_bundle(files, "synthetic password"))

    def test_wrong_password_or_tampering_cannot_restore_signing_material(self):
        from cryptography.exceptions import InvalidTag
        encrypted = encrypt_bundle({"key.pem": b"synthetic key"}, "synthetic password")
        with self.assertRaises(InvalidTag):
            decrypt_bundle(encrypted, "wrong password")
        corrupted = encrypted[:-1] + bytes([encrypted[-1] ^ 1])
        with self.assertRaises(InvalidTag):
            decrypt_bundle(corrupted, "synthetic password")

    def test_backup_cannot_write_outside_its_private_directory(self):
        encrypted = encrypt_bundle({"../outside": b"synthetic"}, "synthetic password")
        with self.assertRaisesRegex(RuntimeError, "Unexpected files"):
            decrypt_bundle(encrypted, "synthetic password")
