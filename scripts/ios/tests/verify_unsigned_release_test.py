#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import functools
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path, PurePosixPath
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_unsigned_release.py"
REPOSITORY_ROOT = MODULE_PATH.parents[2]
SPEC = importlib.util.spec_from_file_location("verify_unsigned_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
verify = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verify
SPEC.loader.exec_module(verify)
PINNED_APP_ICON_SHA256 = verify.APP_ICON_SHA256
PINNED_PROJECT_SPEC_SHA256 = verify.PROJECT_SPEC_SHA256


class UnsignedReleaseVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings_path = self.root / "settings.json"
        self.project_file = self.root / "SentiPocketApp.xcodeproj" / "project.pbxproj"
        self.scheme_path = (
            self.project_file.parent
            / "xcshareddata"
            / "xcschemes"
            / "SentiPocketAppRelease.xcscheme"
        )
        self.source_privacy_path = self.root / "PrivacyInfo.xcprivacy"
        self.products_root = self.root / "Build" / "Products"
        self.developer_dir = PurePosixPath(
            "/Applications/Xcode.app/Contents/Developer"
        )
        self.sdk_root = self.developer_dir / (
            "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"
        )
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
            project_file=self.project_file,
            developer_dir=self.developer_dir,
            sdk_root=self.sdk_root,
        )
        self.write_valid_project()
        self.real_project_converter = verify._structured_project_from_plutil
        self.project_converter = mock.patch.object(
            verify,
            "_structured_project_from_plutil",
            side_effect=self.convert_project_fixture,
        )
        self.project_converter.start()
        self.addCleanup(self.project_converter.stop)
        self.real_package_manifest_errors = verify._approved_package_manifest_errors
        self.package_manifests = mock.patch.object(
            verify,
            "_approved_package_manifest_errors",
            return_value=[],
        )
        self.package_manifests.start()
        self.addCleanup(self.package_manifests.stop)
        self.real_project_spec_errors = verify._approved_project_spec_errors
        self.project_spec = mock.patch.object(
            verify,
            "_approved_project_spec_errors",
            return_value=[],
        )
        self.project_spec.start()
        self.addCleanup(self.project_spec.stop)
        self.icon_digest = mock.patch.object(
            verify,
            "APP_ICON_SHA256",
            hashlib.sha256(self.synthetic_png()).hexdigest(),
        )
        self.icon_digest.start()
        self.addCleanup(self.icon_digest.stop)
        self.write_valid_app_icon_source()
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
            "INFOPLIST_PREPROCESS": "NO",
            "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "",
            "INFOPLIST_PREFIX_HEADER": "",
            "INFOPLIST_PREPROCESSOR_DEFINITIONS": "",
            "IPHONEOS_DEPLOYMENT_TARGET": self.expected.deployment_target,
            "INFOPLIST_FILE": "Sources/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "Sources/SentiPocketApp.entitlements",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES": "",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "NO",
            "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": "NO",
            "ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR": "default",
            "ASSETCATALOG_OTHER_FLAGS": "",
            "ASSETCATALOG_EXEC": str(self.developer_dir / "usr/bin/actool"),
            "TARGETED_DEVICE_FAMILY": "1",
            "INCLUDED_SOURCE_FILE_NAMES": "",
            "PROJECT_FILE_PATH": str(self.project_file.parent.resolve(strict=False)),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "" if is_release else "DEBUG",
            "OTHER_SWIFT_FLAGS": "",
            "OTHER_CFLAGS": "",
            "OTHER_CPLUSPLUSFLAGS": "",
            "OTHER_LDFLAGS": "",
            "OTHER_LIBTOOLFLAGS": "",
            "ALL_OTHER_LDFLAGS": "",
            "ALTERNATE_LINKER": "",
            "ALTERNATE_LINKER_PATH": "",
            "CLANG_ALTERNATE_LINKER": "",
            "CLANG_ALTERNATE_LINKER_PATH": "",
            "LD_FLAGS": "",
            "PRODUCT_SPECIFIC_LDFLAGS": "",
            "SECTORDER_FLAGS": "",
            "SWIFTC_ALTERNATE_LINKER": "",
            "SWIFTC_ALTERNATE_LINKER_PATH": "",
            "WARNING_CFLAGS": "",
            "SWIFT_TOOLS_DIR": str(
                self.developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
            ),
            "SWIFT_TOOLCHAIN_FLAGS": "",
            "SWIFT_RESPONSE_FILE_PATH": "",
            "SWIFT_USE_INTEGRATED_DRIVER": "YES",
            "COMPILATION_CACHE_ENABLE_PLUGIN": "NO",
            "COMPILATION_CACHE_PLUGIN_PATH": "",
            "SWIFT_ENABLE_COMPILE_CACHE": "NO",
            "CODESIGN": "/usr/bin/codesign",
            "CODESIGN_ALLOCATE": str(
                self.developer_dir
                / "Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate"
            ),
            "LD_OBJC_RUNTIME_ARGS": "-fobjc-link-runtime",
            "LD_OBJC_RUNTIME_ARGS_clang": "-fobjc-link-runtime",
            "LD_OBJC_RUNTIME_ARGS_swiftc": "-link-objc-runtime",
            "DEVELOPER_DIR": str(self.developer_dir),
            "DT_TOOLCHAIN_DIR": str(
                self.developer_dir / "Toolchains/XcodeDefault.xctoolchain"
            ),
            "TOOLCHAIN_DIR": str(
                self.developer_dir / "Toolchains/XcodeDefault.xctoolchain"
            ),
            "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
            "SDKROOT": str(self.sdk_root),
            "PATH": ":".join(
                (
                    str(
                        self.developer_dir
                        / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
                    ),
                    str(self.developer_dir / "usr/bin"),
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                )
            ),
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

    def write_valid_project(self) -> None:
        self.project_id = "111111111111111111111111"
        self.main_group_id = "222222222222222222222222"
        self.resources_group_id = "333333333333333333333333"
        self.asset_ref_id = "444444444444444444444444"
        self.asset_build_file_id = "555555555555555555555555"
        self.resources_phase_id = "666666666666666666666666"
        self.target_id = "777777777777777777777777"
        self.frameworks_phase_id = "D00000000000000000000000"
        self.release_configuration_id = "F00000000000000000000000"
        package_products = sorted(verify.APPROVED_PACKAGE_PRODUCTS)
        self.package_reference_ids = {
            product: f"A{index:023X}"
            for index, product in enumerate(package_products, start=1)
        }
        self.package_product_ids = {
            product: f"B{index:023X}"
            for index, product in enumerate(package_products, start=1)
        }
        self.package_build_file_ids = {
            product: f"C{index:023X}"
            for index, product in enumerate(package_products, start=1)
        }
        self.project_graph: dict[str, object] = {
            "archiveVersion": "1",
            "objectVersion": "77",
            "objects": {
                self.project_id: {
                    "isa": "PBXProject",
                    "mainGroup": self.main_group_id,
                    "projectDirPath": "",
                    "projectRoot": "",
                    "packageReferences": list(self.package_reference_ids.values()),
                    "targets": [self.target_id],
                },
                self.main_group_id: {
                    "isa": "PBXGroup",
                    "children": [self.resources_group_id],
                    "sourceTree": "<group>",
                },
                self.resources_group_id: {
                    "isa": "PBXGroup",
                    "children": [self.asset_ref_id],
                    "path": "Resources",
                    "sourceTree": "<group>",
                },
                self.asset_ref_id: {
                    "isa": "PBXFileReference",
                    "lastKnownFileType": "folder.assetcatalog",
                    "path": "Assets.xcassets",
                    "sourceTree": "<group>",
                },
                self.asset_build_file_id: {
                    "isa": "PBXBuildFile",
                    "fileRef": self.asset_ref_id,
                },
                self.resources_phase_id: {
                    "isa": "PBXResourcesBuildPhase",
                    "files": [self.asset_build_file_id],
                    "buildActionMask": "2147483647",
                    "runOnlyForDeploymentPostprocessing": "0",
                },
                self.frameworks_phase_id: {
                    "isa": "PBXFrameworksBuildPhase",
                    "files": list(self.package_build_file_ids.values()),
                    "buildActionMask": "2147483647",
                    "runOnlyForDeploymentPostprocessing": "0",
                },
                self.target_id: {
                    "isa": "PBXNativeTarget",
                    "buildPhases": [self.frameworks_phase_id, self.resources_phase_id],
                    "name": "SentiPocketApp",
                    "packageProductDependencies": list(
                        self.package_product_ids.values()
                    ),
                    "productType": "com.apple.product-type.application",
                },
                self.release_configuration_id: {
                    "isa": "XCBuildConfiguration",
                    "buildSettings": {"SDKROOT": "iphoneos"},
                    "name": "Release",
                },
            },
            "rootObject": self.project_id,
        }
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        for product in package_products:
            objects[self.package_reference_ids[product]] = {
                "isa": "XCLocalSwiftPackageReference",
                "relativePath": f"../../packages/{product}",
            }
            objects[self.package_product_ids[product]] = {
                "isa": "XCSwiftPackageProductDependency",
                "productName": product,
            }
            objects[self.package_build_file_ids[product]] = {
                "isa": "PBXBuildFile",
                "productRef": self.package_product_ids[product],
            }
        self.project_file.parent.mkdir(parents=True, exist_ok=True)
        self.project_file.write_text(
            "// !$*UTF8*$!\n"
            "{\n"
            "\tarchiveVersion = 1;\n"
            "\tobjectVersion = 77;\n"
            "\tobjects = {\n"
            "\t\t111111111111111111111111 /* Project object */ = {isa = PBXProject; "
            "mainGroup = 222222222222222222222222; targets = "
            "(777777777777777777777777,); projectDirPath = \"\"; "
            "projectRoot = \"\"; };\n"
            "\t\t222222222222222222222222 /* Main Group */ = {isa = PBXGroup; "
            "children = (333333333333333333333333,); sourceTree = \"<group>\"; };\n"
            "\t\t333333333333333333333333 /* Resources */ = {isa = PBXGroup; "
            "children = (444444444444444444444444,); path = Resources; "
            "sourceTree = \"<group>\"; };\n"
            "\t\t444444444444444444444444 /* Assets.xcassets */ = "
            "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
            "path = Assets.xcassets; sourceTree = \"<group>\"; };\n"
            "\t\t555555555555555555555555 /* Assets.xcassets in Resources */ = "
            "{isa = PBXBuildFile; fileRef = 444444444444444444444444 "
            "/* Assets.xcassets */; };\n"
            "\t\t666666666666666666666666 /* Resources */ = "
            "{isa = PBXResourcesBuildPhase; files = "
            "(555555555555555555555555,); "
            "runOnlyForDeploymentPostprocessing = 0; };\n"
            "\t\t777777777777777777777777 /* SentiPocketApp */ = "
            "{isa = PBXNativeTarget; buildPhases = "
            "(666666666666666666666666,); name = SentiPocketApp; "
            "productType = \"com.apple.product-type.application\"; };\n"
            "\t};\n"
            "\trootObject = 111111111111111111111111;\n"
            "}\n",
            encoding="utf-8",
        )
        self.scheme_path.parent.mkdir(parents=True, exist_ok=True)
        self.scheme_path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Scheme LastUpgradeVersion="2600" version="1.7">\n'
            '  <BuildAction parallelizeBuildables="YES" '
            'buildImplicitDependencies="NO">\n'
            '    <BuildActionEntries>\n'
            '      <BuildActionEntry buildForTesting="YES" '
            'buildForRunning="YES" buildForProfiling="YES" '
            'buildForArchiving="YES" buildForAnalyzing="YES">\n'
            '        <BuildableReference BuildableIdentifier="primary" '
            f'BlueprintIdentifier="{self.target_id}" '
            'BuildableName="SentiPocketApp.app" '
            'BlueprintName="SentiPocketApp" '
            'ReferencedContainer="container:SentiPocketApp.xcodeproj"/>\n'
            '      </BuildActionEntry>\n'
            '    </BuildActionEntries>\n'
            '  </BuildAction>\n'
            '  <TestAction/>\n'
            '  <LaunchAction/>\n'
            '  <ProfileAction/>\n'
            '  <AnalyzeAction/>\n'
            '  <ArchiveAction buildConfiguration="Release"/>\n'
            '</Scheme>\n',
            encoding="utf-8",
        )

    def convert_project_fixture(
        self, path: Path, expected_bytes: bytes
    ) -> tuple[dict[str, object], list[str]]:
        self.assertEqual(path.read_bytes(), expected_bytes)
        return self.project_graph, []

    @staticmethod
    def png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(payload))
            + chunk_type
            + payload
            + struct.pack(">I", checksum)
        )

    @staticmethod
    @functools.lru_cache(maxsize=32)
    def synthetic_png(
        *,
        width: int = 1024,
        height: int = 1024,
        color_type: int = 2,
        alpha_byte: int = 255,
        transparent: bool = False,
        filter_byte: int = 0,
        row_count: int | None = None,
        compressed_payload: bytes | None = None,
        truncate_compressed: bool = False,
        trailing_compressed: bytes = b"",
        split_idat: bool = False,
        cgbi: bool = False,
        extra_chunks: tuple[tuple[bytes, bytes], ...] = (),
    ) -> bytes:
        header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
        chunks = []
        if cgbi:
            chunks.append(UnsignedReleaseVerifierTests.png_chunk(b"CgBI", b""))
        chunks.append(UnsignedReleaseVerifierTests.png_chunk(b"IHDR", header))
        if transparent:
            chunks.append(
                UnsignedReleaseVerifierTests.png_chunk(b"tRNS", b"\0\0\0\0\0\0")
            )
        chunks.extend(
            UnsignedReleaseVerifierTests.png_chunk(chunk_type, payload)
            for chunk_type, payload in extra_chunks
        )
        if compressed_payload is None:
            rows = height if row_count is None else row_count
            if color_type == 6:
                pixels = bytes((0, 0, 0, alpha_byte)) * width
            else:
                pixels = bytes(width * 3)
            scanline = bytes((filter_byte,)) + pixels
            if cgbi:
                compressor = zlib.compressobj(wbits=-zlib.MAX_WBITS)
                compressed_payload = (
                    compressor.compress(scanline * rows) + compressor.flush()
                )
            else:
                compressed_payload = zlib.compress(scanline * rows)
        if truncate_compressed:
            compressed_payload = compressed_payload[:-2]
        compressed_payload += trailing_compressed
        idat_payloads = (compressed_payload,)
        if split_idat:
            split_at = max(1, len(compressed_payload) // 2)
            idat_payloads = (
                compressed_payload[:split_at],
                compressed_payload[split_at:],
            )
        chunks.extend(
            UnsignedReleaseVerifierTests.png_chunk(b"IDAT", payload)
            for payload in idat_payloads
        )
        chunks.append(UnsignedReleaseVerifierTests.png_chunk(b"IEND", b""))
        return b"\x89PNG\r\n\x1a\n" + b"".join(chunks)

    def write_valid_app_icon_source(self) -> None:
        catalog = self.root / "Resources" / "Assets.xcassets"
        icon_set = catalog / "AppIcon.appiconset"
        icon_set.mkdir(parents=True, exist_ok=True)
        (catalog / "Contents.json").write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}),
            encoding="utf-8",
        )
        (icon_set / "Contents.json").write_text(
            json.dumps(
                {
                    "images": [
                        {
                            "filename": "SentiPocketAppIcon.png",
                            "idiom": "universal",
                            "platform": "ios",
                            "size": "1024x1024",
                        }
                    ],
                    "info": {"author": "xcode", "version": 1},
                }
            ),
            encoding="utf-8",
        )
        (icon_set / "SentiPocketAppIcon.png").write_bytes(self.synthetic_png())

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
            "UIDeviceFamily": [1],
            "CFBundleIcons": {
                "CFBundlePrimaryIcon": {
                    "CFBundleIconName": "AppIcon",
                    "CFBundleIconFiles": ["AppIcon60x60"],
                }
            },
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
        (self.app_path / "Assets.car").write_bytes(
            b"BOMStore synthetic compiled assets"
        )
        (self.app_path / "AppIcon60x60@2x.png").write_bytes(
            self.synthetic_png(width=120, height=120)
        )

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

    def test_settings_reject_duplicate_json_object_keys(self) -> None:
        encoded = json.dumps(
            [{"target": "SentiPocketApp", "buildSettings": self.settings}]
        )
        encoded = encoded.replace(
            '"CONFIGURATION": "Release"',
            '"CONFIGURATION": "Debug", "CONFIGURATION": "Release"',
            1,
        )
        self.settings_path.write_text(encoded, encoding="utf-8")

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assert_error_contains(errors, "duplicate object keys")

    def test_security_file_reader_is_descriptor_anchored_and_fails_on_drift(
        self,
    ) -> None:
        with mock.patch.object(Path, "open", side_effect=AssertionError("unsafe open")):
            payload, errors = verify._read_json(self.settings_path)
        self.assertEqual([], errors)
        self.assertIsInstance(payload, list)

        with mock.patch.object(verify, "_opened_file_changed", return_value=True):
            payload, errors = verify._read_json(self.settings_path)
        self.assertIsNone(payload)
        self.assert_error_contains(errors, "changed during verification")

        replacement = self.root / "replacement.json"
        replacement.write_text("[]", encoding="utf-8")
        real_open = verify.os.open

        def swap_before_open(path: object, flags: int) -> int:
            replacement.replace(Path(path))
            return real_open(path, flags)

        with mock.patch.object(verify.os, "open", side_effect=swap_before_open):
            payload, errors = verify._read_json(self.settings_path)
        self.assertIsNone(payload)
        self.assert_error_contains(errors, "changed before opening")

        captured_descriptor = -1
        real_lstat = Path.lstat
        lstat_calls = 0

        def fail_second_lstat(path: Path) -> os.stat_result:
            nonlocal lstat_calls
            lstat_calls += 1
            if lstat_calls == 2:
                raise PermissionError("deny stable-path confirmation")
            return real_lstat(path)

        def capture_open(path: object, flags: int) -> int:
            nonlocal captured_descriptor
            captured_descriptor = real_open(path, flags)
            return captured_descriptor

        with (
            mock.patch.object(
                Path, "lstat", autospec=True, side_effect=fail_second_lstat
            ),
            mock.patch.object(verify.os, "open", side_effect=capture_open),
        ):
            _, errors = verify._read_json(self.settings_path)
        self.assert_error_contains(errors, "could not be opened")
        with self.assertRaises(OSError):
            verify.os.fstat(captured_descriptor)

        evidence = self.root / "same-inode.bin"
        evidence.write_bytes(b"approved")
        evidence_stat = evidence.stat()

        def rewrite_before_open(path: object, flags: int) -> int:
            with evidence.open("r+b") as stream:
                stream.write(b"attacker")
                stream.flush()
                os.fsync(stream.fileno())
            os.utime(
                evidence,
                ns=(evidence_stat.st_atime_ns, evidence_stat.st_mtime_ns + 1_000_000_000),
            )
            return real_open(path, flags)

        with mock.patch.object(verify.os, "open", side_effect=rewrite_before_open):
            payload, errors = verify._read_bounded_regular_file(
                evidence, "same-inode evidence", maximum_bytes=8
            )
        self.assertIsNone(payload)
        self.assert_error_contains(errors, "changed before opening")

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
            "ASSETCATALOG_COMPILER_APPICON_NAME": "OtherIcon",
            "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES": "OtherIcon",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
            "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": "YES",
            "ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR": "none",
            "ASSETCATALOG_OTHER_FLAGS": "--unverified-option",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "PROJECT_FILE_PATH": str(self.root / "Decoy.xcodeproj"),
            "EXCLUDED_SOURCE_FILE_NAMES": "canonical_checkpoint.json Assets.xcassets",
            "INCLUDED_SOURCE_FILE_NAMES": "Other.swift",
            "TARGET_BUILD_DIR": "relative/build",
            "WRAPPER_NAME": "../Wrong.app",
            "EXECUTABLE_NAME": "../wrong",
            "SWIFT_EXEC": "/tmp/evil-swiftc",
            "SWIFT_EXEC_NORMAL_ARM64_EXEC": "/tmp/evil-swiftc",
            "SWIFT_DRIVER_SWIFT_EXEC": "/tmp/evil-swiftc",
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": "/tmp/evil-frontend",
            "CC": "/tmp/evil-clang",
            "CXX": "/tmp/evil-clang++",
            "LD": "/tmp/evil-ld",
            "LDPLUSPLUS": "/tmp/evil-clang++",
            "LIBTOOL": "/tmp/evil-libtool",
            "C_COMPILER_LAUNCHER": "/tmp/evil-launcher",
            "CXX_COMPILER_LAUNCHER": "/tmp/evil-launcher",
            "SWIFT_COMPILER_LAUNCHER": "/tmp/evil-launcher",
            "TOOLCHAINS": "com.example.evil",
            "SDKROOT": "/tmp/Evil.sdk",
            "DEVELOPER_DIR": "/tmp/Evil.app/Contents/Developer",
            "DT_TOOLCHAIN_DIR": "/tmp/Evil.xctoolchain",
            "TOOLCHAIN_DIR": "/tmp/Evil.xctoolchain",
            "PATH": "/tmp/attacker-bin:/usr/bin:/bin",
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

    def test_settings_accept_trusted_resolved_tool_selectors(self) -> None:
        changed = dict(self.settings)
        changed.update(
            {
                "CC": "/Applications/Xcode.app/Contents/Developer/Toolchains/"
                "XcodeDefault.xctoolchain/usr/bin/clang",
                "CXX": "clang++",
                "CPLUSPLUS": "clang++",
                "OBJCC": "clang",
                "OBJCPLUSPLUS": "clang++",
                "LD": "ld",
                "LDPLUSPLUS": "clang++",
                "LIBTOOL": "libtool",
                "SWIFT_EXEC": "swiftc",
                "SWIFT_DRIVER_SWIFT_EXEC": "swift",
                "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": "swift-frontend",
                "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
                "SDKROOT": "/Applications/Xcode.app/Contents/Developer/Platforms/"
                "iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk",
            }
        )
        self.write_settings(changed)

        resolved, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assertEqual([], errors)
        self.assertEqual(changed, resolved)

    def test_settings_reject_compiler_plugin_and_linker_flag_surfaces(self) -> None:
        mutations = (
            (
                "OTHER_SWIFT_FLAGS",
                "-Xfrontend -load-plugin-executable -Xfrontend /tmp/evil#Evil",
            ),
            ("OTHER_SWIFT_FLAGS", "-driver-use-frontend-path /tmp/evil"),
            ("OTHER_SWIFT_FLAGS", "-load-plugin-library /tmp/evil.dylib"),
            ("OTHER_CFLAGS", "-Xclang -load -Xclang /tmp/evil.dylib"),
            ("OTHER_CPLUSPLUSFLAGS", "-Xclang -load -Xclang /tmp/evil.dylib"),
            ("OTHER_LDFLAGS", "-Wl,-load,/tmp/evil.dylib"),
            ("OTHER_LIBTOOLFLAGS", "-Wl,-load,/tmp/evil.dylib"),
            ("ALL_OTHER_LDFLAGS", "-ld-path=/tmp/evil-linker"),
            ("ALTERNATE_LINKER", "/tmp/evil-linker"),
            ("ALTERNATE_LINKER_PATH", "/tmp/evil-linker"),
            ("CLANG_ALTERNATE_LINKER", "/tmp/evil-linker"),
            ("CLANG_ALTERNATE_LINKER_PATH", "/tmp/evil-linker"),
            ("LD_FLAGS", "-ld-path=/tmp/evil-linker"),
            ("PRODUCT_SPECIFIC_LDFLAGS", "-ld-path=/tmp/evil-linker"),
            ("SECTORDER_FLAGS", "-ld-path=/tmp/evil-linker"),
            ("SWIFTC_ALTERNATE_LINKER", "/tmp/evil-linker"),
            ("SWIFTC_ALTERNATE_LINKER_PATH", "/tmp/evil-linker"),
            ("LD_OBJC_RUNTIME_ARGS", "-ld-path=/tmp/evil-linker"),
            ("LD_OBJC_RUNTIME_ARGS_clang", "-ld-path=/tmp/evil-linker"),
            ("LD_OBJC_RUNTIME_ARGS_swiftc", "-ld-path=/tmp/evil-linker"),
            ("WARNING_CFLAGS", "-Xclang -load -Xclang /tmp/evil.dylib"),
            ("INFOPLIST_PREPROCESS", "YES"),
            (
                "INFOPLIST_OTHER_PREPROCESSOR_FLAGS",
                "-Xclang -load -Xclang /tmp/evil.dylib",
            ),
            ("INFOPLIST_PREFIX_HEADER", "/tmp/evil-prefix.h"),
            ("INFOPLIST_PREPROCESSOR_DEFINITIONS", "EVIL=1"),
            ("SWIFT_TOOLS_DIR", "/tmp/evil-tools"),
            ("ASSETCATALOG_EXEC", "/tmp/evil-actool"),
            ("SWIFT_TOOLCHAIN_FLAGS", "-driver-use-frontend-path /tmp/evil"),
            ("SWIFT_RESPONSE_FILE_PATH", "/tmp/evil.rsp"),
            ("SWIFT_RESPONSE_FILE_PATH_normal_arm64", "/tmp/evil.rsp"),
            ("SWIFT_USE_INTEGRATED_DRIVER", "NO"),
            ("COMPILATION_CACHE_ENABLE_PLUGIN", "YES"),
            ("COMPILATION_CACHE_PLUGIN_PATH", "/tmp/evil-cas.dylib"),
            ("SWIFT_ENABLE_COMPILE_CACHE", "YES"),
            ("CODESIGN", "/tmp/evil-codesign"),
            ("CODESIGN_ALLOCATE", "/tmp/evil-codesign-allocate"),
        )
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                changed = dict(self.settings)
                changed[key] = value
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assert_error_contains(errors, key)

    def test_settings_bind_named_tools_to_selected_xcode_path(self) -> None:
        changed = dict(self.settings)
        changed["CC"] = "clang"
        changed["PATH"] = "/tmp/attacker-bin:/usr/bin:/bin"
        self.write_settings(changed)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "PATH")

        changed = dict(self.settings)
        changed.pop("TOOLCHAINS")
        self.write_settings(changed)
        resolved, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assertEqual([], errors)
        self.assertEqual(changed, resolved)

        changed = dict(self.settings)
        changed["CC"] = (
            "/tmp/Evil.app/Contents/Developer/Toolchains/"
            "XcodeDefault.xctoolchain/usr/bin/clang"
        )
        self.write_settings(changed)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "CC")

        changed = dict(self.settings)
        changed["SDKROOT"] = (
            "/tmp/Evil.app/Contents/Developer/Platforms/iPhoneOS.platform/"
            "Developer/SDKs/iPhoneOS26.5.sdk"
        )
        self.write_settings(changed)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "SDKROOT")

    def test_settings_require_app_icon_settings(self) -> None:
        for key in (
            "ASSETCATALOG_COMPILER_APPICON_NAME",
            "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS",
            "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT",
            "ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR",
            "ASSETCATALOG_OTHER_FLAGS",
            "TARGETED_DEVICE_FAMILY",
            "INCLUDED_SOURCE_FILE_NAMES",
        ):
            with self.subTest(key=key):
                changed = dict(self.settings)
                del changed[key]
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assert_error_contains(errors, key)

    def test_settings_reject_invalid_source_app_icon_evidence(self) -> None:
        catalog = self.root / "Resources" / "Assets.xcassets"
        icon_set = catalog / "AppIcon.appiconset"
        icon_path = icon_set / "SentiPocketAppIcon.png"

        mutations = (
            (
                "catalog metadata",
                lambda: (catalog / "Contents.json").write_text(
                    json.dumps({"info": {"author": "other", "version": 1}}),
                    encoding="utf-8",
                ),
            ),
            (
                "icon set metadata",
                lambda: (icon_set / "Contents.json").write_text(
                    json.dumps(
                        {
                            "images": [
                                {
                                    "filename": "Other.png",
                                    "idiom": "universal",
                                    "platform": "ios",
                                    "size": "1024x1024",
                                }
                            ],
                            "info": {"author": "xcode", "version": 1},
                        }
                    ),
                    encoding="utf-8",
                ),
            ),
            ("missing PNG", icon_path.unlink),
            (
                "wrong dimensions",
                lambda: icon_path.write_bytes(self.synthetic_png(width=512)),
            ),
            (
                "alpha PNG",
                lambda: icon_path.write_bytes(self.synthetic_png(color_type=6)),
            ),
            (
                "transparent PNG",
                lambda: icon_path.write_bytes(self.synthetic_png(transparent=True)),
            ),
            (
                "non-zlib image data",
                lambda: icon_path.write_bytes(
                    self.synthetic_png(compressed_payload=b"not-zlib")
                ),
            ),
            (
                "truncated zlib stream",
                lambda: icon_path.write_bytes(
                    self.synthetic_png(truncate_compressed=True)
                ),
            ),
            (
                "short image data",
                lambda: icon_path.write_bytes(self.synthetic_png(row_count=1023)),
            ),
            (
                "extra image data",
                lambda: icon_path.write_bytes(self.synthetic_png(row_count=1025)),
            ),
            (
                "invalid row filter",
                lambda: icon_path.write_bytes(self.synthetic_png(filter_byte=5)),
            ),
            (
                "unapproved but structurally valid artwork bytes",
                lambda: icon_path.write_bytes(self.synthetic_png(filter_byte=1)),
            ),
            (
                "trailing compressed data",
                lambda: icon_path.write_bytes(
                    self.synthetic_png(trailing_compressed=b"trailing")
                ),
            ),
            (
                "unknown critical chunk",
                lambda: icon_path.write_bytes(
                    self.synthetic_png(extra_chunks=((b"ABCD", b"opaque"),))
                ),
            ),
            (
                "unapproved ancillary chunk",
                lambda: icon_path.write_bytes(
                    self.synthetic_png(extra_chunks=((b"vpAg", b"opaque"),))
                ),
            ),
            (
                "corrupt PNG checksum",
                lambda: icon_path.write_bytes(self.synthetic_png()[:-1] + b"!"),
            ),
            (
                "extra AppIcon entry",
                lambda: (icon_set / "Unexpected.txt").write_text(
                    "unexpected", encoding="utf-8"
                ),
            ),
        )
        for label, mutate in mutations:
            with self.subTest(label=label):
                self.write_valid_app_icon_source()
                mutate()
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"{label} unexpectedly passed")

    def test_settings_accept_multi_idat_source_app_icon(self) -> None:
        icon_path = (
            self.root
            / "Resources"
            / "Assets.xcassets"
            / "AppIcon.appiconset"
            / "SentiPocketAppIcon.png"
        )
        split_png = self.synthetic_png(split_idat=True)
        icon_path.write_bytes(split_png)

        with mock.patch.object(
            verify, "APP_ICON_SHA256", hashlib.sha256(split_png).hexdigest()
        ):
            _, errors = verify.verify_settings_file(
                self.settings_path, self.expected
            )

        self.assertEqual([], errors)

    def test_settings_reject_duplicate_source_catalog_json_keys(self) -> None:
        catalog_contents = (
            self.root / "Resources" / "Assets.xcassets" / "Contents.json"
        )
        catalog_contents.write_text(
            '{"info":{"author":"attacker","author":"xcode","version":1}}',
            encoding="utf-8",
        )

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assert_error_contains(errors, "duplicate object keys")

    def test_settings_bound_source_asset_catalog_enumeration(self) -> None:
        with mock.patch.object(verify, "MAX_ASSET_CATALOG_ENTRIES", 1):
            _, errors = verify.verify_settings_file(
                self.settings_path, self.expected
            )

        self.assert_error_contains(errors, "entry verification limit")

    def test_settings_reject_extra_app_icon_set(self) -> None:
        alternate_set = (
            self.root / "Resources" / "Assets.xcassets" / "Alternate.appiconset"
        )
        alternate_set.mkdir()
        (alternate_set / "Contents.json").write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}),
            encoding="utf-8",
        )

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assert_error_contains(errors, "alternate AppIcon")

    def test_settings_reject_nested_or_icon_composer_icon_inputs(self) -> None:
        nested_set = (
            self.root
            / "Resources"
            / "Assets.xcassets"
            / "Nested"
            / "Alternate.appiconset"
        )
        nested_set.mkdir(parents=True)

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "alternate AppIcon")

        nested_set.rmdir()
        nested_set.parent.rmdir()
        composer = self.root / "Resources" / "Alternate.icon"
        composer.mkdir()
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "Icon Composer")

    def test_settings_bound_source_resources_enumeration(self) -> None:
        with mock.patch.object(verify, "MAX_SOURCE_RESOURCE_ENTRIES", 1):
            _, errors = verify.verify_settings_file(
                self.settings_path, self.expected
            )

        self.assert_error_contains(errors, "entry verification limit")

    def test_settings_reject_release_debug_compilation_condition_injection(
        self,
    ) -> None:
        injections = (
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "FEATURE DEBUG TRACE"),
            ("OTHER_SWIFT_FLAGS", "-DDEBUG"),
            ("OTHER_SWIFT_FLAGS", "-D DEBUG"),
            ("OTHER_SWIFT_FLAGS", "-D DEBUG=1"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend -DDEBUG"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend=-DDEBUG"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend -D -Xfrontend DEBUG"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend=-D -Xfrontend=DEBUG"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend -D -Xfrontend=DEBUG"),
            ("OTHER_SWIFT_FLAGS", "-D'DEBUG'"),
        )
        for key, value in injections:
            with self.subTest(key=key, value=value):
                changed = dict(self.settings)
                changed[key] = value
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assert_error_contains(errors, "DEBUG")

    def test_settings_allow_distinct_release_compilation_conditions(self) -> None:
        release = dict(self.settings)
        release["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "RELEASE DEBUG_FEATURE"
        self.write_settings(release)
        resolved, errors = verify.verify_settings_file(
            self.settings_path, self.expected
        )
        self.assertEqual([], errors)
        self.assertEqual(release, resolved)

    def test_settings_require_debug_condition_only_for_debug_configuration(
        self,
    ) -> None:
        debug = self.valid_settings("Debug")
        debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "TRACE"
        self.write_settings(debug)
        expected = self.expected_with(
            configuration="Debug",
            aps_environment="development",
        )
        _, errors = verify.verify_settings_file(self.settings_path, expected)
        self.assert_error_contains(errors, "Debug configuration must define DEBUG")

    def test_settings_reject_opaque_or_malformed_swift_condition_surfaces(self) -> None:
        mutations: tuple[tuple[str, object], ...] = (
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ["DEBUG"]),
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "'unterminated"),
            ("OTHER_SWIFT_FLAGS", ["-DDEBUG"]),
            ("OTHER_SWIFT_FLAGS", "'unterminated"),
            ("OTHER_SWIFT_FLAGS", "@opaque-response-file"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend=@opaque-response-file"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend"),
            ("OTHER_SWIFT_FLAGS", "-Xfrontend="),
        )
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                changed = dict(self.settings)
                changed[key] = value
                self.write_settings(changed)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"opaque condition surface {key} passed")

    def test_settings_reject_generated_project_per_file_compiler_flags(self) -> None:
        self.project_file.write_text(
            "// !$*UTF8*$!\n"
            "{ objects = {\n"
            "A1 /* SentiPocketApp.swift in Sources */ = {isa = PBXBuildFile; "
            'settings = {COMPILER_FLAGS = "-DDEBUG"; }; };\n'
            "}; }\n",
            encoding="utf-8",
        )
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "per-file compiler flags")

        # OpenStep quoted keys can spell the F in COMPILER_FLAGS through a
        # Unicode escape. The raw-byte substring does not see that spelling,
        # while plutil normalizes it in the structured PBX graph.
        self.write_valid_project()
        source_ref_id = "888888888888888888888888"
        source_build_id = "999999999999999999999999"
        source_phase_id = "AAAAAAAAAAAAAAAAAAAAAAAA"
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        objects[source_ref_id] = {
            "isa": "PBXFileReference",
            "path": "SentiPocketApp.swift",
            "sourceTree": "<group>",
        }
        objects[source_build_id] = {
            "isa": "PBXBuildFile",
            "fileRef": source_ref_id,
            "settings": {"COMPILER_FLAGS": "-DDEBUG"},
        }
        objects[source_phase_id] = {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [source_build_id],
            "runOnlyForDeploymentPostprocessing": "0",
        }
        target = objects[self.target_id]
        assert isinstance(target, dict)
        target["buildPhases"] = [source_phase_id, self.resources_phase_id]
        with self.project_file.open("a", encoding="utf-8") as stream:
            stream.write('"COMPILER_\\U0046LAGS" = "-DDEBUG";\n')
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "broken build file")

    def test_settings_bind_app_icon_catalog_to_app_resources_phase(self) -> None:
        def break_phase(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            target = objects[self.target_id]
            assert isinstance(target, dict)
            target["buildPhases"] = ["FFFFFFFFFFFFFFFFFFFFFFFF"]

        def move_resources(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            resources = objects[self.resources_group_id]
            assert isinstance(resources, dict)
            resources["path"] = "OtherResources"

        def orphan_root(graph: dict[str, object]) -> None:
            graph["rootObject"] = self.asset_build_file_id

        for label, mutate in (
            ("broken phase", break_phase),
            ("wrong group path", move_resources),
            ("orphan graph", orphan_root),
        ):
            with self.subTest(label=label):
                self.write_valid_project()
                mutate(self.project_graph)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"{label} unexpectedly passed")

    def test_repository_app_icon_matches_the_pinned_approved_digest(self) -> None:
        icon_path = (
            REPOSITORY_ROOT
            / "apps"
            / "SentiPocketApp"
            / "Resources"
            / "Assets.xcassets"
            / "AppIcon.appiconset"
            / "SentiPocketAppIcon.png"
        )
        encoded = icon_path.read_bytes()
        self.assertEqual(PINNED_APP_ICON_SHA256, hashlib.sha256(encoded).hexdigest())
        with mock.patch.object(verify, "APP_ICON_SHA256", PINNED_APP_ICON_SHA256):
            self.assertEqual([], verify._source_app_icon_png_errors(icon_path))

    def test_repository_project_spec_matches_reviewed_digest_before_xcodegen(
        self,
    ) -> None:
        spec_path = REPOSITORY_ROOT / verify.PROJECT_SPEC_RELATIVE
        canonical = spec_path.read_bytes().replace(b"\r\n", b"\n")
        self.assertNotIn(b"\r", canonical)
        self.assertEqual(
            PINNED_PROJECT_SPEC_SHA256,
            hashlib.sha256(canonical).hexdigest(),
        )
        self.assertEqual([], self.real_project_spec_errors(REPOSITORY_ROOT))

        repository = self.root / "project-spec-repository"
        copied_spec = repository / verify.PROJECT_SPEC_RELATIVE
        copied_spec.parent.mkdir(parents=True)
        copied_spec.write_bytes(canonical)
        self.assertEqual([], self.real_project_spec_errors(repository))

        copied_spec.write_bytes(canonical.replace(b"\n", b"\r\n"))
        self.assertEqual([], self.real_project_spec_errors(repository))

        copied_spec.write_bytes(
            canonical + b"\npreGenCommand: touch /tmp/xcodegen-gate-bypass\n"
        )
        errors = self.real_project_spec_errors(repository)
        self.assert_error_contains(errors, "reviewed digest")

    def test_hosted_settings_capture_is_fail_fast_and_swift_tool_bound(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/ios-verify.yml").read_text(
            encoding="utf-8"
        )
        capture = workflow.split(
            "- name: Capture and verify unsigned device build settings", maxsplit=1
        )[1].split("- name: Build unsigned Release device closure", maxsplit=1)[0]
        self.assertIn("set -euo pipefail", capture)
        self.assertIn("SWIFT_TOOLS_DIR=$DEVELOPER_DIR/Toolchains/", capture)
        self.assertIn("SWIFT_USE_INTEGRATED_DRIVER=YES", capture)
        self.assertIn("CODESIGN=/usr/bin/codesign", capture)
        self.assertIn("COMPILATION_CACHE_ENABLE_PLUGIN=NO", capture)
        self.assertIn("SWIFT_ENABLE_COMPILE_CACHE=NO", capture)
        self.assertIn("ALTERNATE_LINKER_PATH=", capture)

        archive = (REPOSITORY_ROOT / "scripts/ios/archive_ipa.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('"CODESIGN=/usr/bin/codesign"', archive)
        self.assertIn('"COMPILATION_CACHE_ENABLE_PLUGIN=NO"', archive)
        self.assertIn('"SWIFT_ENABLE_COMPILE_CACHE=NO"', archive)
        self.assertIn('"ALTERNATE_LINKER_PATH="', archive)
        self.assertIn("/usr/bin/codesign --verify --deep --strict", archive)
        self.assertNotIn("\nif ! codesign --verify", archive)

    def test_repository_package_manifests_match_reviewed_release_closure(self) -> None:
        self.assertEqual(
            verify.APPROVED_PACKAGE_PRODUCTS,
            set(verify.APPROVED_PACKAGE_MANIFEST_SHA256),
        )
        self.assertEqual([], self.real_package_manifest_errors(REPOSITORY_ROOT))

        repository = self.root / "manifest-repository"
        for product in verify.APPROVED_PACKAGE_PRODUCTS:
            package_directory = repository / "packages" / product
            package_directory.mkdir(parents=True)
            encoded = (
                REPOSITORY_ROOT / "packages" / product / "Package.swift"
            ).read_bytes()
            (package_directory / "Package.swift").write_bytes(
                encoded.replace(b"\r\n", b"\n")
            )
        self.assertEqual([], self.real_package_manifest_errors(repository))

        product = sorted(verify.APPROVED_PACKAGE_PRODUCTS)[0]
        manifest = repository / "packages" / product / "Package.swift"
        manifest.write_bytes(manifest.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual([], self.real_package_manifest_errors(repository))

        manifest.write_bytes(manifest.read_bytes() + b"// plugin drift\r\n")
        errors = self.real_package_manifest_errors(repository)
        self.assert_error_contains(errors, "reviewed digest")

        manifest.write_bytes(
            (REPOSITORY_ROOT / "packages" / product / "Package.swift").read_bytes()
        )
        (repository / "packages" / product / "Package@swift-6.swift").write_text(
            "// alternate executable manifest\n", encoding="utf-8"
        )
        errors = self.real_package_manifest_errors(repository)
        self.assert_error_contains(errors, "only canonical Package.swift")

    def test_settings_reject_decoy_or_alternate_target_asset_catalogs(self) -> None:
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        alternate_group_id = "888888888888888888888888"
        alternate_ref_id = "999999999999999999999999"
        alternate_build_id = "AAAAAAAAAAAAAAAAAAAAAAAA"
        main_group = objects[self.main_group_id]
        resources_phase = objects[self.resources_phase_id]
        assert isinstance(main_group, dict)
        assert isinstance(resources_phase, dict)
        main_group["children"] = [self.resources_group_id, alternate_group_id]
        objects[alternate_group_id] = {
            "isa": "PBXGroup",
            "children": [alternate_ref_id],
            "path": "Decoy",
            "sourceTree": "<group>",
        }
        objects[alternate_ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder.assetcatalog",
            "path": "Alternate.xcassets",
            "sourceTree": "<group>",
        }
        objects[alternate_build_id] = {
            "isa": "PBXBuildFile",
            "fileRef": alternate_ref_id,
        }
        resources_phase["files"] = [alternate_build_id]

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assert_error_contains(errors, "asset catalog")

    def test_settings_reject_cyclic_or_multiply_reachable_main_group(self) -> None:
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        resources_group = objects[self.resources_group_id]
        assert isinstance(resources_group, dict)
        resources_group["children"] = [self.asset_ref_id, self.main_group_id]

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assert_error_contains(errors, "cyclic or ambiguous")

    def test_settings_reject_unverified_project_membership_surfaces(self) -> None:
        def project_root_shift(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            project = objects[self.project_id]
            assert isinstance(project, dict)
            project["projectDirPath"] = "Decoy"

        def synchronized_group(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            target = objects[self.target_id]
            assert isinstance(target, dict)
            target["fileSystemSynchronizedGroups"] = [
                "888888888888888888888888"
            ]

        def target_dependency(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            target = objects[self.target_id]
            assert isinstance(target, dict)
            target["dependencies"] = ["888888888888888888888888"]

        def inactive_resources(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            phase = objects[self.resources_phase_id]
            assert isinstance(phase, dict)
            phase["runOnlyForDeploymentPostprocessing"] = "1"

        def inactive_action_mask(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            phase = objects[self.resources_phase_id]
            assert isinstance(phase, dict)
            phase["buildActionMask"] = "0"

        def conditional_asset(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            build_file = objects[self.asset_build_file_id]
            assert isinstance(build_file, dict)
            build_file["platformFilter"] = "macos"

        def shell_phase(graph: dict[str, object]) -> None:
            objects = graph["objects"]
            assert isinstance(objects, dict)
            shell_id = "888888888888888888888888"
            objects[shell_id] = {"isa": "PBXShellScriptBuildPhase"}
            target = objects[self.target_id]
            assert isinstance(target, dict)
            target["buildPhases"] = [self.resources_phase_id, shell_id]

        for label, mutate in (
            ("project root shift", project_root_shift),
            ("synchronized group", synchronized_group),
            ("target dependency", target_dependency),
            ("inactive resources", inactive_resources),
            ("inactive action mask", inactive_action_mask),
            ("conditional asset", conditional_asset),
            ("shell phase", shell_phase),
        ):
            with self.subTest(label=label):
                self.write_valid_project()
                mutate(self.project_graph)
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"{label} unexpectedly passed")

    def test_settings_bind_exact_local_package_product_closure(self) -> None:
        product = sorted(verify.APPROVED_PACKAGE_PRODUCTS)[0]

        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        package_product = objects[self.package_product_ids[product]]
        assert isinstance(package_product, dict)
        package_product["productName"] = "plugin:EvilBuildPlugin"
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "approved package product names")

        self.write_valid_project()
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        package_reference = objects[self.package_reference_ids[product]]
        assert isinstance(package_reference, dict)
        package_reference.clear()
        package_reference.update(
            {
                "isa": "XCRemoteSwiftPackageReference",
                "repositoryURL": "https://example.invalid/evil.git",
                "requirement": {"kind": "branch", "branch": "main"},
            }
        )
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unverified Swift package reference")

        self.write_valid_project()
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        frameworks_phase = objects[self.frameworks_phase_id]
        assert isinstance(frameworks_phase, dict)
        frameworks_phase["files"] = list(self.package_build_file_ids.values())[1:]
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "link every approved package product")

    def test_settings_reject_project_compiler_override_surface(self) -> None:
        mutations = (
            ("CC", "/tmp/evil-clang"),
            ("CC[sdk=iphoneos*]", "/tmp/evil-clang"),
            ("SWIFT_EXEC[config=Release]", "/tmp/evil-swiftc"),
            ("PATH[sdk=iphoneos*]", "/tmp/attacker-bin"),
            ("TOOLCHAINS[config=Release]", "com.example.evil"),
            ("SDKROOT[config=Release]", "/tmp/Evil.sdk"),
            ("OTHER_SWIFT_FLAGS[sdk=iphoneos*]", "-load-plugin-library /tmp/e"),
            ("OTHER_CFLAGS[config=Release]", "-Xclang -load -Xclang /tmp/e"),
            ("OTHER_CFLAGS_normal", "-Xclang -load -Xclang /tmp/e"),
            ("OTHER_LDFLAGS_normal", "-Wl,-load,/tmp/e"),
            ("ALTERNATE_LINKER[config=Release]", "/tmp/evil-linker"),
            ("ALTERNATE_LINKER_PATH", "/tmp/evil-linker"),
            ("LD_FLAGS_normal", "-ld-path=/tmp/evil-linker"),
            ("ALL_OTHER_LDFLAGS[config=Release]", "-ld-path=/tmp/e"),
            ("LD_OBJC_RUNTIME_ARGS", "-ld-path=/tmp/evil-linker"),
            ("LD_OBJC_RUNTIME_ARGS_swiftc", "-ld-path=/tmp/evil-linker"),
            ("INFOPLIST_PREPROCESS", "YES"),
            ("INFOPLIST_PREPROCESS[sdk=iphoneos*]", "YES"),
            ("SWIFT_TOOLS_DIR[config=Release]", "/tmp/evil-tools"),
            ("ASSETCATALOG_EXEC[config=Release]", "/tmp/evil-actool"),
            (
                "SWIFT_TOOLCHAIN_FLAGS[config=Release]",
                "-driver-use-frontend-path /tmp/evil",
            ),
            ("SWIFT_RESPONSE_FILE_PATH[config=Release]", "/tmp/evil.rsp"),
            ("SWIFT_USE_INTEGRATED_DRIVER[config=Release]", "NO"),
            ("COMPILATION_CACHE_ENABLE_PLUGIN", "YES"),
            ("COMPILATION_CACHE_PLUGIN_PATH[config=Release]", "/tmp/e.dylib"),
            ("SWIFT_ENABLE_COMPILE_CACHE", "YES"),
            ("CODESIGN", "/tmp/evil-codesign"),
            ("CODESIGN_ALLOCATE[config=Release]", "/tmp/evil-helper"),
            (
                "INFOPLIST_OTHER_PREPROCESSOR_FLAGS[config=Release]",
                "-Xclang -load -Xclang /tmp/e",
            ),
            ("C_COMPILER_LAUNCHER[sdk=iphoneos*]", "/tmp/e"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                self.write_valid_project()
                objects = self.project_graph["objects"]
                assert isinstance(objects, dict)
                objects["E00000000000000000000000"] = {
                    "isa": "XCBuildConfiguration",
                    "buildSettings": {key: value},
                    "name": "Release",
                }
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assert_error_contains(errors, "executable tool override")

        self.write_valid_project()
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        objects["E00000000000000000000000"] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": {"CC[sdk=iphoneos*": "/tmp/e"},
            "name": "Release",
        }
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "invalid build-setting key")

    def test_settings_bind_minimal_script_free_release_scheme(self) -> None:
        original = self.scheme_path.read_text(encoding="utf-8")
        mutations = (
            (
                "implicit dependencies",
                original.replace(
                    'buildImplicitDependencies="NO"',
                    'buildImplicitDependencies="YES"',
                    1,
                ),
            ),
            (
                "wrong target",
                original.replace(self.target_id, "888888888888888888888888", 1),
            ),
            (
                "wrong buildable identifier",
                original.replace(
                    'BuildableIdentifier="primary"',
                    'BuildableIdentifier="secondary"',
                    1,
                ),
            ),
            (
                "pre-action script",
                original.replace(
                    "<BuildActionEntries>",
                    '<PreActions><ExecutionAction ActionType="ShellScript"/></PreActions>'
                    "<BuildActionEntries>",
                    1,
                ),
            ),
            (
                "second build target",
                original.replace(
                    "</BuildActionEntries>",
                    '<BuildActionEntry buildForRunning="YES"/>'
                    "</BuildActionEntries>",
                    1,
                ),
            ),
            (
                "debug archive",
                original.replace(
                    'ArchiveAction buildConfiguration="Release"',
                    'ArchiveAction buildConfiguration="Debug"',
                    1,
                ),
            ),
        )
        for label, changed in mutations:
            with self.subTest(label=label):
                self.scheme_path.write_text(changed, encoding="utf-8")
                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )
                self.assertTrue(errors, f"{label} unexpectedly passed")

        self.scheme_path.unlink()
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "scheme")

    def test_settings_reject_duplicate_asset_reference_or_icon_resource(self) -> None:
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        duplicate_ref_id = "888888888888888888888888"
        objects[duplicate_ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder.assetcatalog",
            "path": "Assets.xcassets",
            "sourceTree": "<group>",
        }
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unambiguous Assets.xcassets")

        self.write_valid_project()
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        icon_ref_id = "888888888888888888888888"
        icon_build_id = "999999999999999999999999"
        objects[icon_ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder",
            "path": "Alternate.icon",
            "sourceTree": "<group>",
        }
        objects[icon_build_id] = {"isa": "PBXBuildFile", "fileRef": icon_ref_id}
        phase = objects[self.resources_phase_id]
        assert isinstance(phase, dict)
        phase["files"] = [self.asset_build_file_id, icon_build_id]
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "Icon Composer")

        self.write_valid_project()
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        objects[icon_ref_id] = {
            "isa": "PBXFileReference",
            "explicitFileType": "folder.iconcomposer.icon",
            "path": "Decoy",
            "sourceTree": "<group>",
        }
        objects[icon_build_id] = {"isa": "PBXBuildFile", "fileRef": icon_ref_id}
        phase = objects[self.resources_phase_id]
        assert isinstance(phase, dict)
        phase["files"] = [self.asset_build_file_id, icon_build_id]
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "Icon Composer")

    def test_settings_reject_unverified_phase_input_paths(self) -> None:
        mutations = (
            ("PBXResourcesBuildPhase", "Resources", "folder"),
            ("PBXSourcesBuildPhase", "../../Outside.swift", "sourcecode.swift"),
            ("PBXFrameworksBuildPhase", "../../Helper.framework", "wrapper.framework"),
        )
        for index, (phase_isa, path, file_type) in enumerate(mutations, start=8):
            with self.subTest(phase=phase_isa):
                self.write_valid_project()
                objects = self.project_graph["objects"]
                assert isinstance(objects, dict)
                reference_id = f"{index:024X}"
                build_id = f"{index + 10:024X}"
                phase_id = f"{index + 20:024X}"
                objects[reference_id] = {
                    "isa": "PBXFileReference",
                    "lastKnownFileType": file_type,
                    "path": path,
                    "sourceTree": "SOURCE_ROOT",
                }
                objects[build_id] = {
                    "isa": "PBXBuildFile",
                    "fileRef": reference_id,
                }
                objects[phase_id] = {
                    "isa": phase_isa,
                    "buildActionMask": "2147483647",
                    "files": [build_id],
                    "runOnlyForDeploymentPostprocessing": "0",
                }
                target = objects[self.target_id]
                assert isinstance(target, dict)
                target["buildPhases"] = [self.resources_phase_id, phase_id]

                _, errors = verify.verify_settings_file(
                    self.settings_path, self.expected
                )

                self.assertTrue(errors, f"{phase_isa} unsafe input unexpectedly passed")

    def test_project_graph_walk_handles_a_deep_bounded_group_chain(self) -> None:
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        main_group = objects[self.main_group_id]
        assert isinstance(main_group, dict)
        previous_id = self.main_group_id
        for index in range(1, 1001):
            group_id = f"{index:024X}"
            group = {
                "isa": "PBXGroup",
                "children": [],
                "sourceTree": "<group>",
            }
            objects[group_id] = group
            previous = objects[previous_id]
            assert isinstance(previous, dict)
            previous["children"] = [group_id]
            previous_id = group_id
        final_group = objects[previous_id]
        assert isinstance(final_group, dict)
        final_group["children"] = [self.resources_group_id]

        _, errors = verify.verify_settings_file(self.settings_path, self.expected)

        self.assertEqual([], errors)

    def test_settings_allow_only_the_pinned_opaque_ui_test_source_group(self) -> None:
        root_group_id = "E10000000000000000000000"
        packages_group_id = "E20000000000000000000000"
        pocket_ui_group_id = "E30000000000000000000000"
        device_tests_group_id = "E40000000000000000000000"
        child_id = "E50000000000000000000000"
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        main_group = objects[self.main_group_id]
        assert isinstance(main_group, dict)
        children = main_group["children"]
        assert isinstance(children, list)
        children.append(root_group_id)
        objects[root_group_id] = {
            "isa": "PBXGroup",
            "children": [packages_group_id],
            "name": ".",
            "path": "../..",
            "sourceTree": "<group>",
        }
        objects[packages_group_id] = {
            "isa": "PBXGroup",
            "children": [pocket_ui_group_id],
            "path": "packages",
            "sourceTree": "<group>",
        }
        objects[pocket_ui_group_id] = {
            "isa": "PBXGroup",
            "children": [device_tests_group_id],
            "path": "PocketUI",
            "sourceTree": "<group>",
        }
        objects[device_tests_group_id] = {
            "isa": "PBXGroup",
            "children": [child_id],
            "path": "DeviceUITests",
            "sourceTree": "<group>",
        }
        objects[child_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "sourcecode.swift",
            "path": "ExampleUITest.swift",
            "sourceTree": "<group>",
        }

        self.write_settings(self.settings)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assertEqual([], errors)

        root_group = objects[root_group_id]
        assert isinstance(root_group, dict)
        root_group["path"] = "../../.."
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unsafe PBXGroup path")

        root_group["path"] = "../.."
        pocket_ui_group = objects[pocket_ui_group_id]
        assert isinstance(pocket_ui_group, dict)
        pocket_ui_group["path"] = "OtherUI"
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "approved canonical chain")

        pocket_ui_group["path"] = "PocketUI"
        root_group["sourceTree"] = "SOURCE_ROOT"
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "approved canonical chain")

        root_group["sourceTree"] = "<group>"
        wrapper_group_id = "E60000000000000000000000"
        children.remove(root_group_id)
        children.append(wrapper_group_id)
        objects[wrapper_group_id] = {
            "isa": "PBXGroup",
            "children": [root_group_id],
            "path": "Wrapper",
            "sourceTree": "<group>",
        }
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unsafe PBXGroup path")

    def test_settings_reject_duplicate_external_ui_test_root(self) -> None:
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        main_group = objects[self.main_group_id]
        assert isinstance(main_group, dict)
        children = main_group["children"]
        assert isinstance(children, list)
        chain_ids = [f"E{index:023X}" for index in range(1, 11)]
        for offset in (0, 5):
            root_id, packages_id, pocket_ui_id, device_tests_id, file_id = chain_ids[
                offset : offset + 5
            ]
            children.append(root_id)
            objects[root_id] = {
                "isa": "PBXGroup",
                "children": [packages_id],
                "path": "../..",
                "sourceTree": "<group>",
            }
            objects[packages_id] = {
                "isa": "PBXGroup",
                "children": [pocket_ui_id],
                "path": "packages",
                "sourceTree": "<group>",
            }
            objects[pocket_ui_id] = {
                "isa": "PBXGroup",
                "children": [device_tests_id],
                "path": "PocketUI",
                "sourceTree": "<group>",
            }
            objects[device_tests_id] = {
                "isa": "PBXGroup",
                "children": [file_id],
                "path": "DeviceUITests",
                "sourceTree": "<group>",
            }
            objects[file_id] = {
                "isa": "PBXFileReference",
                "path": f"Example{offset}.swift",
                "sourceTree": "<group>",
            }

        self.write_settings(self.settings)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "multiple external UI-test roots")

    def test_settings_reject_opaque_group_alias_and_unhashable_path(self) -> None:
        root_group_id = "E10000000000000000000000"
        packages_group_id = "E20000000000000000000000"
        pocket_ui_group_id = "E30000000000000000000000"
        device_tests_group_id = "E40000000000000000000000"
        nested_group_id = "E50000000000000000000000"
        nested_file_id = "E60000000000000000000000"
        objects = self.project_graph["objects"]
        assert isinstance(objects, dict)
        main_group = objects[self.main_group_id]
        assert isinstance(main_group, dict)
        children = main_group["children"]
        assert isinstance(children, list)
        children.append(root_group_id)
        objects[root_group_id] = {
            "isa": "PBXGroup",
            "children": [packages_group_id],
            "path": "../..",
            "sourceTree": "<group>",
        }
        objects[packages_group_id] = {
            "isa": "PBXGroup",
            "children": [pocket_ui_group_id],
            "path": "packages",
            "sourceTree": "<group>",
        }
        objects[pocket_ui_group_id] = {
            "isa": "PBXGroup",
            "children": [device_tests_group_id],
            "path": "PocketUI",
            "sourceTree": "<group>",
        }
        objects[device_tests_group_id] = {
            "isa": "PBXGroup",
            "children": [nested_group_id],
            "path": "DeviceUITests",
            "sourceTree": "<group>",
        }
        objects[nested_group_id] = {
            "isa": "PBXGroup",
            "children": [nested_file_id],
            "path": "Nested",
            "sourceTree": "<group>",
        }
        objects[nested_file_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "sourcecode.swift",
            "path": "NestedUITest.swift",
            "sourceTree": "<group>",
        }

        self.write_settings(self.settings)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assertEqual([], errors)

        source_build_file_id = "E70000000000000000000000"
        source_phase_id = "E80000000000000000000000"
        objects[source_build_file_id] = {
            "isa": "PBXBuildFile",
            "fileRef": nested_file_id,
        }
        objects[source_phase_id] = {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [source_build_file_id],
            "runOnlyForDeploymentPostprocessing": "0",
        }
        target = objects[self.target_id]
        assert isinstance(target, dict)
        build_phases = target["buildPhases"]
        assert isinstance(build_phases, list)
        build_phases.append(source_phase_id)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unsafe source path")
        build_phases.remove(source_phase_id)
        del objects[source_phase_id]
        del objects[source_build_file_id]

        nested_group = objects[nested_group_id]
        assert isinstance(nested_group, dict)
        nested_group["children"] = [self.asset_ref_id]
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "multiply reachable")

        for object_id in (
            root_group_id,
            packages_group_id,
            pocket_ui_group_id,
            device_tests_group_id,
            nested_group_id,
            nested_file_id,
        ):
            del objects[object_id]
        children.remove(root_group_id)
        resources_group = objects[self.resources_group_id]
        assert isinstance(resources_group, dict)
        resources_group["path"] = []
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "unsafe PBXGroup path")

    def test_settings_reject_decoy_generated_project_path(self) -> None:
        decoy = self.root / "decoy" / "SentiPocketApp.xcodeproj" / "project.pbxproj"
        decoy.parent.mkdir(parents=True)
        decoy.write_text("// !$*UTF8*$!\n{ objects = {}; }\n", encoding="utf-8")
        expected = self.expected_with(project_file=decoy)

        _, errors = verify.verify_settings_file(self.settings_path, expected)

        self.assert_error_contains(errors, "PROJECT_FILE_PATH")

    def test_settings_reject_malformed_or_oversized_generated_project(self) -> None:
        self.project_file.write_bytes(b"\xff\xfe")
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "could not be decoded")

        self.write_valid_project()
        with mock.patch.object(verify, "MAX_PROJECT_BYTES", 1):
            _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "verification limit")

        self.project_file.unlink()
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "not a regular file")

    def test_project_conversion_invokes_exact_bounded_plutil(self) -> None:
        expected_bytes = self.project_file.read_bytes()
        observed_command: list[str] = []

        def fake_run(command: list[str], **kwargs: object) -> object:
            observed_command.extend(command)
            self.assertNotEqual(str(self.project_file), command[-1])
            self.assertEqual(expected_bytes, Path(command[-1]).read_bytes())
            Path(command[4]).write_text(
                json.dumps(self.project_graph), encoding="utf-8"
            )
            return verify.subprocess.CompletedProcess(command, 0)

        with (
            mock.patch.object(verify.sys, "platform", "darwin"),
            mock.patch.object(verify.subprocess, "run", side_effect=fake_run),
        ):
            project, errors = self.real_project_converter(
                self.project_file, expected_bytes
            )

        self.assertEqual([], errors)
        self.assertEqual(self.project_graph, project)
        self.assertEqual("/usr/bin/plutil", observed_command[0])
        self.assertEqual(["-convert", "json", "-o"], observed_command[1:4])
        self.assertEqual("--", observed_command[-2])
        self.assertTrue(observed_command[-1].endswith("project.pbxproj"))

    def test_settings_reject_generated_project_symlink(self) -> None:
        outside = self.root / "outside.pbxproj"
        outside.write_text("// !$*UTF8*$!\n{}\n", encoding="utf-8")
        self.project_file.unlink()
        self.symlink_or_skip(outside, self.project_file)
        _, errors = verify.verify_settings_file(self.settings_path, self.expected)
        self.assert_error_contains(errors, "not a regular file")

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
        self.assert_error_contains(
            errors, "EXCLUDED_SOURCE_FILE_NAMES: expected '', got"
        )

    def test_settings_reject_debug_wildcard_that_excludes_fixture(self) -> None:
        debug = self.valid_settings("Debug")
        debug["EXCLUDED_SOURCE_FILE_NAMES"] = "*.json"
        self.write_settings(debug)
        expected = self.expected_with(
            configuration="Debug",
            aps_environment="development",
        )
        _, errors = verify.verify_settings_file(self.settings_path, expected)
        self.assert_error_contains(
            errors, "EXCLUDED_SOURCE_FILE_NAMES: expected '', got"
        )

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

    def test_expectations_accept_selected_unversioned_sdk_path_only(self) -> None:
        sdk_directory = self.developer_dir / (
            "Platforms/iPhoneOS.platform/Developer/SDKs"
        )
        errors = verify.validate_expectations(
            self.expected_with(sdk_root=sdk_directory / "iPhoneOS.sdk")
        )
        self.assertEqual([], errors)

        for sdk_root in (
            sdk_directory / "iPhoneSimulator.sdk",
            sdk_directory / "iPhoneOSbeta.sdk",
            PurePosixPath("/tmp/Evil.app/Contents/Developer/Platforms/")
            / "iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
        ):
            with self.subTest(sdk_root=sdk_root):
                errors = verify.validate_expectations(
                    self.expected_with(sdk_root=sdk_root)
                )
                self.assert_error_contains(errors, "sdk_root")

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

    def test_bundle_rejects_app_icon_metadata_and_artifact_drift(self) -> None:
        original = self.read_info()
        mutations = (
            ("UIDeviceFamily", [1, 2]),
            ("UIDeviceFamily", [True]),
            ("UIDeviceFamily", "1"),
            ("CFBundleIcons", {}),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "OtherIcon",
                        "CFBundleIconFiles": ["AppIcon60x60"],
                    }
                },
            ),
            (
                "CFBundleIcons~ipad",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["AppIcon76x76"],
                    },
                    "CFBundleAlternateIcons": {"OtherIcon": {}},
                },
            ),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["AppIcon1x1"],
                    }
                },
            ),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["AppIcon60x60"],
                        "CFBundleIconFiles~iphone": ["OtherIcon"],
                    }
                },
            ),
            (
                "CFBundleIcons~iphone",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["AppIcon60x60"],
                    },
                    "CFBundleAlternateIcons": {"OtherIcon": {}},
                },
            ),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": original["CFBundleIcons"][
                        "CFBundlePrimaryIcon"
                    ],
                    "CFBundleAlternateIcons": {"OtherIcon": {}},
                },
            ),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["AppIcon60x60.png"],
                    }
                },
            ),
            (
                "CFBundleIcons",
                {
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "AppIcon",
                        "CFBundleIconFiles": ["../Outside"],
                    }
                },
            ),
        )
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                self.write_info({**original, key: value})
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assertTrue(errors, f"Info.plist mutation for {key} passed")

        for qualified_key in (
            "CFBundleAlternateIcons~iphone",
            "CFBundleAlternateIcons-iphoneos~iphone",
            "CFBundleIconFile",
            "CFBundleIconFiles",
        ):
            with self.subTest(qualified_key=qualified_key):
                self.write_info({**original, qualified_key: "OtherIcon"})
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, "icon metadata")

        self.write_info(original)
        compiled_assets = self.app_path / "Assets.car"
        compiled_assets.unlink()
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "Assets.car")

        compiled_assets.write_bytes(b"")
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "Assets.car")

        compiled_assets.write_bytes(b"not-a-coreui-archive")
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "BOMStore")

        compiled_assets.write_bytes(b"BOMStore synthetic compiled assets")
        (self.app_path / "AppIcon60x60@2x.png").unlink()
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "AppIcon60x60")

        (self.app_path / "AppIcon60x60@2x.png").write_bytes(
            self.synthetic_png(width=120, height=120)
        )
        (self.app_path / "OtherIcon60x60@2x.png").write_bytes(self.synthetic_png())
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "alternate icon artifact")

    def test_bundle_rejects_duplicate_xml_plist_keys(self) -> None:
        info_path = self.app_path / "Info.plist"
        original = self.read_info()
        xml = plistlib.dumps(original, fmt=plistlib.FMT_XML).decode("utf-8")
        duplicate = (
            "<key>CFBundleIcons</key>"
            "<dict><key>CFBundleAlternateIcons</key><dict/></dict>"
        )
        duplicate_xml = xml.replace("<dict>", f"<dict>{duplicate}", 1)
        variants = (
            duplicate_xml,
            duplicate_xml[duplicate_xml.index("<plist") :],
        )
        for variant in variants:
            with self.subTest(prefix=variant[:20]):
                info_path.write_text(variant, encoding="utf-8")
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, "duplicate dictionary keys")

    def test_bundle_rejects_namespaced_xml_plist_duplicate_key_bypass(self) -> None:
        info_path = self.app_path / "Info.plist"
        original = self.read_info()
        xml = plistlib.dumps(original, fmt=plistlib.FMT_XML).decode("utf-8")
        duplicate = (
            "<key>CFBundleIcons</key>"
            "<dict><key>CFBundleAlternateIcons</key><dict/></dict>"
        )
        namespaced = xml.replace(
            '<plist version="1.0">',
            '<plist version="1.0" xmlns="urn:attacker">',
        ).replace("<dict>", f"<dict>{duplicate}", 1)
        info_path.write_text(namespaced, encoding="utf-8")

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assert_error_contains(errors, "unsupported")

    def test_bundle_rejects_nested_plist_last_value_bypass(self) -> None:
        info_path = self.app_path / "Info.plist"
        original_xml = plistlib.dumps(
            self.read_info(), fmt=plistlib.FMT_XML
        ).decode("utf-8")
        safe_dict = original_xml[
            original_xml.index("<dict>") : original_xml.rindex("</dict>") + 7
        ]
        malicious = (
            "<dict><key>CFBundleIcons</key><dict>"
            "<key>CFBundleAlternateIcons</key><dict/></dict></dict>"
        )
        nested = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<plist version="1.0"><plist>'
            f"{malicious}{safe_dict}</plist></plist>"
        )
        info_path.write_text(nested, encoding="utf-8")

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assert_error_contains(errors, "unsupported")

    def test_plist_reader_rejects_duplicate_binary_dictionary_keys(self) -> None:
        key = b"CFBundleIcons"
        objects = (
            bytes((0x50 | len(key),)) + key,
            b"\xD0",
            b"\xD2\x00\x00\x01\x01",
        )
        body = bytearray(b"bplist00")
        offsets: list[int] = []
        for item in objects:
            offsets.append(len(body))
            body.extend(item)
        offset_table = len(body)
        body.extend(bytes(offsets))
        body.extend(b"\0" * 6)
        body.extend(b"\x01\x01")
        body.extend(len(objects).to_bytes(8, "big"))
        body.extend((2).to_bytes(8, "big"))
        body.extend(offset_table.to_bytes(8, "big"))
        info_path = self.app_path / "Info.plist"
        info_path.write_bytes(body)

        _, errors = verify._read_plist(info_path, "built Info.plist")

        self.assert_error_contains(errors, "duplicate dictionary keys")

    def test_plist_reader_bounds_binary_object_table(self) -> None:
        info_path = self.app_path / "Info.plist"
        with mock.patch.object(verify, "MAX_PLIST_OBJECTS", 1):
            _, errors = verify._read_plist(info_path, "built Info.plist")

        self.assert_error_contains(errors, "malformed object table")

    def test_xml_plist_reader_bounds_object_count_and_depth(self) -> None:
        info_path = self.app_path / "Info.plist"
        many_values = (
            '<plist version="1.0"><array>'
            + "<string/>" * 4
            + "</array></plist>"
        ).encode()
        info_path.write_bytes(many_values)
        with mock.patch.object(verify, "MAX_PLIST_OBJECTS", 3):
            _, errors = verify._read_plist(info_path, "built Info.plist")
        self.assert_error_contains(errors, "object verification limit")

        deep_value = (
            '<plist version="1.0">'
            + "<array>" * 4
            + "<string/>"
            + "</array>" * 4
            + "</plist>"
        ).encode()
        info_path.write_bytes(deep_value)
        with mock.patch.object(verify, "MAX_XML_PLIST_DEPTH", 3):
            _, errors = verify._read_plist(info_path, "built Info.plist")
        self.assert_error_contains(errors, "nesting-depth verification limit")

        info_path.write_bytes(b"<plist version=\"1.0\"><string>oversized</string></plist>")
        with mock.patch.object(verify, "MAX_XML_PLIST_BYTES", 8):
            _, errors = verify._read_plist(info_path, "built Info.plist")
        self.assert_error_contains(errors, "byte verification limit")

    def test_privacy_manifest_comparison_handles_deep_valid_plists_iteratively(
        self,
    ) -> None:
        depth = 500
        nested = "<array>" * depth + "<string>x</string>" + "</array>" * depth
        encoded = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<plist version="1.0"><dict><key>x</key>'
            f"{nested}</dict></plist>"
        ).encode()
        source = self.root / "deep-source.xcprivacy"
        bundled = self.root / "deep-bundled.xcprivacy"
        source.write_bytes(encoded)
        bundled.write_bytes(encoded)
        with mock.patch.object(verify, "MAX_XML_PLIST_DEPTH", depth + 2):
            source_payload, source_errors = verify._read_plist(
                source, "source PrivacyInfo.xcprivacy"
            )
            bundled_payload, bundled_errors = verify._read_plist(
                bundled, "bundled PrivacyInfo.xcprivacy"
            )

        self.assertEqual([], source_errors)
        self.assertEqual([], bundled_errors)
        self.assertIsNotNone(source_payload)
        self.assertIsNotNone(bundled_payload)
        self.assertTrue(
            verify._type_sensitive_plist_equal(source_payload, bundled_payload)
        )

    def test_binary_plist_key_decode_is_cached_by_physical_offset(self) -> None:
        encoded = plistlib.dumps(
            [{"K" * 4096: index} for index in range(500)],
            fmt=plistlib.FMT_BINARY,
            sort_keys=False,
        )

        self.assertIsNone(verify._binary_plist_duplicate_key_error(encoded))

    def test_plist_value_validator_rejects_cycles_and_unsupported_values(self) -> None:
        cyclic: list[object] = []
        cyclic.append(cyclic)
        self.assertIn("cyclic", verify._plist_value_error({"cycle": cyclic}) or "")
        self.assertIn(
            "unsupported",
            verify._plist_value_error({"unsupported": object()}) or "",
        )
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value):
                self.assertIn(
                    "non-finite",
                    verify._plist_value_error({"real": value}) or "",
                )

    def test_plist_reader_rejects_binary_container_cycle(self) -> None:
        objects = (b"\xd1\x01\x02", b"\x54loop", b"\xa1\x02")
        body = bytearray(b"bplist00")
        offsets: list[int] = []
        for item in objects:
            offsets.append(len(body))
            body.extend(item)
        offset_table = len(body)
        body.extend(bytes(offsets))
        body.extend(b"\0" * 6)
        body.extend(b"\x01\x01")
        body.extend(len(objects).to_bytes(8, "big"))
        body.extend((0).to_bytes(8, "big"))
        body.extend(offset_table.to_bytes(8, "big"))
        info_path = self.app_path / "Info.plist"
        info_path.write_bytes(body)

        _, errors = verify._read_plist(info_path, "built Info.plist")

        self.assert_error_contains(errors, "cyclic container graph")

    def test_binary_plist_key_decode_has_cumulative_work_bound(self) -> None:
        encoded = plistlib.dumps(
            [{f"{index:02d}-" + "K" * 64: index} for index in range(4)],
            fmt=plistlib.FMT_BINARY,
            sort_keys=False,
        )

        with mock.patch.object(verify, "MAX_PLIST_DECODED_KEY_BYTES", 100):
            error = verify._binary_plist_duplicate_key_error(encoded)

        self.assertIsNotNone(error)
        assert error is not None
        self.assertIn("work bound", error)

    def test_reparse_point_attribute_is_treated_as_indirection(self) -> None:
        entry = mock.Mock()
        entry.is_symlink.return_value = False
        entry.stat.return_value = mock.Mock(
            st_mode=0,
            st_file_attributes=getattr(
                verify.stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x0400
            ),
        )

        self.assertTrue(verify._directory_entry_is_indirection(entry))

    def test_bundle_rejects_every_invalid_approved_icon_candidate(self) -> None:
        extra_candidate = self.app_path / "AppIcon60x60@3x.png"
        extra_candidate.mkdir()
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "not a regular file")

        extra_candidate.rmdir()
        extra_candidate.write_bytes(b"x")
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "PNG signature")

        valid_candidate = self.synthetic_png(width=180, height=180)
        corrupt_idat = self.synthetic_png(
            width=180,
            height=180,
            compressed_payload=b"definitely-not-zlib",
        )
        for label, encoded, expected_error in (
            (
                "wrong dimensions",
                self.synthetic_png(width=1, height=180),
                "dimensions",
            ),
            ("corrupt image data", corrupt_idat, "zlib stream"),
            (
                "non-opaque alpha",
                self.synthetic_png(
                    width=180, height=180, color_type=6, alpha_byte=254
                ),
                "non-opaque alpha",
            ),
        ):
            with self.subTest(label=label):
                extra_candidate.write_bytes(encoded)
                errors = verify.verify_bundle(
                    self.settings_path, self.source_privacy_path, self.expected
                )
                self.assert_error_contains(errors, expected_error)
        extra_candidate.write_bytes(valid_candidate)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assertEqual([], errors)

        extra_candidate.write_bytes(
            self.synthetic_png(
                width=180,
                height=180,
                color_type=6,
                alpha_byte=255,
                cgbi=True,
            )
        )
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assertEqual([], errors)

        cgbi_then_metadata = b"\x89PNG\r\n\x1a\n" + b"".join(
            (
                self.png_chunk(b"CgBI", b""),
                self.png_chunk(b"sRGB", b"\0"),
                self.png_chunk(
                    b"IHDR", struct.pack(">IIBBBBB", 180, 180, 8, 2, 0, 0, 0)
                ),
                self.png_chunk(b"IDAT", zlib.compress(bytes(180 * (180 * 3 + 1)))),
                self.png_chunk(b"IEND", b""),
            )
        )
        extra_candidate.write_bytes(cgbi_then_metadata)
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "IHDR")

    def test_bundle_bounds_root_icon_enumeration(self) -> None:
        with mock.patch.object(verify, "MAX_APP_ROOT_ENTRIES", 1):
            errors = verify.verify_bundle(
                self.settings_path, self.source_privacy_path, self.expected
            )

        self.assert_error_contains(errors, "entry verification limit")

    def test_bundle_accepts_same_primary_app_icon_ipad_metadata(self) -> None:
        info = self.read_info()
        info["CFBundleIcons~ipad"] = {
            "CFBundlePrimaryIcon": {
                "CFBundleIconName": "AppIcon",
                "CFBundleIconFiles": ["AppIcon76x76"],
            }
        }
        self.write_info(info)
        (self.app_path / "AppIcon76x76@2x.png").write_bytes(
            self.synthetic_png(width=152, height=152)
        )

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assertEqual([], errors)

    def test_bundle_rejects_app_icon_filename_prefix_collision(self) -> None:
        (self.app_path / "AppIcon60x60@2x.png").unlink()
        (self.app_path / "AppIcon60x60.png").write_bytes(
            self.synthetic_png(width=60, height=60)
        )
        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )
        self.assert_error_contains(errors, "required 2x")
        (self.app_path / "AppIcon60x60.png").unlink()
        (self.app_path / "AppIcon60x60@unexpected.png").write_bytes(
            self.synthetic_png()
        )

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assert_error_contains(errors, "AppIcon60x60")

    def test_bundle_rejects_icon_composer_artifacts(self) -> None:
        composer = self.app_path / "AppIcon.icon"
        composer.mkdir()

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assert_error_contains(errors, "forbidden artifact")

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
        real_scandir = verify.os.scandir

        def deny_app_bundle(path: object) -> object:
            if Path(path) == self.app_path:
                raise PermissionError("denied")
            return real_scandir(path)

        with mock.patch.object(verify.os, "scandir", side_effect=deny_app_bundle):
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

    def test_signed_bundle_reuses_icon_privacy_and_artifact_verification(self) -> None:
        (self.app_path / "_CodeSignature").mkdir()
        (self.app_path / "_CodeSignature" / "CodeResources").write_bytes(b"signed")
        (self.app_path / "embedded.mobileprovision").write_bytes(b"profile")
        framework_signature = (
            self.app_path
            / "Frameworks"
            / "whisper.framework"
            / "_CodeSignature"
        )
        framework_signature.mkdir(parents=True)
        (framework_signature / "CodeResources").write_bytes(b"signed framework")
        expected = verify.BundleExpectations(
            bundle_id=self.expected.bundle_id,
            marketing_version=self.expected.marketing_version,
            build_number=self.expected.build_number,
            api_url=self.expected.api_url,
            gateway_url=self.expected.gateway_url,
            deployment_target=self.expected.deployment_target,
        )

        self.assertEqual(
            [],
            verify.verify_signed_bundle(
                self.app_path, self.source_privacy_path, expected
            ),
        )

        unscoped_signature = self.app_path / "Resources" / "NotCode" / "_CodeSignature"
        unscoped_signature.mkdir(parents=True)
        (unscoped_signature / "CodeResources").write_bytes(b"not code")
        errors = verify.verify_signed_bundle(
            self.app_path, self.source_privacy_path, expected
        )
        self.assert_error_contains(errors, "_CodeSignature")
        (unscoped_signature / "CodeResources").unlink()
        unscoped_signature.rmdir()
        unscoped_signature.parent.rmdir()
        unscoped_signature.parent.parent.rmdir()

        (self.app_path / "AppIcon60x60@2x.png").write_bytes(b"corrupt")
        errors = verify.verify_signed_bundle(
            self.app_path, self.source_privacy_path, expected
        )
        self.assert_error_contains(errors, "invalid PNG signature")

    def test_unsigned_bundle_rejects_signed_artifacts(self) -> None:
        (self.app_path / "_CodeSignature").mkdir()
        (self.app_path / "_CodeSignature" / "CodeResources").write_bytes(b"signed")
        (self.app_path / "embedded.mobileprovision").write_bytes(b"profile")

        errors = verify.verify_bundle(
            self.settings_path, self.source_privacy_path, self.expected
        )

        self.assert_error_contains(errors, "embedded.mobileprovision")
        self.assert_error_contains(errors, "_CodeSignature")

    def test_preflight_cli_is_source_only(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(verify, "_source_app_icon_errors", return_value=[]),
            mock.patch.object(
                verify, "_approved_package_manifest_errors", return_value=[]
            ),
            mock.patch.object(
                verify,
                "_structured_project_from_plutil",
                side_effect=AssertionError("preflight invoked plutil"),
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = verify.main(
                ["preflight", "--repository-root", str(self.root.resolve())]
            )
        self.assertEqual(0, status)
        self.assertEqual("", stderr.getvalue())
        self.assertIn("preflight passed", stdout.getvalue())

    def test_cli_reports_success_without_absolute_paths(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        args = [
            "bundle",
            "--settings-json",
            str(self.settings_path),
            "--project-file",
            str(self.project_file),
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
            "--developer-dir",
            str(self.developer_dir),
            "--sdk-root",
            str(self.sdk_root),
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
            "--project-file",
            str(self.project_file),
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
            "--developer-dir",
            str(self.developer_dir),
            "--sdk-root",
            str(self.sdk_root),
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
