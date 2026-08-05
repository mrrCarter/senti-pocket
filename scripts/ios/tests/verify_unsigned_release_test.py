#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_unsigned_release.py"
SPEC = importlib.util.spec_from_file_location("verify_unsigned_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
verify = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verify
SPEC.loader.exec_module(verify)


class UnsignedReleaseVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings_path = self.root / "settings.json"
        self.source_privacy_path = self.root / "PrivacyInfo.xcprivacy"
        self.products_root = self.root / "Build" / "Products"
        self.expected = verify.Expectations(
            target="SentiPocketApp",
            configuration="Release",
            aps_environment="production",
            bundle_id="com.plexaura.sentipocket.app",
            marketing_version="0.1.0",
            build_number="4242",
            api_url="https://api.ci.invalid",
            gateway_url="https://gateway.ci.invalid",
            deployment_target="16.0",
            products_root=self.products_root,
        )
        self.settings = self.valid_settings()
        self.write_settings(self.settings)
        self.app_path = (
            Path(self.settings["TARGET_BUILD_DIR"]) / self.settings["WRAPPER_NAME"]
        )
        self.write_valid_bundle()

    def valid_settings(self, configuration: str = "Release") -> dict[str, str]:
        is_release = configuration == "Release"
        return {
            "CONFIGURATION": configuration,
            "PLATFORM_NAME": "iphoneos",
            "APS_ENVIRONMENT": "production" if is_release else "development",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "DEVELOPMENT_TEAM": "",
            "ONLY_ACTIVE_ARCH": "NO",
            "PRODUCT_BUNDLE_IDENTIFIER": self.expected.bundle_id,
            "MARKETING_VERSION": self.expected.marketing_version,
            "CURRENT_PROJECT_VERSION": self.expected.build_number,
            "SENTI_API_URL": self.expected.api_url,
            "SENTI_GATEWAY_URL": self.expected.gateway_url,
            "GENERATE_INFOPLIST_FILE": "NO",
            "IPHONEOS_DEPLOYMENT_TARGET": self.expected.deployment_target,
            "INFOPLIST_FILE": "Sources/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "Sources/SentiPocketApp.entitlements",
            "EXCLUDED_SOURCE_FILE_NAMES": "canonical_checkpoint.json"
            if is_release
            else "",
            "TARGET_BUILD_DIR": str(self.products_root / f"{configuration}-iphoneos"),
            "WRAPPER_NAME": "SentiPocketApp.app",
            "EXECUTABLE_NAME": "SentiPocketApp",
        }

    def write_settings(
        self, settings: dict[str, object], duplicate: bool = False
    ) -> None:
        records = [{"target": "SentiPocketApp", "buildSettings": settings}]
        if duplicate:
            records.append({"target": "SentiPocketApp", "buildSettings": settings})
        self.settings_path.write_text(json.dumps(records), encoding="utf-8")

    def write_valid_bundle(self, fmt: int = plistlib.FMT_BINARY) -> None:
        self.app_path.mkdir(parents=True, exist_ok=True)
        info = {
            "CFBundleIdentifier": self.expected.bundle_id,
            "CFBundleShortVersionString": self.expected.marketing_version,
            "CFBundleVersion": self.expected.build_number,
            "SENTI_API_URL": self.expected.api_url,
            "SENTI_GATEWAY_URL": self.expected.gateway_url,
            "MinimumOSVersion": self.expected.deployment_target,
            "CFBundlePackageType": "APPL",
            "CFBundleDisplayName": "Senti Pocket",
            "CFBundleExecutable": "SentiPocketApp",
            "UIBackgroundModes": ["audio", "voip"],
        }
        privacy = {
            "NSPrivacyTracking": False,
            "NSPrivacyTrackingDomains": [],
            "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [],
        }
        with (self.app_path / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, fmt=fmt)
        with self.source_privacy_path.open("wb") as stream:
            plistlib.dump(privacy, stream, fmt=plistlib.FMT_XML)
        with (self.app_path / "PrivacyInfo.xcprivacy").open("wb") as stream:
            plistlib.dump(privacy, stream, fmt=fmt)
        executable = self.app_path / "SentiPocketApp"
        executable.write_bytes(self.synthetic_macho())
        executable.chmod(0o755)

    @staticmethod
    def synthetic_macho() -> bytes:
        header_size = 32
        segment_size = 72
        file_size = header_size + segment_size
        header = struct.pack(
            "<8I",
            0xFEEDFACF,
            0x0100000C,
            0,
            2,
            1,
            segment_size,
            0,
            0,
        )
        segment = struct.pack(
            "<II16sQQQQiiII",
            0x19,
            segment_size,
            b"__TEXT".ljust(16, b"\0"),
            0,
            file_size,
            0,
            file_size,
            5,
            5,
            0,
            0,
        )
        return header + segment

    def read_info(self) -> dict[str, object]:
        with (self.app_path / "Info.plist").open("rb") as stream:
            return plistlib.load(stream)

    def write_info(self, info: dict[str, object]) -> None:
        with (self.app_path / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY)

    def assert_error_contains(self, errors: list[str], fragment: str) -> None:
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected {fragment!r} in {errors!r}",
        )

    def expected_with(self, **changes: object) -> object:
        return verify.Expectations(**{**self.expected.__dict__, **changes})

    def symlink_or_skip(
        self, target: Path, link: Path, *, target_is_directory: bool = False
    ) -> None:
        try:
            link.symlink_to(target, target_is_directory=target_is_directory)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symlinks unavailable on this host: {type(exc).__name__}")

    def test_settings_accept_exact_debug_and_release_policies(self) -> None:
        for configuration, aps in (("Debug", "development"), ("Release", "production")):
            with self.subTest(configuration=configuration):
                settings = self.valid_settings(configuration)
                self.write_settings(settings)
                expected = self.expected_with(
                    configuration=configuration,
                    aps_environment=aps,
                )
                resolved, errors = verify.verify_settings_file(
                    self.settings_path, expected
                )
                self.assertEqual([], errors)
                self.assertEqual(settings, resolved)

    def test_settings_reject_duplicate_or_missing_target_records(self) -> None:
        self.write_settings(self.settings, duplicate=True)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "found 2")

        self.settings_path.write_text(
            json.dumps([{"target": "Other", "buildSettings": self.settings}]),
            encoding="utf-8",
        )
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "found 0")

    def test_settings_reject_every_security_relevant_drift(self) -> None:
        mutations = {
            "APS_ENVIRONMENT": "development",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "DEVELOPMENT_TEAM": "WRONGTEAM1",
            "ONLY_ACTIVE_ARCH": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.wrong",
            "MARKETING_VERSION": "9.9.9",
            "CURRENT_PROJECT_VERSION": "7",
            "SENTI_API_URL": "https://wrong.ci.invalid",
            "SENTI_GATEWAY_URL": "https://wrong-gateway.ci.invalid",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "INFOPLIST_FILE": "Other/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "Other/Entitlements.plist",
            "EXCLUDED_SOURCE_FILE_NAMES": "",
            "TARGET_BUILD_DIR": "relative/build",
            "WRAPPER_NAME": "../Wrong.app",
            "EXECUTABLE_NAME": "../wrong",
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                changed = dict(self.settings)
                changed[key] = value
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"mutation for {key} unexpectedly passed")

    def test_settings_bind_exact_source_and_products_paths(self) -> None:
        mutations = (
            ("INFOPLIST_FILE", "EvilSources/Info.plist"),
            ("INFOPLIST_FILE", r"Sources\Info.plist"),
            (
                "CODE_SIGN_ENTITLEMENTS",
                "EvilSources/SentiPocketApp.entitlements",
            ),
            ("CODE_SIGN_ENTITLEMENTS", r"Sources\SentiPocketApp.entitlements"),
            (
                "TARGET_BUILD_DIR",
                str(self.root / "OtherProducts" / "Release-iphoneos"),
            ),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                changed = dict(self.settings)
                changed[key] = value
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"path mutation for {key} unexpectedly passed")

    def test_settings_reject_products_directory_symlink_escape(self) -> None:
        real_build_dir = self.root / "OutsideProducts" / "Release-iphoneos"
        real_build_dir.mkdir(parents=True)
        linked_build_dir = self.products_root / "Release-iphoneos"
        for child in self.app_path.iterdir():
            if child.is_file():
                child.unlink()
        self.app_path.rmdir()
        linked_build_dir.rmdir()
        self.symlink_or_skip(real_build_dir, linked_build_dir, target_is_directory=True)
        self.write_settings(self.settings)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(
            errors, "outside the independently expected products root"
        )

    def test_settings_reject_release_fixture_in_debug_exclusions(self) -> None:
        debug = self.valid_settings("Debug")
        debug["EXCLUDED_SOURCE_FILE_NAMES"] = "canonical_checkpoint.json"
        self.write_settings(debug)
        expected = self.expected_with(
            configuration="Debug",
            aps_environment="development",
        )
        _, errors = verify.verify_settings_file(self.settings_path, expected)
        self.assert_error_contains(errors, "unexpectedly excluded from Debug")

    def test_settings_reject_debug_wildcard_that_excludes_fixture(self) -> None:
        debug = self.valid_settings("Debug")
        debug["EXCLUDED_SOURCE_FILE_NAMES"] = "*.json"
        self.write_settings(debug)
        expected = self.expected_with(
            configuration="Debug",
            aps_environment="development",
        )
        _, errors = verify.verify_settings_file(self.settings_path, expected)
        self.assert_error_contains(errors, "unexpectedly excluded from Debug")

    def test_expectations_reject_unsafe_origins(self) -> None:
        invalid_origins = (
            "https://api.ci.invalid ",
            "https://api.ci.invalid\n",
            "https://tést.invalid",
            "https://api.ci.invalid:0",
            "https://api.ci.invalid:",
            "https://api.ci.invalid:/",
            "https://api.ci.invalid?",
            "https://api.ci.invalid#",
            "https://api.ci.invalid/?",
            "https://api.ci.invalid/#",
            "https://bad_host.invalid",
        )
        for origin in invalid_origins:
            with self.subTest(origin=origin):
                errors = verify.validate_expectations(
                    self.expected_with(api_url=origin)
                )
                self.assert_error_contains(errors, "api_url")

    def test_bundle_accepts_binary_plists_and_exact_resources(self) -> None:
        self.assertEqual(
            [],
            verify.verify_bundle(
                self.settings_path, self.source_privacy_path, self.expected
            ),
        )

    def test_bundle_rejects_info_plist_drift(self) -> None:
        mutations = {
            "CFBundleIdentifier": "com.example.wrong",
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "7",
            "SENTI_API_URL": "https://wrong.ci.invalid",
            "SENTI_GATEWAY_URL": "https://wrong-gateway.ci.invalid",
            "MinimumOSVersion": "17.0",
            "CFBundlePackageType": "BNDL",
            "UIBackgroundModes": ["audio"],
            "CFBundleExecutable": "OtherExecutable",
        }
        original = self.read_info()
        for key, value in mutations.items():
            with self.subTest(key=key):
                changed = dict(original)
                changed[key] = value
                self.write_info(changed)
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assertTrue(
                    errors, f"Info.plist mutation for {key} unexpectedly passed"
                )
        self.write_info(original)

    def test_bundle_rejects_missing_or_changed_privacy_manifest(self) -> None:
        bundled = self.app_path / "PrivacyInfo.xcprivacy"
        bundled.unlink()
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "bundled PrivacyInfo.xcprivacy")

        privacy = {"NSPrivacyTracking": True}
        with bundled.open("wb") as stream:
            plistlib.dump(privacy, stream)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "differs type-sensitively")

    def test_bundle_rejects_type_loose_privacy_manifest_substitutions(self) -> None:
        with self.source_privacy_path.open("rb") as stream:
            source = plistlib.load(stream)
        bundled = self.app_path / "PrivacyInfo.xcprivacy"
        substitutions = (
            {**source, "NSPrivacyTracking": 0},
            {**source, "NSPrivacyTrackingDomains": [0.0]},
        )
        for changed in substitutions:
            with self.subTest(changed=changed):
                with bundled.open("wb") as stream:
                    plistlib.dump(changed, stream)
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, "differs type-sensitively")

    def test_bundle_rejects_release_fixture_models_and_private_artifacts(self) -> None:
        forbidden = (
            "canonical_checkpoint.json",
            "ggml-base.en.bin",
            "embedded.mobileprovision",
            "_CodeSignature",
            "AuthKey_TEST.p8",
            "signing.p12",
            "profile.mobileprovision",
            "profile.provisionprofile",
            "secret.pem",
            "private.key",
            "agent.credentials.json",
            "Credentials.JSON",
            ".env",
            "model.gguf",
            "ggml-small.en.bin",
            "private-whisper.bin",
            "signing.pfx",
        )
        for name in forbidden:
            with self.subTest(name=name):
                candidate = self.app_path / name
                if name == "_CodeSignature":
                    candidate.mkdir()
                else:
                    candidate.write_bytes(b"forbidden")
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, name)
                if candidate.is_dir():
                    candidate.rmdir()
                else:
                    candidate.unlink()

    def test_bundle_rejects_nested_directory_and_executable_symlinks(self) -> None:
        outside = self.root / "Outside"
        outside.mkdir()
        (outside / "AuthKey_HIDDEN.p8").write_bytes(b"private")
        nested_link = self.app_path / "ExternalAssets"
        self.symlink_or_skip(outside, nested_link, target_is_directory=True)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "contains a symlink")
        nested_link.unlink()

        executable = self.app_path / "SentiPocketApp"
        executable.unlink()
        outside_executable = outside / "SentiPocketApp"
        outside_executable.write_bytes(self.synthetic_macho())
        outside_executable.chmod(0o755)
        self.symlink_or_skip(outside_executable, executable)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "executable must not be a symlink")

    def test_bundle_rejects_invalid_executable_evidence(self) -> None:
        executable = self.app_path / "SentiPocketApp"
        wrong_type = bytearray(self.synthetic_macho())
        struct.pack_into("<I", wrong_type, 12, 1)
        invalid_payloads = (
            (b"", "truncated Mach-O header"),
            (b"\xcf\xfa\xed\xfe", "truncated Mach-O header"),
            (b"not a Mach-O executable".ljust(32, b"!"), "not a thin"),
            (bytes(wrong_type), "not MH_EXECUTE"),
            (self.synthetic_macho()[:-1], "exceeds the executable"),
        )
        for payload, fragment in invalid_payloads:
            with self.subTest(fragment=fragment):
                executable.write_bytes(payload)
                executable.chmod(0o755)
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, fragment)

    @unittest.skipUnless(os.name == "posix", "POSIX executable mode bits required")
    def test_bundle_rejects_non_executable_mode(self) -> None:
        executable = self.app_path / "SentiPocketApp"
        executable.chmod(0o644)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "executable mode bit")

    def test_bundle_traversal_fails_closed_and_is_bounded(self) -> None:
        with mock.patch.object(
            verify.os, "scandir", side_effect=PermissionError("denied")
        ):
            errors = verify.verify_bundle(
                self.settings_path, self.source_privacy_path, self.expected
            )
        self.assert_error_contains(errors, "traversal failed")

        with mock.patch.object(verify, "MAX_BUNDLE_ENTRIES", 1):
            errors = verify.verify_bundle(
                self.settings_path, self.source_privacy_path, self.expected
            )
        self.assert_error_contains(errors, "entry verification limit")

    def test_bundle_rejects_missing_executable(self) -> None:
        (self.app_path / "SentiPocketApp").unlink()
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "executable could not be inspected")

    def test_cli_reports_success_without_absolute_paths(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        args = [
            "bundle",
            "--settings-json",
            str(self.settings_path),
            "--source-privacy",
            str(self.source_privacy_path),
            "--configuration",
            "Release",
            "--aps-environment",
            "production",
            "--bundle-id",
            self.expected.bundle_id,
            "--marketing-version",
            self.expected.marketing_version,
            "--build-number",
            self.expected.build_number,
            "--api-url",
            self.expected.api_url,
            "--gateway-url",
            self.expected.gateway_url,
            "--products-root",
            str(self.products_root),
        ]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = verify.main(args)
        self.assertEqual(0, status)
        self.assertEqual("", stderr.getvalue())
        self.assertEqual(
            "verify_unsigned_release: bundle passed for Release/production\n",
            stdout.getvalue(),
        )
        self.assertNotIn(str(self.root), stdout.getvalue())

    def test_cli_redacts_secret_bearing_endpoint_drift(self) -> None:
        changed = dict(self.settings)
        changed["SENTI_API_URL"] = "https://user:TOPSECRET@evil.invalid"
        self.write_settings(changed)
        stdout = io.StringIO()
        stderr = io.StringIO()
        args = [
            "settings",
            "--settings-json",
            str(self.settings_path),
            "--configuration",
            "Release",
            "--aps-environment",
            "production",
            "--bundle-id",
            self.expected.bundle_id,
            "--marketing-version",
            self.expected.marketing_version,
            "--build-number",
            self.expected.build_number,
            "--api-url",
            self.expected.api_url,
            "--gateway-url",
            self.expected.gateway_url,
            "--products-root",
            str(self.products_root),
        ]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = verify.main(args)
        self.assertEqual(1, status)
        self.assertEqual("", stdout.getvalue())
        self.assertIn("SENTI_API_URL", stderr.getvalue())
        self.assertNotIn("TOPSECRET", stderr.getvalue())
        self.assertNotIn("user:", stderr.getvalue())

    def test_malformed_inputs_fail_closed(self) -> None:
        self.settings_path.write_text("not json", encoding="utf-8")
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "could not be decoded")

        self.write_settings(self.settings)
        (self.app_path / "Info.plist").write_bytes(b"not a plist")
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "built Info.plist could not be decoded")


if __name__ == "__main__":
    unittest.main()
