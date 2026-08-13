#!/usr/bin/env python3
"""Verify resolved unsigned iOS settings and the resulting Release .app.

This verifier intentionally stops at the unsigned-build boundary. It proves Xcode
configuration resolution and packaged resources; it does not prove signing,
provisioning, embedded entitlements, APNs delivery, or physical-device behavior.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import ipaddress
import json
import math
import os
import plistlib
import re
import shlex
import stat
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import urlsplit


MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_PROJECT_BYTES = 16 * 1024 * 1024
MAX_COMPILED_ASSET_BYTES = 64 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 100_000
MAX_PNG_CHUNKS = 4096
MAX_ASSET_CATALOG_ENTRIES = 4096
MAX_APP_ICON_SET_ENTRIES = 2
MAX_APP_ROOT_ENTRIES = 4096
MAX_SOURCE_RESOURCE_ENTRIES = 20_000
MAX_PROJECT_OBJECTS = 100_000
MAX_PROJECT_REFERENCES = 100_000
MAX_BUILD_SETTING_KEY_LENGTH = 512
MAX_RESOLVED_BUILD_SETTINGS = 4096
MAX_RESOLVED_PATH_LENGTH = 8192
MAX_RESOLVED_PATH_ENTRIES = 32
MAX_PLIST_OBJECTS = 100_000
MAX_XML_PLIST_DEPTH = 256
MAX_XML_PLIST_BYTES = 256 * 1024
MAX_PLIST_DECODED_KEY_BYTES = MAX_INPUT_BYTES
MAX_STRUCTURED_PROJECT_BYTES = 64 * 1024 * 1024
PLUTIL_TIMEOUT_SECONDS = 15
FIXTURE_NAME = "canonical_checkpoint.json"
ENTITLEMENTS_SUFFIX = "Sources/SentiPocketApp.entitlements"
INFO_PLIST_SUFFIX = "Sources/Info.plist"
APP_WRAPPER_NAME = "SentiPocketApp.app"
APP_EXECUTABLE_NAME = "SentiPocketApp"
APP_DISPLAY_NAME = "Senti Pocket"
APP_ICON_NAME = "AppIcon"
APP_ICON_FILENAME = "SentiPocketAppIcon.png"
APP_ICON_SHA256 = "495904bf6d5a1fc41cfebfaa1fe1e67cb20a3c6882194408406210c2097a1b8f"
PROJECT_SPEC_RELATIVE = Path("apps/SentiPocketApp/project.yml")
PROJECT_SPEC_SHA256 = "eedb5f582fa0025a457fd575260a77944f6f10a212a30b1cdb4131a44fd80e72"
APP_ICON_WIDTH = 1024
APP_ICON_HEIGHT = 1024
APP_ICON_CHANNELS = 3
APP_ICON_ROW_BYTES = APP_ICON_WIDTH * APP_ICON_CHANNELS
APP_ICON_SCANLINE_BYTES = APP_ICON_ROW_BYTES + 1
APP_ICON_INFLATED_BYTES = APP_ICON_SCANLINE_BYTES * APP_ICON_HEIGHT
APP_ICON_SET_RELATIVE = Path("Resources/Assets.xcassets/AppIcon.appiconset")
ASSET_CATALOG_RELATIVE = Path("Resources/Assets.xcassets")
APPROVED_RESOURCE_REFERENCES = frozenset(
    {
        PurePosixPath("Resources/Assets.xcassets"),
        PurePosixPath("Resources/PrivacyInfo.xcprivacy"),
        PurePosixPath(f"Resources/{FIXTURE_NAME}"),
    }
)
APPROVED_PACKAGE_PRODUCTS = frozenset(
    {
        "PocketContracts",
        "PocketCall",
        "PocketUI",
        "PocketReasoning",
        "PocketSyncClient",
        "PocketDialVoice",
        "PocketVoice",
    }
)
APPROVED_LOCAL_PACKAGE_PATHS = frozenset(
    f"../../packages/{product}" for product in APPROVED_PACKAGE_PRODUCTS
)
APPROVED_OPAQUE_GROUP_ROOT_PATH = "../.."
APPROVED_OPAQUE_GROUP_CHAIN = ("packages", "PocketUI", "DeviceUITests")
APPROVED_PACKAGE_MANIFEST_SHA256 = {
    "PocketCall": "e3731c3954a29409cf1867ede171cf939ecb863e0589b496f705d68baeb31923",
    "PocketContracts": "e779465a333d13948fb7d41ad56556b7a93bea5e7be72371908f9bcdc125698a",
    "PocketDialVoice": "952cdccd2cc1d9556506b20cace12e32387f2cba37697c17d7c512ac630ab672",
    "PocketReasoning": "36599039c7a777c9dd1fa5545a33677ef3bd8a670d1c5f026d95703d75cd7c33",
    "PocketSyncClient": "7423e66396fc78d3c5046dc1364f8402895566ef7c0c29d32f045a516f6b45c4",
    "PocketUI": "b2de263525ed7a590116d40716d673fa13b43ba4ffa5597532c1daacb111c491",
    "PocketVoice": "9523bb5a305632c5d462c963101009dc7f015235cce8ff6197e511873e351534",
}
SCHEME_RELATIVE = Path(
    "xcshareddata/xcschemes/SentiPocketAppRelease.xcscheme"
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COMPILED_ASSET_MAGIC = b"BOMStore"
APPROVED_PNG_CHUNKS = frozenset(
    {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"sRGB", b"gAMA", b"pHYs"}
)
UNIQUE_PNG_CHUNKS = APPROVED_PNG_CHUNKS - {b"IDAT"}
FORBIDDEN_BASENAMES = frozenset(
    {
        FIXTURE_NAME.lower(),
        "credentials.json",
        "ggml-base.en.bin",
        "embedded.mobileprovision",
        "_codesignature",
    }
)
FORBIDDEN_SUFFIXES = (
    ".icon",
    ".p8",
    ".p12",
    ".pfx",
    ".pkcs12",
    ".mobileprovision",
    ".provisionprofile",
    ".pem",
    ".key",
    ".credentials.json",
    ".gguf",
    ".tflite",
    ".litertlm",
    ".task",
)
MACH_O_64_LE_MAGIC = b"\xcf\xfa\xed\xfe"
MACH_O_64_HEADER_SIZE = 32
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
LC_SEGMENT_64 = 0x19
SEGMENT_COMMAND_64_SIZE = 72
SECTION_64_SIZE = 80
MAX_LOAD_COMMANDS = 4096
MAX_LOAD_COMMAND_BYTES = 16 * 1024 * 1024
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
MARKETING_VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
BUILD_NUMBER_RE = re.compile(r"^[1-9][0-9]*$")
DNS_LABEL_RE = re.compile(r"^(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9])$")
SWIFT_CONDITION_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SWIFT_DEBUG_FLAG_RE = re.compile(r"(?:^|=)-D=?DEBUG(?:$|=)")
BUILD_SETTING_KEY_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\[[A-Za-z_][A-Za-z0-9_]*=[^\[\]\x00-\x1f]+\])*$"
)
APPROVED_BUILT_ICON_SIZES = {
    "AppIcon20x20": 20.0,
    "AppIcon29x29": 29.0,
    "AppIcon40x40": 40.0,
    "AppIcon60x60": 60.0,
    "AppIcon76x76": 76.0,
    "AppIcon83.5x83.5": 83.5,
}
PBX_ID_RE = re.compile(r"^[A-F0-9]{24}$")
SENSITIVE_SETTING_KEYS = frozenset({"SENTI_API_URL", "SENTI_GATEWAY_URL"})
EMPTY_EXECUTION_OVERRIDE_KEYS = frozenset(
    {
        "C_COMPILER_LAUNCHER",
        "CXX_COMPILER_LAUNCHER",
        "SWIFT_COMPILER_LAUNCHER",
    }
)
SWIFT_TOOL_SELECTORS = {
    "SWIFT_EXEC": frozenset({"swiftc"}),
    "SWIFT_DRIVER_SWIFT_EXEC": frozenset({"swift"}),
    "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": frozenset({"swift-frontend"}),
}
EMPTY_RELEASE_FLAG_KEYS = frozenset(
    {
        "ALL_OTHER_LDFLAGS",
        "ALTERNATE_LINKER",
        "ALTERNATE_LINKER_PATH",
        "CLANG_ALTERNATE_LINKER",
        "CLANG_ALTERNATE_LINKER_PATH",
        "LD_FLAGS",
        "OTHER_SWIFT_FLAGS",
        "OTHER_CFLAGS",
        "OTHER_CPLUSPLUSFLAGS",
        "OTHER_LDFLAGS",
        "OTHER_LIBTOOLFLAGS",
        "PRODUCT_SPECIFIC_LDFLAGS",
        "SECTORDER_FLAGS",
        "SWIFTC_ALTERNATE_LINKER",
        "SWIFTC_ALTERNATE_LINKER_PATH",
        "WARNING_CFLAGS",
    }
)
TRUSTED_OBJC_RUNTIME_ARGS = {
    "LD_OBJC_RUNTIME_ARGS": "-fobjc-link-runtime",
    "LD_OBJC_RUNTIME_ARGS_clang": "-fobjc-link-runtime",
    "LD_OBJC_RUNTIME_ARGS_swiftc": "-link-objc-runtime",
}
SWIFT_RESPONSE_FILE_KEY = "SWIFT_RESPONSE_FILE_PATH_normal_arm64"
CANONICAL_SWIFT_RESPONSE_FILE_VALUE = (
    "$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))"
)
OPTIONAL_EMPTY_RESOLVED_SETTINGS = frozenset(
    {
        "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
        "ASSETCATALOG_OTHER_FLAGS",
        "COMPILATION_CACHE_PLUGIN_PATH",
        "INCLUDED_SOURCE_FILE_NAMES",
        "SWIFT_RESPONSE_FILE_PATH",
        "SWIFT_TOOLCHAIN_FLAGS",
    }
)
RESOURCE_POLICY_SETTING_BASES = frozenset(
    {
        "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
        "ASSETCATALOG_OTHER_FLAGS",
        "EXCLUDED_SOURCE_FILE_NAMES",
        "INCLUDED_SOURCE_FILE_NAMES",
    }
)
STATIC_EXECUTION_SETTINGS = {
    "COMPILATION_CACHE_ENABLE_PLUGIN": "NO",
    "COMPILATION_CACHE_PLUGIN_PATH": "",
    "SWIFT_ENABLE_COMPILE_CACHE": "NO",
}
EMPTY_INFO_PLIST_PREPROCESSOR_KEYS = frozenset(
    {
        "INFOPLIST_OTHER_PREPROCESSOR_FLAGS",
        "INFOPLIST_PREFIX_HEADER",
        "INFOPLIST_PREPROCESSOR_DEFINITIONS",
    }
)
TOOL_SELECTOR_BASENAMES = {
    "CC": frozenset({"clang"}),
    "CXX": frozenset({"clang++"}),
    "CPLUSPLUS": frozenset({"clang++"}),
    "OBJCC": frozenset({"clang"}),
    "OBJCPLUSPLUS": frozenset({"clang++"}),
    "LD": frozenset({"clang", "ld"}),
    "LDPLUSPLUS": frozenset({"clang++", "ld"}),
    "LIBTOOL": frozenset({"libtool"}),
}
PROJECT_EXECUTION_OVERRIDE_KEYS = frozenset(
    {
        *EMPTY_EXECUTION_OVERRIDE_KEYS,
        *SWIFT_TOOL_SELECTORS,
        *EMPTY_RELEASE_FLAG_KEYS,
        *EMPTY_INFO_PLIST_PREPROCESSOR_KEYS,
        *TOOL_SELECTOR_BASENAMES,
        "DEVELOPER_DIR",
        "DT_TOOLCHAIN_DIR",
        "TOOLCHAIN_DIR",
        "TOOLCHAINS",
        "SDKROOT",
        "PATH",
        "INFOPLIST_PREPROCESS",
        "ASSETCATALOG_EXEC",
        "CODESIGN",
        "CODESIGN_ALLOCATE",
        *STATIC_EXECUTION_SETTINGS,
        "LD_OBJC_RUNTIME_ARGS",
        "SWIFT_TOOLS_DIR",
        "SWIFT_TOOLCHAIN_FLAGS",
        "SWIFT_RESPONSE_FILE_PATH",
        "SWIFT_USE_INTEGRATED_DRIVER",
        *OPTIONAL_EMPTY_RESOLVED_SETTINGS,
        "EXCLUDED_SOURCE_FILE_NAMES",
    }
)


class DuplicateJSONKeyError(ValueError):
    """Raised when security evidence contains an ambiguous JSON object."""


class NonstandardJSONConstantError(ValueError):
    """Raised when JSON evidence contains NaN or infinity."""


@dataclass(frozen=True)
class Expectations:
    target: str
    configuration: str
    aps_environment: str
    bundle_id: str
    marketing_version: str
    build_number: str
    api_url: str
    gateway_url: str
    deployment_target: str
    products_root: Path
    project_file: Path
    developer_dir: PurePosixPath
    sdk_root: PurePosixPath


@dataclass(frozen=True)
class BundleExpectations:
    bundle_id: str
    marketing_version: str
    build_number: str
    api_url: str
    gateway_url: str
    deployment_target: str


def _safe_repr(value: Any) -> str:
    rendered = repr(value)
    if len(rendered) > 180:
        return rendered[:177] + "..."
    return rendered


def _safe_setting_key_label(key: Any) -> str:
    if (
        isinstance(key, str)
        and len(key) <= 256
        and key.isascii()
        and all(0x20 <= ord(character) <= 0x7E for character in key)
    ):
        return key
    if isinstance(key, str):
        encoded = key.encode("utf-8", errors="surrogatepass")
        length = len(key)
    else:
        encoded = repr(type(key).__name__).encode("ascii")
        length = -1
    digest = hashlib.sha256(encoded).hexdigest()[:16]
    return f"<invalid-setting-key length={length} sha256={digest}>"


def _resolved_absolute_path(value: Any) -> Path | None:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 4096
        or any(ord(character) < 0x20 for character in value)
    ):
        return None
    candidate = Path(value)
    if not candidate.is_absolute():
        return None
    try:
        return candidate.resolve(strict=False)
    except (OSError, RuntimeError, ValueError):
        return None


def _stat_fingerprint(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _stat_identity(value: os.stat_result) -> tuple[int, int, int]:
    return (value.st_dev, value.st_ino, value.st_size)


def _stat_is_indirection(value: os.stat_result) -> bool:
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x0400)
    return stat.S_ISLNK(value.st_mode) or bool(
        getattr(value, "st_file_attributes", 0) & reparse_flag
    )


def _directory_entry_is_indirection(entry: os.DirEntry[str]) -> bool:
    return entry.is_symlink() or _stat_is_indirection(
        entry.stat(follow_symlinks=False)
    )


def _open_regular_fd(
    path: Path, label: str
) -> tuple[int | None, os.stat_result | None, list[str]]:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        initial_stat = path.lstat()
        if _stat_is_indirection(initial_stat) or not stat.S_ISREG(initial_stat.st_mode):
            return None, None, [f"{label} is not a regular file"]
        descriptor = os.open(path, flags)
        opened_stat = os.fstat(descriptor)
        path_stat = path.lstat()
        if (
            _stat_is_indirection(path_stat)
            or not stat.S_ISREG(opened_stat.st_mode)
            or not stat.S_ISREG(path_stat.st_mode)
            or _stat_fingerprint(initial_stat) != _stat_fingerprint(path_stat)
            or _stat_identity(opened_stat) != _stat_identity(path_stat)
        ):
            os.close(descriptor)
            descriptor = -1
            return None, None, [f"{label} is not a regular file or changed before opening"]
        return descriptor, opened_stat, []
    except FileNotFoundError:
        if descriptor >= 0:
            os.close(descriptor)
        return None, None, [f"{label} is not a regular file"]
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
        return None, None, [f"{label} could not be opened: {type(exc).__name__}"]


def _opened_file_changed(
    path: Path, opened_stat: os.stat_result, final_stat: os.stat_result
) -> bool:
    try:
        path_stat = path.lstat()
    except OSError:
        return True
    return (
        _stat_is_indirection(path_stat)
        or not stat.S_ISREG(path_stat.st_mode)
        or _stat_fingerprint(opened_stat) != _stat_fingerprint(final_stat)
        or _stat_identity(opened_stat) != _stat_identity(path_stat)
    )


def _read_bounded_regular_file(
    path: Path,
    label: str,
    *,
    maximum_bytes: int,
    minimum_bytes: int = 0,
) -> tuple[bytes | None, list[str]]:
    descriptor, opened_stat, errors = _open_regular_fd(path, label)
    if descriptor is None or opened_stat is None:
        return None, errors
    try:
        if opened_stat.st_size < minimum_bytes:
            return None, [f"{label} has an invalid bounded size"]
        if opened_stat.st_size > maximum_bytes:
            return None, [f"{label} exceeds the {maximum_bytes}-byte verification limit"]
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            encoded = stream.read(maximum_bytes + 1)
            final_stat = os.fstat(stream.fileno())
        if len(encoded) > maximum_bytes:
            return None, [f"{label} exceeds the {maximum_bytes}-byte verification limit"]
        if _opened_file_changed(path, opened_stat, final_stat):
            return None, [f"{label} changed during verification"]
        return encoded, []
    except OSError as exc:
        return None, [f"{label} could not be read: {type(exc).__name__}"]
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _https_origin_error(name: str, value: str) -> str | None:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 2048
        or any(ord(character) < 0x21 or ord(character) > 0x7E for character in value)
    ):
        return f"{name} must be a bounded HTTPS origin"
    if "?" in value or "#" in value:
        return f"{name} must not contain a query or fragment delimiter"
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return f"{name} must be a valid HTTPS origin"
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        return f"{name} must be an HTTPS origin without credentials, path, query, or fragment"
    if port == 0:
        return f"{name} port must be between 1 and 65535"
    hostname = parsed.hostname
    if hostname is None or len(hostname) > 253:
        return f"{name} must use a bounded ASCII DNS or IPv4 host"
    normalized_authority = hostname if port is None else f"{hostname}:{port}"
    if parsed.netloc.lower() != normalized_authority.lower():
        return f"{name} contains an invalid HTTPS authority"
    if hostname.replace(".", "").isdigit():
        try:
            parsed_ip = ipaddress.ip_address(hostname)
        except ValueError:
            return f"{name} contains an invalid IPv4 address"
        if not isinstance(parsed_ip, ipaddress.IPv4Address):
            return f"{name} must use an ASCII DNS or IPv4 host"
    else:
        labels = hostname.split(".")
        if len(labels) < 2 or any(
            not DNS_LABEL_RE.fullmatch(label) for label in labels
        ):
            return f"{name} contains an invalid DNS host"
    return None


def validate_expectations(expected: Expectations) -> list[str]:
    errors: list[str] = []
    if expected.target != "SentiPocketApp":
        errors.append("target must be exactly SentiPocketApp")
    if expected.configuration not in ("Debug", "Release"):
        errors.append("configuration must be exactly Debug or Release")
    required_aps = "development" if expected.configuration == "Debug" else "production"
    if expected.aps_environment != required_aps:
        errors.append(
            f"{expected.configuration} must use aps_environment={required_aps} for this unsigned gate"
        )
    if len(expected.bundle_id) > 255 or not BUNDLE_ID_RE.fullmatch(expected.bundle_id):
        errors.append("bundle_id must be a bounded reverse-DNS identifier")
    if (
        not isinstance(expected.marketing_version, str)
        or len(expected.marketing_version) > 64
        or not MARKETING_VERSION_RE.fullmatch(expected.marketing_version)
    ):
        errors.append("marketing_version must contain two or three numeric components")
    if (
        not isinstance(expected.build_number, str)
        or len(expected.build_number) > 64
        or not BUILD_NUMBER_RE.fullmatch(expected.build_number)
    ):
        errors.append("build_number must be a positive integer")
    if (
        not isinstance(expected.deployment_target, str)
        or len(expected.deployment_target) > 32
        or not MARKETING_VERSION_RE.fullmatch(expected.deployment_target)
    ):
        errors.append("deployment_target must contain two or three numeric components")
    for name, value in (
        ("api_url", expected.api_url),
        ("gateway_url", expected.gateway_url),
    ):
        error = _https_origin_error(name, value)
        if error:
            errors.append(error)
    products_root = expected.products_root
    if (
        not isinstance(products_root, Path)
        or not products_root.is_absolute()
        or products_root == Path(products_root.anchor)
        or any(ord(character) < 0x20 for character in str(products_root))
    ):
        errors.append("products_root must be an absolute path below a named directory")
    project_file = expected.project_file
    if (
        not isinstance(project_file, Path)
        or project_file.name != "project.pbxproj"
        or project_file.parent.name != "SentiPocketApp.xcodeproj"
    ):
        errors.append("project_file must name SentiPocketApp.xcodeproj/project.pbxproj")
    developer_dir = expected.developer_dir
    if (
        not isinstance(developer_dir, PurePosixPath)
        or not developer_dir.is_absolute()
        or len(developer_dir.parts) < 3
        or developer_dir.parts[-2:] != ("Contents", "Developer")
        or ".." in developer_dir.parts
        or any(ord(character) < 0x20 for character in str(developer_dir))
    ):
        errors.append(
            "developer_dir must be an absolute selected Xcode Contents/Developer path"
        )
    sdk_root = expected.sdk_root
    if (
        not isinstance(sdk_root, PurePosixPath)
        or sdk_root.parent
        != developer_dir / "Platforms/iPhoneOS.platform/Developer/SDKs"
        or not re.fullmatch(
            r"iPhoneOS(?:[0-9]+(?:\.[0-9]+)*)?\.sdk", sdk_root.name
        )
    ):
        errors.append("sdk_root must be the selected Xcode iPhoneOS SDK path")
    return errors


def validate_bundle_expectations(expected: BundleExpectations) -> list[str]:
    errors: list[str] = []
    if len(expected.bundle_id) > 255 or not BUNDLE_ID_RE.fullmatch(expected.bundle_id):
        errors.append("bundle_id must be a bounded reverse-DNS identifier")
    if not MARKETING_VERSION_RE.fullmatch(expected.marketing_version):
        errors.append("marketing_version must contain two or three numeric components")
    if not BUILD_NUMBER_RE.fullmatch(expected.build_number):
        errors.append("build_number must be a positive integer")
    if not MARKETING_VERSION_RE.fullmatch(expected.deployment_target):
        errors.append("deployment_target must contain two or three numeric components")
    for name, value in (
        ("api_url", expected.api_url),
        ("gateway_url", expected.gateway_url),
    ):
        error = _https_origin_error(name, value)
        if error:
            errors.append(error)
    return errors


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    decoded: dict[str, Any] = {}
    for key, value in pairs:
        if key in decoded:
            raise DuplicateJSONKeyError(key)
        decoded[key] = value
    return decoded


def _reject_nonstandard_json_constant(value: str) -> None:
    raise NonstandardJSONConstantError(value)


def _decode_json(encoded: bytes, label: str) -> tuple[Any | None, list[str]]:
    try:
        return (
            json.loads(
                encoded.decode("utf-8"),
                object_pairs_hook=_reject_duplicate_json_keys,
                parse_constant=_reject_nonstandard_json_constant,
            ),
            [],
        )
    except DuplicateJSONKeyError:
        return None, [f"{label} contains duplicate object keys"]
    except NonstandardJSONConstantError:
        return None, [f"{label} contains a nonstandard numeric constant"]
    except (UnicodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        return None, [f"{label} could not be decoded: {type(exc).__name__}"]


def _read_json(
    path: Path, label: str = "settings JSON"
) -> tuple[Any | None, list[str]]:
    encoded, read_errors = _read_bounded_regular_file(
        path, label, maximum_bytes=MAX_INPUT_BYTES
    )
    if encoded is None:
        return None, read_errors
    return _decode_json(encoded, label)


def _bounded_directory_entries(
    path: Path, limit: int, label: str
) -> tuple[list[os.DirEntry[str]], list[str]]:
    entries: list[os.DirEntry[str]] = []
    try:
        with os.scandir(path) as iterator:
            for entry in iterator:
                if len(entries) >= limit:
                    return [], [
                        f"{label} exceeds the {limit}-entry verification limit"
                    ]
                entries.append(entry)
    except OSError as exc:
        return [], [f"{label} could not be listed: {type(exc).__name__}"]
    return entries, []


def _source_resource_tree_errors(resources: Path) -> list[str]:
    pending = [resources]
    entry_count = 0
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    entry_count += 1
                    if entry_count > MAX_SOURCE_RESOURCE_ENTRIES:
                        return [
                            "source Resources tree exceeds the "
                            f"{MAX_SOURCE_RESOURCE_ENTRIES}-entry verification limit"
                        ]
                    relative = Path(entry.path).relative_to(resources).as_posix()
                    if _directory_entry_is_indirection(entry):
                        return [
                            "source Resources contains a symlink or reparse point: "
                            f"{_safe_repr(relative)}"
                        ]
                    folded_relative = relative.casefold()
                    if (
                        entry.name.casefold().endswith(".appiconset")
                        and folded_relative
                        != "assets.xcassets/appicon.appiconset"
                    ):
                        return [
                            "source asset catalog contains an alternate AppIcon set"
                        ]
                    if (
                        entry.name.casefold().endswith(".xcassets")
                        and folded_relative != "assets.xcassets"
                    ):
                        return ["source Resources contains an alternate asset catalog"]
                    if entry.name.casefold().endswith(".icon"):
                        return [
                            "source Resources contains an unverified Icon Composer input"
                        ]
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(Path(entry.path))
        except OSError as exc:
            return [
                "source Resources tree could not be inspected: "
                f"{type(exc).__name__}"
            ]
    return []


def _png_image_data_errors(
    idat_payloads: Sequence[bytes],
    *,
    width: int,
    height: int,
    channels: int,
    label: str,
    exact_scanline_description: str,
    require_opaque_alpha: bool,
    wbits: int = zlib.MAX_WBITS,
) -> list[str]:
    if (
        not 1 <= width <= APP_ICON_WIDTH
        or height != width
        or channels not in {3, 4}
    ):
        return [f"{label} has unsafe decoded dimensions or channel count"]
    row_bytes = width * channels
    scanline_bytes = row_bytes + 1
    inflated_bytes = scanline_bytes * height
    inflater = zlib.decompressobj(wbits)
    decoded = bytearray()
    try:
        for payload in idat_payloads:
            remaining = inflated_bytes + 1 - len(decoded)
            if remaining <= 0:
                return [f"{label} inflates beyond the expected image size"]
            decoded.extend(inflater.decompress(payload, remaining))
            if inflater.unconsumed_tail:
                return [f"{label} inflates beyond the expected image size"]
        flush_limit = max(1, inflated_bytes + 1 - len(decoded))
        decoded.extend(inflater.flush(flush_limit))
    except (zlib.error, ValueError):
        return [f"{label} image data is not a valid zlib stream"]

    errors: list[str] = []
    if len(decoded) > inflated_bytes:
        errors.append(f"{label} inflates beyond the expected image size")
    elif len(decoded) != inflated_bytes:
        errors.append(f"{label} does not contain exactly {exact_scanline_description}")
    if not inflater.eof:
        errors.append(f"{label} image data ends before the zlib stream")
    if inflater.unused_data or inflater.unconsumed_tail:
        errors.append(f"{label} contains trailing compressed image data")
    if len(decoded) != inflated_bytes:
        return errors

    filter_offsets = range(0, inflated_bytes, scanline_bytes)
    if not require_opaque_alpha:
        if any(decoded[offset] > 4 for offset in filter_offsets):
            errors.append(f"{label} contains an invalid scanline filter")
        return errors

    previous = bytearray(row_bytes)
    for row_index in range(height):
        offset = row_index * scanline_bytes
        filter_type = decoded[offset]
        if filter_type > 4:
            errors.append(f"{label} contains an invalid scanline filter")
            break
        row = bytearray(decoded[offset + 1 : offset + scanline_bytes])
        for index, encoded_byte in enumerate(row):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                left_distance = abs(estimate - left)
                above_distance = abs(estimate - above)
                upper_left_distance = abs(estimate - upper_left)
                if left_distance <= above_distance and left_distance <= upper_left_distance:
                    predictor = left
                elif above_distance <= upper_left_distance:
                    predictor = above
                else:
                    predictor = upper_left
            else:
                predictor = 0
            row[index] = (encoded_byte + predictor) & 0xFF
        if require_opaque_alpha and any(
            row[index] != 0xFF for index in range(3, row_bytes, channels)
        ):
            errors.append(f"{label} contains non-opaque alpha pixels")
            break
        previous = row
    return errors


def _app_icon_image_data_errors(idat_payloads: Sequence[bytes]) -> list[str]:
    return _png_image_data_errors(
        idat_payloads,
        width=APP_ICON_WIDTH,
        height=APP_ICON_HEIGHT,
        channels=APP_ICON_CHANNELS,
        label="source AppIcon PNG",
        exact_scanline_description="1024 RGB scanlines",
        require_opaque_alpha=False,
    )


def _source_app_icon_png_errors(path: Path) -> list[str]:
    encoded, read_errors = _read_bounded_regular_file(
        path,
        "source AppIcon PNG",
        maximum_bytes=MAX_INPUT_BYTES,
        minimum_bytes=1,
    )
    if encoded is None:
        return read_errors

    if not encoded.startswith(PNG_SIGNATURE):
        return ["source AppIcon PNG has an invalid signature"]

    errors: list[str] = []
    offset = len(PNG_SIGNATURE)
    chunk_count = 0
    saw_ihdr = False
    saw_idat = False
    saw_iend = False
    idat_closed = False
    idat_payloads: list[bytes] = []
    seen_unique_chunks: set[bytes] = set()
    while offset < len(encoded):
        chunk_count += 1
        if chunk_count > MAX_PNG_CHUNKS:
            errors.append("source AppIcon PNG exceeds the chunk verification limit")
            break
        if len(encoded) - offset < 12:
            errors.append("source AppIcon PNG has a truncated chunk envelope")
            break

        chunk_size = struct.unpack_from(">I", encoded, offset)[0]
        chunk_end = offset + 12 + chunk_size
        if chunk_end > len(encoded):
            errors.append("source AppIcon PNG chunk exceeds the file")
            break
        chunk_type = encoded[offset + 4 : offset + 8]
        payload = encoded[offset + 8 : offset + 8 + chunk_size]
        recorded_crc = struct.unpack_from(">I", encoded, offset + 8 + chunk_size)[0]
        calculated_crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        if recorded_crc != calculated_crc:
            errors.append("source AppIcon PNG contains an invalid chunk checksum")
            break
        if len(chunk_type) != 4 or any(
            byte not in range(ord("A"), ord("Z") + 1)
            and byte not in range(ord("a"), ord("z") + 1)
            for byte in chunk_type
        ):
            errors.append("source AppIcon PNG contains an invalid chunk type")
            break

        if chunk_type not in APPROVED_PNG_CHUNKS:
            if chunk_type[0] & 0x20 == 0:
                errors.append("source AppIcon PNG contains an unknown critical chunk")
            else:
                errors.append(
                    "source AppIcon PNG contains an unapproved ancillary chunk"
                )
        if chunk_type in UNIQUE_PNG_CHUNKS:
            if chunk_type in seen_unique_chunks:
                errors.append("source AppIcon PNG contains a duplicate singleton chunk")
            seen_unique_chunks.add(chunk_type)

        if saw_idat and chunk_type not in (b"IDAT", b"IEND"):
            idat_closed = True
        if saw_idat and chunk_type in {b"PLTE", b"sRGB", b"gAMA", b"pHYs"}:
            errors.append("source AppIcon PNG metadata chunks must precede IDAT")
        if chunk_count == 1 and chunk_type != b"IHDR":
            errors.append("source AppIcon PNG must begin with IHDR")
        if chunk_type == b"IHDR":
            if saw_ihdr or chunk_size != 13:
                errors.append("source AppIcon PNG has an invalid IHDR")
            else:
                saw_ihdr = True
                (
                    width,
                    height,
                    bit_depth,
                    color_type,
                    compression,
                    filtering,
                    interlace,
                ) = struct.unpack(">IIBBBBB", payload)
                if (width, height) != (APP_ICON_WIDTH, APP_ICON_HEIGHT):
                    errors.append("source AppIcon PNG must be exactly 1024x1024")
                if bit_depth != 8 or color_type != 2:
                    errors.append("source AppIcon PNG must be opaque 8-bit RGB")
                if (compression, filtering, interlace) != (0, 0, 0):
                    errors.append(
                        "source AppIcon PNG uses unsupported encoding methods"
                    )
        elif chunk_type == b"IDAT":
            if idat_closed:
                errors.append("source AppIcon PNG IDAT chunks must be consecutive")
            if not payload:
                errors.append("source AppIcon PNG contains an empty IDAT chunk")
            saw_idat = True
            idat_payloads.append(payload)
        elif chunk_type == b"PLTE":
            if not 3 <= chunk_size <= 768 or chunk_size % 3 != 0:
                errors.append("source AppIcon PNG contains an invalid PLTE chunk")
        elif chunk_type == b"sRGB":
            if chunk_size != 1 or payload[0] > 3:
                errors.append("source AppIcon PNG contains an invalid sRGB chunk")
        elif chunk_type == b"gAMA":
            if chunk_size != 4 or struct.unpack(">I", payload)[0] == 0:
                errors.append("source AppIcon PNG contains an invalid gAMA chunk")
        elif chunk_type == b"pHYs":
            if chunk_size != 9 or payload[-1] not in (0, 1):
                errors.append("source AppIcon PNG contains an invalid pHYs chunk")
        elif chunk_type == b"tRNS":
            errors.append("source AppIcon PNG must not declare transparency")
        elif chunk_type == b"acTL":
            errors.append("source AppIcon PNG must not be animated")
        elif chunk_type == b"IEND":
            if chunk_size != 0:
                errors.append("source AppIcon PNG has an invalid IEND")
            saw_iend = True
            if chunk_end != len(encoded):
                errors.append("source AppIcon PNG contains bytes after IEND")
            offset = chunk_end
            break
        offset = chunk_end

    if not saw_ihdr:
        errors.append("source AppIcon PNG is missing IHDR")
    if not saw_idat:
        errors.append("source AppIcon PNG is missing image data")
    if not saw_iend:
        errors.append("source AppIcon PNG is missing IEND")
    if idat_payloads:
        errors.extend(_app_icon_image_data_errors(idat_payloads))
    if not hmac.compare_digest(hashlib.sha256(encoded).hexdigest(), APP_ICON_SHA256):
        errors.append("source AppIcon PNG does not match the approved artwork digest")
    return errors


def _source_app_icon_errors(project_file: Path) -> list[str]:
    app_root = project_file.parent.parent
    resources = app_root / "Resources"
    catalog = app_root / ASSET_CATALOG_RELATIVE
    icon_set = app_root / APP_ICON_SET_RELATIVE
    errors: list[str] = []
    for path, label in (
        (resources, "Resources directory"),
        (catalog, "asset catalog"),
        (icon_set, "AppIcon set"),
    ):
        try:
            path_stat = path.lstat()
            if _stat_is_indirection(path_stat) or not stat.S_ISDIR(path_stat.st_mode):
                errors.append(f"source {label} is not a regular directory")
        except OSError as exc:
            errors.append(
                f"source {label} could not be inspected: {type(exc).__name__}"
            )
    if errors:
        return errors

    errors.extend(_source_resource_tree_errors(resources))
    if errors:
        return errors

    icon_set_entries, icon_set_listing_errors = _bounded_directory_entries(
        icon_set, MAX_APP_ICON_SET_ENTRIES, "source AppIcon set"
    )
    catalog_entries, catalog_listing_errors = _bounded_directory_entries(
        catalog, MAX_ASSET_CATALOG_ENTRIES, "source asset catalog"
    )
    errors.extend(icon_set_listing_errors)
    errors.extend(catalog_listing_errors)
    if icon_set_listing_errors or catalog_listing_errors:
        return errors
    expected_icon_set_entries = {"Contents.json", APP_ICON_FILENAME}
    if {entry.name for entry in icon_set_entries} != expected_icon_set_entries:
        errors.append(
            "source AppIcon set must contain exactly Contents.json and its PNG"
        )
    if any(
        entry.name.casefold().endswith(".appiconset")
        and entry.name != "AppIcon.appiconset"
        for entry in catalog_entries
    ):
        errors.append("source asset catalog contains an alternate AppIcon set")

    catalog_contents, catalog_errors = _read_json(
        catalog / "Contents.json", "asset catalog Contents.json"
    )
    icon_contents, icon_errors = _read_json(
        icon_set / "Contents.json", "AppIcon Contents.json"
    )
    errors.extend(catalog_errors)
    errors.extend(icon_errors)
    expected_info = {"author": "xcode", "version": 1}
    if catalog_contents is not None and not _type_sensitive_plist_equal(
        catalog_contents, {"info": expected_info}
    ):
        errors.append("asset catalog Contents.json does not match the approved schema")
    if icon_contents is not None and not _type_sensitive_plist_equal(
        icon_contents,
        {
            "images": [
                {
                    "filename": APP_ICON_FILENAME,
                    "idiom": "universal",
                    "platform": "ios",
                    "size": "1024x1024",
                }
            ],
            "info": expected_info,
        },
    ):
        errors.append("AppIcon Contents.json does not match the approved schema")
    errors.extend(_source_app_icon_png_errors(icon_set / APP_ICON_FILENAME))
    return errors


def _structured_project_from_plutil(
    path: Path, expected_bytes: bytes
) -> tuple[dict[str, Any] | None, list[str]]:
    if sys.platform != "darwin":
        return None, [
            "generated Xcode project structured verification requires macOS plutil"
        ]

    try:
        with tempfile.TemporaryDirectory(prefix="senti-pbx-") as temporary:
            input_path = Path(temporary) / "project.pbxproj"
            output_path = Path(temporary) / "project.json"
            input_path.write_bytes(expected_bytes)
            completed = subprocess.run(
                [
                    "/usr/bin/plutil",
                    "-convert",
                    "json",
                    "-o",
                    str(output_path),
                    "--",
                    str(input_path),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=PLUTIL_TIMEOUT_SECONDS,
            )
            if completed.returncode != 0:
                return None, ["generated Xcode project could not be parsed by plutil"]
            structured_bytes, output_errors = _read_bounded_regular_file(
                output_path,
                "generated Xcode project conversion",
                maximum_bytes=MAX_STRUCTURED_PROJECT_BYTES,
            )
            if structured_bytes is None:
                return None, output_errors

        current_bytes, current_errors = _read_bounded_regular_file(
            path,
            "generated Xcode project",
            maximum_bytes=MAX_PROJECT_BYTES,
        )
        if current_bytes is None:
            return None, current_errors
        if current_bytes != expected_bytes:
            return None, ["generated Xcode project changed during verification"]
    except subprocess.TimeoutExpired:
        return None, ["generated Xcode project plutil conversion timed out"]
    except OSError as exc:
        return None, [
            f"generated Xcode project conversion failed: {type(exc).__name__}"
        ]

    payload, errors = _decode_json(
        structured_bytes, "generated Xcode project conversion"
    )
    if errors:
        return None, errors
    if not isinstance(payload, dict) or not all(
        isinstance(key, str) for key in payload
    ):
        return None, ["generated Xcode project root must be a string-keyed dictionary"]
    return payload, []


def _pbx_reference_list(value: Any, *, allow_empty: bool = True) -> list[str] | None:
    if (
        not isinstance(value, list)
        or len(value) > MAX_PROJECT_REFERENCES
        or (not allow_empty and not value)
        or any(
            not isinstance(reference, str) or not PBX_ID_RE.fullmatch(reference)
            for reference in value
        )
        or len(set(value)) != len(value)
    ):
        return None
    return value


def _safe_project_path(value: Any, *, allow_empty: bool) -> PurePosixPath | None:
    if value in (None, "") and allow_empty:
        return PurePosixPath()
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 4096
        or "\\" in value
        or any(ord(character) < 0x20 for character in value)
    ):
        return None
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or any(part in ("", ".", "..") for part in candidate.parts):
        return None
    return candidate


def _build_setting_base(key: str) -> str | None:
    if (
        len(key) > MAX_BUILD_SETTING_KEY_LENGTH
        or not key.isascii()
        or not BUILD_SETTING_KEY_RE.fullmatch(key)
    ):
        return None
    return key.partition("[")[0]


def _is_execution_override_base(base: str) -> bool:
    return (
        base in PROJECT_EXECUTION_OVERRIDE_KEYS
        or any(
            base.startswith(f"{flag_key}_")
            for flag_key in EMPTY_RELEASE_FLAG_KEYS
        )
        or (base.startswith("SWIFT_EXEC_") and base.endswith("_EXEC"))
        or (base.startswith("SWIFT_DRIVER_") and base.endswith("_EXEC"))
        or base.startswith("SWIFT_RESPONSE_FILE_PATH_")
        or base.startswith("SWIFT_TOOLCHAIN_FLAGS_")
        or base.startswith("LD_OBJC_RUNTIME_ARGS_")
        or any(
            base.startswith(f"{policy_key}_")
            for policy_key in RESOURCE_POLICY_SETTING_BASES
        )
        or base.endswith("_COMPILER_LAUNCHER")
    )


def _is_execution_override_key(key: str) -> bool:
    base = _build_setting_base(key)
    return base is not None and _is_execution_override_base(base)


def _safe_resolved_tool_selector(
    value: Any,
    basenames: frozenset[str],
    developer_dir: PurePosixPath,
) -> bool:
    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    if value in basenames:
        return True
    candidate = PurePosixPath(value)
    approved_directories = {
        developer_dir / "usr/bin",
        developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin",
    }
    return candidate.name in basenames and candidate.parent in approved_directories


def _safe_resolved_path(
    value: Any, developer_dir: PurePosixPath
) -> bool:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > MAX_RESOLVED_PATH_LENGTH
        or "\x00" in value
    ):
        return False
    toolchain_bin = developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    expected_entries = (
        toolchain_bin,
        developer_dir / "usr/bin",
        PurePosixPath("/usr/bin"),
        PurePosixPath("/bin"),
        PurePosixPath("/usr/sbin"),
        PurePosixPath("/sbin"),
    )
    return value == ":".join(str(entry) for entry in expected_entries)


def _safe_path_diagnostic(value: Any, developer_dir: PurePosixPath) -> str:
    if not isinstance(value, str):
        return f"<non-string {type(value).__name__}>"
    if len(value) > MAX_RESOLVED_PATH_LENGTH:
        return f"<oversized path length={len(value)}>"
    entry_count = value.count(":") + 1
    if entry_count > MAX_RESOLVED_PATH_ENTRIES:
        return f"<{entry_count} path entries>"
    entries = value.split(":")
    system_entries = {
        PurePosixPath("/usr/bin"),
        PurePosixPath("/bin"),
        PurePosixPath("/usr/sbin"),
        PurePosixPath("/sbin"),
    }
    xcode_contents = developer_dir.parent
    known_xcode_entries = {
        developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin": (
            "$DEFAULT_TOOLCHAIN_USR_BIN"
        ),
        developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/local/bin": (
            "$DEFAULT_TOOLCHAIN_USR_LOCAL_BIN"
        ),
        developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/libexec": (
            "$DEFAULT_TOOLCHAIN_USR_LIBEXEC"
        ),
        developer_dir / "Platforms/iPhoneOS.platform/usr/bin": (
            "$IPHONEOS_PLATFORM_USR_BIN"
        ),
        developer_dir / "Platforms/iPhoneOS.platform/usr/local/bin": (
            "$IPHONEOS_PLATFORM_USR_LOCAL_BIN"
        ),
        developer_dir / "Platforms/iPhoneOS.platform/Developer/usr/bin": (
            "$IPHONEOS_DEVELOPER_USR_BIN"
        ),
        developer_dir / "Platforms/iPhoneOS.platform/Developer/usr/local/bin": (
            "$IPHONEOS_DEVELOPER_USR_LOCAL_BIN"
        ),
        developer_dir / "usr/bin": "$DEVELOPER_USR_BIN",
        developer_dir / "usr/local/bin": "$DEVELOPER_USR_LOCAL_BIN",
        xcode_contents
        / (
            "SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/"
            "SWBBuildService.bundle/Contents/PlugIns/"
            "SWBUniversalPlatformPlugin.bundle/Contents/Frameworks/"
            "SWBUniversalPlatform.framework/Resources"
        ): "$SWIFT_BUILD_PLUGIN_RESOURCES",
    }
    rendered: list[str] = []
    for index, entry in enumerate(entries):
        candidate = PurePosixPath(entry)
        is_safe_absolute = (
            bool(entry)
            and candidate.is_absolute()
            and ".." not in candidate.parts
            and not any(ord(character) < 0x20 for character in entry)
        )
        if is_safe_absolute and candidate in system_entries:
            rendered.append(entry)
            continue
        if is_safe_absolute and candidate in known_xcode_entries:
            rendered.append(known_xcode_entries[candidate])
            continue
        digest = hashlib.sha256(entry.encode("utf-8", errors="replace")).hexdigest()
        rendered.append(f"<{index}:sha256={digest[:12]}>")
    diagnostic = repr(rendered)
    return diagnostic if len(diagnostic) <= 8192 else diagnostic[:8189] + "..."


def _record_opaque_group_closure(
    objects: Mapping[str, Mapping[str, Any]],
    root_group_id: str,
    parent_by_child: dict[str, str],
    visited_groups: set[str],
) -> str | None:
    pending = [(root_group_id, 0)]
    while pending:
        group_id, chain_depth = pending.pop()
        if group_id in visited_groups:
            return "generated Xcode project main-group graph is cyclic or ambiguous"
        if len(visited_groups) >= MAX_PROJECT_OBJECTS:
            return "generated Xcode project main-group graph exceeds its bound"
        group = objects.get(group_id)
        if not isinstance(group, dict) or group.get("isa") != "PBXGroup":
            return "generated Xcode project mainGroup must reach only PBXGroup nodes"
        raw_group_path = group.get("path")
        expected_path = (
            APPROVED_OPAQUE_GROUP_ROOT_PATH
            if chain_depth == 0
            else APPROVED_OPAQUE_GROUP_CHAIN[chain_depth - 1]
            if chain_depth <= len(APPROVED_OPAQUE_GROUP_CHAIN)
            else None
        )
        if expected_path is not None:
            if raw_group_path != expected_path or group.get("sourceTree") != "<group>":
                return (
                    "generated Xcode project external UI-test group does not match "
                    "the approved canonical chain"
                )
        elif (
            group.get("sourceTree") != "<group>"
            or _safe_project_path(raw_group_path, allow_empty=False) is None
        ):
            return "generated Xcode project external UI-test group has an unsafe descendant"
        visited_groups.add(group_id)
        children = _pbx_reference_list(group.get("children"))
        if children is None:
            return "generated Xcode project contains invalid PBXGroup children"
        if chain_depth < len(APPROVED_OPAQUE_GROUP_CHAIN) and len(children) != 1:
            return (
                "generated Xcode project external UI-test group does not match "
                "the approved canonical chain"
            )
        for child_id in children:
            if child_id in parent_by_child:
                return "generated Xcode project main-group child is multiply reachable"
            parent_by_child[child_id] = group_id
            child = objects.get(child_id)
            if not isinstance(child, dict) or not isinstance(child.get("isa"), str):
                return "generated Xcode project main-group graph has a broken reference"
            if child.get("isa") == "PBXGroup":
                pending.append((child_id, chain_depth + 1))
            elif chain_depth < len(APPROVED_OPAQUE_GROUP_CHAIN) or (
                child.get("isa") != "PBXFileReference"
                or child.get("sourceTree") != "<group>"
                or _safe_project_path(
                    child.get("path", child.get("name")), allow_empty=False
                )
                is None
            ):
                return (
                    "generated Xcode project external UI-test group has an unsafe descendant"
                )
    return None


def _resolved_main_group_paths(
    objects: Mapping[str, Mapping[str, Any]], main_group_id: str
) -> tuple[dict[str, PurePosixPath], str | None]:
    resolved: dict[str, PurePosixPath] = {}
    parent_by_child: dict[str, str] = {}
    pending: list[tuple[str, PurePosixPath]] = [
        (main_group_id, PurePosixPath())
    ]
    visited_groups: set[str] = set()
    opaque_root_seen = False

    while pending:
        group_id, parent_path = pending.pop()
        if group_id in visited_groups:
            return {}, "generated Xcode project main-group graph is cyclic or ambiguous"
        if len(visited_groups) >= MAX_PROJECT_OBJECTS:
            return {}, "generated Xcode project main-group graph exceeds its bound"
        group = objects.get(group_id)
        if not isinstance(group, dict) or group.get("isa") != "PBXGroup":
            return {}, "generated Xcode project mainGroup must reach only PBXGroup nodes"
        source_tree = group.get("sourceTree")
        if source_tree not in ("<group>", "SOURCE_ROOT"):
            return {}, "generated Xcode project contains an unsupported PBXGroup sourceTree"
        raw_group_path = group.get("path")
        if (
            raw_group_path == APPROVED_OPAQUE_GROUP_ROOT_PATH
            and parent_by_child.get(group_id) == main_group_id
        ):
            if opaque_root_seen:
                return {}, "generated Xcode project contains multiple external UI-test roots"
            opaque_root_seen = True
            opaque_error = _record_opaque_group_closure(
                objects, group_id, parent_by_child, visited_groups
            )
            if opaque_error is not None:
                return {}, opaque_error
            continue
        group_component = _safe_project_path(raw_group_path, allow_empty=True)
        if group_component is None:
            return {}, (
                "generated Xcode project contains an unsafe PBXGroup path: "
                f"{_safe_repr(raw_group_path)}"
            )
        group_path = (
            group_component
            if source_tree == "SOURCE_ROOT"
            else parent_path / group_component
        )
        visited_groups.add(group_id)
        children = _pbx_reference_list(group.get("children"))
        if children is None:
            return {}, "generated Xcode project contains invalid PBXGroup children"

        for child_id in children:
            if child_id in parent_by_child:
                return {}, "generated Xcode project main-group child is multiply reachable"
            parent_by_child[child_id] = group_id
            child = objects.get(child_id)
            if not isinstance(child, dict) or not isinstance(child.get("isa"), str):
                return {}, "generated Xcode project main-group graph has a broken reference"
            if child.get("isa") == "PBXGroup":
                pending.append((child_id, group_path))
                continue

            child_component = _safe_project_path(
                child.get("path", child.get("name")), allow_empty=False
            )
            child_source_tree = child.get("sourceTree")
            if child_component is None:
                continue
            if child_source_tree == "<group>":
                resolved[child_id] = group_path / child_component
            elif child_source_tree == "SOURCE_ROOT":
                resolved[child_id] = child_component

    return resolved, None


def _generated_app_icon_membership_error(project: Mapping[str, Any]) -> str | None:
    objects_value = project.get("objects")
    if (
        not isinstance(objects_value, dict)
        or len(objects_value) > MAX_PROJECT_OBJECTS
        or any(
            not isinstance(object_id, str)
            or not PBX_ID_RE.fullmatch(object_id)
            or not isinstance(value, dict)
            or not all(isinstance(key, str) for key in value)
            for object_id, value in objects_value.items()
        )
    ):
        return "generated Xcode project has an invalid bounded object dictionary"
    objects: Mapping[str, Mapping[str, Any]] = objects_value
    for value in objects.values():
        if value.get("isa") != "XCBuildConfiguration":
            continue
        build_settings = value.get("buildSettings")
        if not isinstance(build_settings, dict) or not all(
            isinstance(key, str) for key in build_settings
        ):
            return "generated Xcode project contains invalid build settings"
        if "baseConfigurationReference" in value:
            return "generated Xcode project uses an unverified base configuration"
        for key, setting in build_settings.items():
            base = _build_setting_base(key)
            if base is None:
                return "generated Xcode project contains an invalid build-setting key"
            key_label = _safe_setting_key_label(key)
            if base.startswith("SWIFT_RESPONSE_FILE_PATH_") or any(
                base.startswith(f"{policy_key}_")
                for policy_key in RESOURCE_POLICY_SETTING_BASES
            ):
                return (
                    "generated Xcode project contains an executable tool override: "
                    f"{key_label}"
                )
            if _is_execution_override_base(base) and key != base:
                return (
                    "generated Xcode project contains an executable tool override "
                    f"or conditional resource policy: {key_label}"
                )
            configuration_name = value.get("name")
            if base == "SWIFT_RESPONSE_FILE_PATH":
                if setting != CANONICAL_SWIFT_RESPONSE_FILE_VALUE:
                    return (
                        "generated Xcode project contains an executable tool override: "
                        f"{key_label}"
                    )
                continue
            if base in OPTIONAL_EMPTY_RESOLVED_SETTINGS:
                if setting != "":
                    return (
                        "generated Xcode project contains an executable tool override: "
                        f"{key_label}"
                    )
                continue
            if base == "EXCLUDED_SOURCE_FILE_NAMES":
                required_exclusion = (
                    FIXTURE_NAME if configuration_name == "Release" else ""
                )
                if setting != required_exclusion:
                    return (
                        "generated Xcode project contains an executable tool override "
                        f"or resource-policy override: {key_label}"
                    )
                continue
            safe_canonical_project_setting = (
                key == base
                and (
                    (base == "INFOPLIST_PREPROCESS" and setting == "NO")
                    or (base == "SDKROOT" and setting == "iphoneos")
                )
            )
            if (
                _is_execution_override_base(base)
                and setting not in (None, "")
                and not safe_canonical_project_setting
            ):
                return (
                    "generated Xcode project contains an executable tool override: "
                    f"{key_label}"
                )
    global_asset_refs = [
        value
        for value in objects.values()
        if value.get("isa") == "PBXFileReference"
        and isinstance(value.get("path"), str)
        and value["path"].casefold() == "assets.xcassets"
    ]
    if len(global_asset_refs) != 1:
        return "generated Xcode project must contain one unambiguous Assets.xcassets reference"

    root_id = project.get("rootObject")
    if not isinstance(root_id, str) or not PBX_ID_RE.fullmatch(root_id):
        return "generated Xcode project has an invalid rootObject reference"
    root = objects.get(root_id)
    if not isinstance(root, dict) or root.get("isa") != "PBXProject":
        return "generated Xcode project rootObject does not reach PBXProject"
    if root.get("projectDirPath") != "" or root.get("projectRoot") != "":
        return "generated Xcode project must use the canonical empty project root"

    package_reference_ids = _pbx_reference_list(
        root.get("packageReferences"), allow_empty=False
    )
    if (
        package_reference_ids is None
        or len(package_reference_ids) != len(APPROVED_LOCAL_PACKAGE_PATHS)
    ):
        return "generated Xcode project must reference the exact approved local packages"
    package_paths: set[str] = set()
    for package_reference_id in package_reference_ids:
        package_reference = objects.get(package_reference_id)
        if (
            not isinstance(package_reference, dict)
            or set(package_reference) != {"isa", "relativePath"}
            or package_reference.get("isa") != "XCLocalSwiftPackageReference"
            or not isinstance(package_reference.get("relativePath"), str)
        ):
            return "generated Xcode project contains an unverified Swift package reference"
        package_paths.add(package_reference["relativePath"])
    if package_paths != APPROVED_LOCAL_PACKAGE_PATHS:
        return "generated Xcode project must reference the exact approved local package paths"

    main_group_id = root.get("mainGroup")
    if not isinstance(main_group_id, str) or not PBX_ID_RE.fullmatch(main_group_id):
        return "generated Xcode project PBXProject has an invalid mainGroup"
    resolved_paths, group_error = _resolved_main_group_paths(objects, main_group_id)
    if group_error:
        return group_error

    target_ids = _pbx_reference_list(root.get("targets"), allow_empty=False)
    if target_ids is None:
        return "generated Xcode project PBXProject has invalid targets"
    targets: list[tuple[str, Mapping[str, Any]]] = []
    for target_id in target_ids:
        target = objects.get(target_id)
        if not isinstance(target, dict) or not isinstance(target.get("isa"), str):
            return "generated Xcode project PBXProject has a broken target reference"
        if target.get("name") == "SentiPocketApp":
            targets.append((target_id, target))
    named_targets = [
        value
        for value in objects.values()
        if value.get("isa") == "PBXNativeTarget"
        and value.get("name") == "SentiPocketApp"
    ]
    if (
        len(targets) != 1
        or len(named_targets) != 1
        or targets[0][1] is not named_targets[0]
    ):
        return "generated Xcode project must contain one reachable SentiPocketApp target"
    target_id, target = targets[0]
    if (
        target.get("isa") != "PBXNativeTarget"
        or target.get("productType") != "com.apple.product-type.application"
    ):
        return "generated Xcode project SentiPocketApp target is not an application"
    if "fileSystemSynchronizedGroups" in target:
        return "generated Xcode project app target uses unverified synchronized groups"
    dependencies = _pbx_reference_list(target.get("dependencies", []))
    if dependencies != []:
        return "generated Xcode project app target uses unverified target dependencies"
    build_rules = _pbx_reference_list(target.get("buildRules", []))
    if build_rules != []:
        return "generated Xcode project app target uses unverified build rules"

    package_product_ids = _pbx_reference_list(
        target.get("packageProductDependencies"), allow_empty=False
    )
    if (
        package_product_ids is None
        or len(package_product_ids) != len(APPROVED_PACKAGE_PRODUCTS)
    ):
        return "generated Xcode project app target must use the exact approved package products"
    package_products: set[str] = set()
    for package_product_id in package_product_ids:
        package_product = objects.get(package_product_id)
        if (
            not isinstance(package_product, dict)
            or set(package_product) != {"isa", "productName"}
            or package_product.get("isa") != "XCSwiftPackageProductDependency"
            or not isinstance(package_product.get("productName"), str)
        ):
            return "generated Xcode project app target contains an unverified package product"
        package_products.add(package_product["productName"])
    if package_products != APPROVED_PACKAGE_PRODUCTS:
        return "generated Xcode project app target must use the exact approved package product names"

    phase_ids = _pbx_reference_list(target.get("buildPhases"), allow_empty=False)
    if phase_ids is None:
        return "generated Xcode project SentiPocketApp target has invalid build phases"
    phases: list[Mapping[str, Any]] = []
    framework_product_ids: list[str] = []
    for phase_id in phase_ids:
        phase = objects.get(phase_id)
        if (
            not isinstance(phase, dict)
            or not isinstance(phase.get("isa"), str)
            or phase["isa"]
            not in {
                "PBXFrameworksBuildPhase",
                "PBXResourcesBuildPhase",
                "PBXSourcesBuildPhase",
            }
        ):
            return "generated Xcode project SentiPocketApp target has an unverified build phase"
        phase_deployment_only = phase.get("runOnlyForDeploymentPostprocessing")
        if not (
            phase_deployment_only == "0"
            or (type(phase_deployment_only) is int and phase_deployment_only == 0)
        ):
            return "generated Xcode project app build phase is not always active"
        build_action_mask = phase.get("buildActionMask")
        if not (
            build_action_mask == "2147483647"
            or (type(build_action_mask) is int and build_action_mask == 2147483647)
        ):
            return "generated Xcode project app build phase has an unverified action mask"
        phase_build_files = _pbx_reference_list(phase.get("files"))
        if phase_build_files is None:
            return "generated Xcode project app build phase has invalid files"
        for build_file_id in phase_build_files:
            build_file = objects.get(build_file_id)
            allowed_reference_keys = (
                ({"isa", "fileRef"}, {"isa", "productRef"})
                if phase["isa"] == "PBXFrameworksBuildPhase"
                else ({"isa", "fileRef"},)
            )
            if (
                not isinstance(build_file, dict)
                or build_file.get("isa") != "PBXBuildFile"
                or set(build_file) not in allowed_reference_keys
            ):
                return "generated Xcode project app build phase has a broken build file"
            reference_key = (
                "productRef" if "productRef" in build_file else "fileRef"
            )
            reference_id = build_file.get(reference_key)
            if not isinstance(reference_id, str) or not PBX_ID_RE.fullmatch(reference_id):
                return "generated Xcode project app build phase has an invalid file reference"
            reference = objects.get(reference_id)
            if not isinstance(reference, dict) or not isinstance(reference.get("isa"), str):
                return "generated Xcode project app build phase has a broken file reference"
            if reference_key == "productRef":
                if (
                    phase["isa"] != "PBXFrameworksBuildPhase"
                    or reference.get("isa") != "XCSwiftPackageProductDependency"
                    or reference_id not in package_product_ids
                ):
                    return "generated Xcode project app Frameworks phase has an invalid package product"
                framework_product_ids.append(reference_id)
                continue
            if reference.get("isa") != "PBXFileReference":
                return "generated Xcode project app build phase has an unsupported file reference"
            reference_file_path = reference.get("path", reference.get("name"))
            reference_file_types = (
                reference.get("lastKnownFileType"),
                reference.get("explicitFileType"),
            )
            if (
                isinstance(reference_file_path, str)
                and reference_file_path.casefold().endswith(".icon")
            ) or any(
                isinstance(file_type, str)
                and (
                    file_type.casefold() == "folder.iconcomposer.icon"
                    or ".iconcomposer." in file_type.casefold()
                )
                for file_type in reference_file_types
            ):
                return "generated Xcode project app target contains an unverified Icon Composer resource"
            reference_path = resolved_paths.get(reference_id)
            if reference_path is None or reference_path.is_absolute() or any(
                part in ("", ".", "..") for part in reference_path.parts
            ):
                return "generated Xcode project app build phase references an unsafe source path"
            if (
                phase["isa"] == "PBXResourcesBuildPhase"
                and reference_path not in APPROVED_RESOURCE_REFERENCES
            ):
                if reference_path.suffix.casefold() == ".xcassets":
                    return "generated Xcode project app Resources phase contains an unverified asset catalog"
                return "generated Xcode project app Resources phase contains an unverified input"
            if phase["isa"] == "PBXSourcesBuildPhase" and (
                len(reference_path.parts) < 2
                or reference_path.parts[0] != "Sources"
                or reference_path.suffix.casefold() != ".swift"
            ):
                return "generated Xcode project app Sources phase contains an unverified input"
            if phase["isa"] == "PBXFrameworksBuildPhase":
                return "generated Xcode project app Frameworks phase contains an unverified file input"
        phases.append(phase)
    if set(framework_product_ids) != set(package_product_ids) or len(
        framework_product_ids
    ) != len(package_product_ids):
        return "generated Xcode project app Frameworks phase must link every approved package product exactly once"
    resource_phases = [
        phase for phase in phases if phase.get("isa") == "PBXResourcesBuildPhase"
    ]
    if len(resource_phases) != 1:
        return "generated Xcode project must contain one app Resources build phase"
    build_file_ids = _pbx_reference_list(resource_phases[0].get("files"))
    if build_file_ids is None:
        return "generated Xcode project app Resources phase has invalid files"
    asset_references: list[tuple[str, Mapping[str, Any]]] = []
    for build_file_id in build_file_ids:
        build_file = objects.get(build_file_id)
        if (
            not isinstance(build_file, dict)
            or build_file.get("isa") != "PBXBuildFile"
            or set(build_file) != {"isa", "fileRef"}
        ):
            return "generated Xcode project app Resources phase has a broken build file"
        file_ref_id = build_file.get("fileRef")
        if not isinstance(file_ref_id, str) or not PBX_ID_RE.fullmatch(file_ref_id):
            return "generated Xcode project app resource has an invalid file reference"
        file_ref = objects.get(file_ref_id)
        if not isinstance(file_ref, dict) or not isinstance(file_ref.get("isa"), str):
            return "generated Xcode project app resource has a broken file reference"
        file_path = file_ref.get("path", file_ref.get("name"))
        file_types = (file_ref.get("lastKnownFileType"), file_ref.get("explicitFileType"))
        if (
            isinstance(file_path, str)
            and file_path.casefold().endswith(".icon")
        ) or any(
            isinstance(file_type, str)
            and (
                file_type.casefold() == "folder.iconcomposer.icon"
                or ".iconcomposer." in file_type.casefold()
            )
            for file_type in file_types
        ):
            return "generated Xcode project app target contains an unverified Icon Composer resource"
        is_asset_catalog = file_ref.get("lastKnownFileType") == "folder.assetcatalog"
        is_asset_catalog = is_asset_catalog or file_ref.get(
            "explicitFileType"
        ) == "folder.assetcatalog"
        is_asset_catalog = is_asset_catalog or (
            isinstance(file_path, str) and file_path.casefold().endswith(".xcassets")
        )
        if is_asset_catalog:
            asset_references.append((file_ref_id, file_ref))

    if len(asset_references) != 1:
        return "generated Xcode project app target must build one asset catalog"
    file_ref_id, file_ref = asset_references[0]
    if (
        file_ref.get("isa") != "PBXFileReference"
        or file_ref.get("lastKnownFileType") != "folder.assetcatalog"
        or file_ref.get("path") != "Assets.xcassets"
        or file_ref.get("sourceTree") != "<group>"
        or resolved_paths.get(file_ref_id)
        != PurePosixPath("Resources/Assets.xcassets")
    ):
        return "generated Xcode project lacks exact reachable app asset catalog membership"
    return target_id


def _generated_scheme_errors(path: Path, target_id: str | None) -> list[str]:
    if target_id is None:
        return ["generated Xcode scheme cannot bind an unverified app target"]
    encoded, read_errors = _read_bounded_regular_file(
        path,
        "generated SentiPocketAppRelease scheme",
        maximum_bytes=MAX_INPUT_BYTES,
        minimum_bytes=1,
    )
    if encoded is None:
        return read_errors
    try:
        root = ET.fromstring(encoded)
    except ET.ParseError:
        return ["generated SentiPocketApp scheme is malformed XML"]
    except OSError as exc:
        return [f"generated SentiPocketApp scheme could not be read: {type(exc).__name__}"]

    if root.tag != "Scheme" or len(root) != 6 or {child.tag for child in root} != {
        "BuildAction",
        "TestAction",
        "LaunchAction",
        "ProfileAction",
        "AnalyzeAction",
        "ArchiveAction",
    }:
        return ["generated SentiPocketApp scheme has an unverified action structure"]
    if root.findall(".//PreActions") or root.findall(".//PostActions"):
        return ["generated SentiPocketApp scheme contains pre/post actions"]
    if root.findall(".//ExecutionAction"):
        return ["generated SentiPocketApp scheme contains executable actions"]

    build_action = root.find("BuildAction")
    if (
        build_action is None
        or build_action.get("buildImplicitDependencies") != "NO"
        or build_action.get("parallelizeBuildables") not in {"YES", "NO"}
    ):
        return ["generated SentiPocketApp scheme permits implicit or ambiguous builds"]
    entries = build_action.findall("./BuildActionEntries/BuildActionEntry")
    if len(entries) != 1:
        return ["generated SentiPocketApp scheme must build exactly one target"]
    entry = entries[0]
    if any(
        entry.get(attribute) != "YES"
        for attribute in (
            "buildForTesting",
            "buildForRunning",
            "buildForProfiling",
            "buildForArchiving",
            "buildForAnalyzing",
        )
    ):
        return ["generated SentiPocketApp scheme has incomplete app build actions"]
    reference = entry.find("BuildableReference")
    if (
        reference is None
        or reference.get("BuildableIdentifier") != "primary"
        or reference.get("BlueprintIdentifier") != target_id
        or reference.get("BlueprintName") != "SentiPocketApp"
        or reference.get("BuildableName") != "SentiPocketApp.app"
        or reference.get("ReferencedContainer") != "container:SentiPocketApp.xcodeproj"
    ):
        return ["generated SentiPocketApp scheme does not bind the verified app target"]
    archive_action = root.find("ArchiveAction")
    if archive_action is None or archive_action.get("buildConfiguration") != "Release":
        return ["generated SentiPocketApp scheme does not archive Release"]
    return []


def _generated_project_errors(path: Path) -> list[str]:
    try:
        for directory, label in (
            (path.parent, "generated Xcode project directory"),
            (path.parent.parent, "generated app source root"),
        ):
            directory_stat = directory.lstat()
            if _stat_is_indirection(directory_stat) or not stat.S_ISDIR(
                directory_stat.st_mode
            ):
                return [f"{label} is not a regular directory"]
        encoded_project, read_errors = _read_bounded_regular_file(
            path,
            "generated Xcode project",
            maximum_bytes=MAX_PROJECT_BYTES,
            minimum_bytes=1,
        )
        if encoded_project is None:
            return read_errors
        project = encoded_project.decode("utf-8")
    except FileNotFoundError:
        return ["generated Xcode project is not a regular file"]
    except (OSError, UnicodeError) as exc:
        return [f"generated Xcode project could not be decoded: {type(exc).__name__}"]

    errors: list[str] = []
    if not project.startswith("// !$*UTF8*$!") or "\x00" in project:
        errors.append("generated Xcode project has an invalid text envelope")
    # XcodeGen's per-source `compilerFlags` are serialized as PBXBuildFile
    # COMPILER_FLAGS and do not appear in `xcodebuild -showBuildSettings`.
    # This app currently needs none, so rejecting the entire surface is both
    # simpler and stronger than attempting to interpret OpenStep quoting.
    if "COMPILER_FLAGS" in project:
        errors.append("generated Xcode project contains per-file compiler flags")
    structured_project, conversion_errors = _structured_project_from_plutil(
        path, encoded_project
    )
    errors.extend(conversion_errors)
    if structured_project is not None:
        membership_result = _generated_app_icon_membership_error(structured_project)
        target_id = membership_result if PBX_ID_RE.fullmatch(membership_result or "") else None
        if membership_result and target_id is None:
            errors.append(membership_result)
        errors.extend(_generated_scheme_errors(path.parent / SCHEME_RELATIVE, target_id))
    return errors


def _approved_package_manifest_errors(repository_root: Path) -> list[str]:
    if set(APPROVED_PACKAGE_MANIFEST_SHA256) != APPROVED_PACKAGE_PRODUCTS:
        return ["approved local package manifest policy is internally inconsistent"]
    packages_root = repository_root / "packages"
    errors: list[str] = []
    try:
        for directory, label in (
            (repository_root, "repository root"),
            (packages_root, "local packages root"),
        ):
            directory_stat = directory.lstat()
            if _stat_is_indirection(directory_stat) or not stat.S_ISDIR(
                directory_stat.st_mode
            ):
                return [f"{label} is not a regular directory"]
    except OSError as exc:
        return [f"local package roots could not be inspected: {type(exc).__name__}"]

    for product, approved_digest in sorted(
        APPROVED_PACKAGE_MANIFEST_SHA256.items()
    ):
        package_directory = packages_root / product
        try:
            package_stat = package_directory.lstat()
        except OSError as exc:
            errors.append(
                f"approved package {product} could not be inspected: {type(exc).__name__}"
            )
            continue
        if _stat_is_indirection(package_stat) or not stat.S_ISDIR(package_stat.st_mode):
            errors.append(f"approved package {product} is not a regular directory")
            continue
        try:
            entries, list_errors = _bounded_directory_entries(
                package_directory,
                MAX_APP_ROOT_ENTRIES,
                f"approved package {product}",
            )
        except OSError as exc:
            errors.append(
                f"approved package {product} could not be enumerated: {type(exc).__name__}"
            )
            continue
        if list_errors:
            errors.extend(list_errors)
            continue
        manifest_names = [
            entry.name
            for entry in entries
            if entry.name.casefold().startswith("package")
            and entry.name.casefold().endswith(".swift")
        ]
        if manifest_names != ["Package.swift"]:
            errors.append(
                f"approved package {product} must contain only canonical Package.swift"
            )
            continue
        encoded, read_errors = _read_bounded_regular_file(
            package_directory / "Package.swift",
            f"approved package {product} manifest",
            maximum_bytes=MAX_INPUT_BYTES,
            minimum_bytes=1,
        )
        errors.extend(read_errors)
        if encoded is not None:
            canonical = encoded.replace(b"\r\n", b"\n")
            if b"\r" in canonical:
                errors.append(
                    f"approved package {product} manifest contains noncanonical line endings"
                )
            elif not hmac.compare_digest(
                hashlib.sha256(canonical).hexdigest(), approved_digest
            ):
                errors.append(
                    f"approved package {product} manifest does not match its reviewed digest"
                )
    return errors


def _approved_project_spec_errors(repository_root: Path) -> list[str]:
    encoded, read_errors = _read_bounded_regular_file(
        repository_root / PROJECT_SPEC_RELATIVE,
        "reviewed XcodeGen project specification",
        maximum_bytes=MAX_INPUT_BYTES,
        minimum_bytes=1,
    )
    if encoded is None:
        return read_errors
    canonical = encoded.replace(b"\r\n", b"\n")
    if b"\r" in canonical:
        return ["reviewed XcodeGen project specification has noncanonical line endings"]
    if not hmac.compare_digest(
        hashlib.sha256(canonical).hexdigest(), PROJECT_SPEC_SHA256
    ):
        return [
            "XcodeGen project specification does not match its reviewed digest"
        ]
    return []


def verify_source(project_file: Path) -> list[str]:
    repository_root = project_file.parent.parent.parent.parent
    errors = _generated_project_errors(project_file)
    errors.extend(_source_app_icon_errors(project_file))
    errors.extend(_approved_project_spec_errors(repository_root))
    errors.extend(_approved_package_manifest_errors(repository_root))
    return errors


def verify_preflight(repository_root: Path) -> list[str]:
    if not repository_root.is_absolute():
        return ["repository root must be absolute"]
    try:
        root_stat = repository_root.lstat()
    except OSError as exc:
        return [f"repository root could not be inspected: {type(exc).__name__}"]
    if _stat_is_indirection(root_stat) or not stat.S_ISDIR(root_stat.st_mode):
        return ["repository root is not a regular directory"]
    project_file = (
        repository_root
        / "apps/SentiPocketApp/SentiPocketApp.xcodeproj/project.pbxproj"
    )
    errors = _approved_project_spec_errors(repository_root)
    errors.extend(_source_app_icon_errors(project_file))
    errors.extend(_approved_package_manifest_errors(repository_root))
    return errors


def _xml_plist_duplicate_key_error(encoded: bytes) -> str | None:
    try:
        root = ET.fromstring(encoded)
    except ET.ParseError:
        return None
    if (
        root.tag != "plist"
        or root.attrib != {"version": "1.0"}
        or len(root) != 1
    ):
        return "XML plist contains an unsupported root structure"

    scalar_tags = {"data", "date", "integer", "real", "string"}
    pending: list[tuple[ET.Element, int]] = [(root[0], 1)]
    visited = 0
    while pending:
        element, depth = pending.pop()
        visited += 1
        if visited > MAX_PLIST_OBJECTS:
            return "XML plist exceeds the object verification limit"
        if depth > MAX_XML_PLIST_DEPTH:
            return "XML plist exceeds the nesting-depth verification limit"
        if not isinstance(element.tag, str) or element.attrib:
            return "XML plist contains an unsupported element, attribute, or namespace"
        children = list(element)
        if element.tag == "dict":
            if len(children) % 2 != 0:
                return "XML plist contains a malformed dictionary"
            keys: set[str] = set()
            for index in range(0, len(children), 2):
                key = children[index]
                if key.tag != "key" or key.attrib or key.text is None or len(key):
                    return "XML plist contains a malformed dictionary"
                if key.text in keys:
                    return "XML plist contains duplicate dictionary keys"
                keys.add(key.text)
                pending.append((children[index + 1], depth + 1))
        elif element.tag == "array":
            pending.extend((child, depth + 1) for child in children)
        elif element.tag in scalar_tags:
            if children:
                return "XML plist contains a malformed scalar value"
        elif element.tag in {"true", "false"}:
            if children or element.text not in (None, ""):
                return "XML plist contains a malformed boolean value"
        else:
            return "XML plist contains an unsupported element, attribute, or namespace"
    return None


def _binary_plist_duplicate_key_error(encoded: bytes) -> str | None:
    if not encoded.startswith(b"bplist00"):
        return None
    if len(encoded) < 40:
        return "binary plist has a malformed object table"

    trailer = encoded[-32:]
    offset_size = trailer[6]
    reference_size = trailer[7]
    object_count = int.from_bytes(trailer[8:16], "big")
    offset_table = int.from_bytes(trailer[24:32], "big")
    if (
        not 1 <= offset_size <= 8
        or not 1 <= reference_size <= 8
        or not 1 <= object_count <= MAX_PLIST_OBJECTS
        or offset_table < 8
        or offset_table + object_count * offset_size > len(encoded) - 32
    ):
        return "binary plist has a malformed object table"

    offsets = [
        int.from_bytes(
            encoded[
                offset_table + index * offset_size :
                offset_table + (index + 1) * offset_size
            ],
            "big",
        )
        for index in range(object_count)
    ]
    if any(offset < 8 or offset >= offset_table for offset in offsets):
        return "binary plist has a malformed object offset"

    def object_length(offset: int, marker: int) -> tuple[int, int] | None:
        inline = marker & 0x0F
        cursor = offset + 1
        if inline < 0x0F:
            return inline, cursor
        if cursor >= offset_table or encoded[cursor] >> 4 != 0x01:
            return None
        integer_bytes = 1 << (encoded[cursor] & 0x0F)
        if integer_bytes > 8 or cursor + 1 + integer_bytes > offset_table:
            return None
        length = int.from_bytes(
            encoded[cursor + 1 : cursor + 1 + integer_bytes], "big"
        )
        return length, cursor + 1 + integer_bytes

    decoded_key_by_offset: dict[int, str | None] = {}
    decoded_key_bytes = 0
    key_budget_exceeded = False

    def decoded_key(reference: int) -> str | None:
        nonlocal decoded_key_bytes, key_budget_exceeded
        if reference >= object_count:
            return None
        offset = offsets[reference]
        if offset in decoded_key_by_offset:
            return decoded_key_by_offset[offset]
        marker = encoded[offset]
        kind = marker >> 4
        length_and_cursor = object_length(offset, marker)
        if length_and_cursor is None or kind not in {0x05, 0x06}:
            decoded_key_by_offset[offset] = None
            return None
        length, cursor = length_and_cursor
        byte_count = length if kind == 0x05 else length * 2
        if byte_count > MAX_INPUT_BYTES or cursor + byte_count > offset_table:
            decoded_key_by_offset[offset] = None
            return None
        if byte_count > MAX_PLIST_DECODED_KEY_BYTES - decoded_key_bytes:
            key_budget_exceeded = True
            decoded_key_by_offset[offset] = None
            return None
        decoded_key_bytes += byte_count
        codec = "ascii" if kind == 0x05 else "utf-16-be"
        try:
            key = encoded[cursor : cursor + byte_count].decode(codec)
        except UnicodeError:
            decoded_key_by_offset[offset] = None
            return None
        decoded_key_by_offset[offset] = key
        return key

    scanned_dictionary_offsets: set[int] = set()
    for offset in offsets:
        marker = encoded[offset]
        if marker >> 4 != 0x0D:
            continue
        if offset in scanned_dictionary_offsets:
            continue
        scanned_dictionary_offsets.add(offset)
        length_and_cursor = object_length(offset, marker)
        if length_and_cursor is None:
            return "binary plist has a malformed dictionary"
        item_count, cursor = length_and_cursor
        references_bytes = item_count * reference_size * 2
        if item_count > object_count or cursor + references_bytes > offset_table:
            return "binary plist has a malformed dictionary"
        keys: set[str] = set()
        for index in range(item_count):
            key_reference = int.from_bytes(
                encoded[
                    cursor + index * reference_size :
                    cursor + (index + 1) * reference_size
                ],
                "big",
            )
            key = decoded_key(key_reference)
            if key is None:
                if key_budget_exceeded:
                    return "binary plist dictionary key decoding exceeds work bound"
                return "binary plist has a malformed dictionary key"
            if key in keys:
                return "binary plist contains duplicate dictionary keys"
            keys.add(key)
    return None


def _plist_value_error(root: Any) -> str | None:
    scalar_types = (str, bytes, int, float, bool, datetime.datetime)
    pending: list[tuple[Any, int, bool]] = [(root, 1, False)]
    active_containers: set[int] = set()
    visited = 0
    while pending:
        value, depth, leaving = pending.pop()
        if leaving:
            active_containers.remove(id(value))
            continue
        visited += 1
        if visited > MAX_PLIST_OBJECTS:
            return "plist exceeds the object verification limit"
        if depth > MAX_XML_PLIST_DEPTH:
            return "plist exceeds the nesting-depth verification limit"
        if isinstance(value, dict):
            if not all(isinstance(key, str) for key in value):
                return "plist contains a non-string dictionary key"
            identity = id(value)
            if identity in active_containers:
                return "plist contains a cyclic container graph"
            active_containers.add(identity)
            pending.append((value, depth, True))
            pending.extend(
                (child, depth + 1, False) for child in value.values()
            )
        elif isinstance(value, list):
            identity = id(value)
            if identity in active_containers:
                return "plist contains a cyclic container graph"
            active_containers.add(identity)
            pending.append((value, depth, True))
            pending.extend((child, depth + 1, False) for child in value)
        elif type(value) is float and not math.isfinite(value):
            return "plist contains a non-finite real value"
        elif not isinstance(value, scalar_types):
            return "plist contains an unsupported value type"
    return None


def _read_plist(path: Path, label: str) -> tuple[dict[str, Any] | None, list[str]]:
    encoded, read_errors = _read_bounded_regular_file(
        path, label, maximum_bytes=MAX_INPUT_BYTES
    )
    if encoded is None:
        return None, read_errors
    try:
        if encoded.startswith(b"bplist00"):
            duplicate_error = _binary_plist_duplicate_key_error(encoded)
            if duplicate_error:
                return None, [f"{label} {duplicate_error}"]
        else:
            if len(encoded) > MAX_XML_PLIST_BYTES:
                return None, [
                    f"{label} XML plist exceeds the {MAX_XML_PLIST_BYTES}-byte verification limit"
                ]
            duplicate_error = _xml_plist_duplicate_key_error(encoded)
            if duplicate_error:
                return None, [f"{label} {duplicate_error}"]
        payload = plistlib.loads(encoded)
    except (
        OSError,
        plistlib.InvalidFileException,
        ValueError,
        TypeError,
        OverflowError,
        EOFError,
        IndexError,
        RecursionError,
    ) as exc:
        return None, [f"{label} could not be decoded: {type(exc).__name__}"]
    if not isinstance(payload, dict):
        return None, [f"{label} root must be a dictionary"]
    value_error = _plist_value_error(payload)
    if value_error:
        return None, [f"{label} {value_error}"]
    return payload, []


def load_target_settings(
    path: Path, target: str
) -> tuple[dict[str, Any] | None, list[str]]:
    payload, errors = _read_json(path)
    if errors:
        return None, errors
    if not isinstance(payload, list):
        return None, ["settings JSON root must be an array"]
    matches = [
        item
        for item in payload
        if isinstance(item, dict) and item.get("target") == target
    ]
    if len(matches) != 1:
        return None, [
            f"expected exactly one {target} settings record, found {len(matches)}"
        ]
    settings = matches[0].get("buildSettings")
    if not isinstance(settings, dict) or not all(
        isinstance(key, str) for key in settings
    ):
        return None, ["target buildSettings must be a string-keyed dictionary"]
    if len(settings) > MAX_RESOLVED_BUILD_SETTINGS:
        return None, [
            "target buildSettings exceeds the bounded resolved-setting limit"
        ]
    return settings, []


def _require_exact(
    values: Mapping[str, Any], expected: Mapping[str, str], errors: list[str]
) -> None:
    for key, wanted in expected.items():
        actual = values.get(key)
        if actual != wanted:
            if key in SENSITIVE_SETTING_KEYS:
                errors.append(f"{key}: resolved value does not match expected")
            else:
                errors.append(
                    f"{key}: expected {_safe_repr(wanted)}, got {_safe_repr(actual)}"
                )


def _require_empty_or_absent(
    values: Mapping[str, Any], keys: Iterable[str], errors: list[str]
) -> None:
    for key in sorted(keys):
        if key not in values:
            continue
        actual = values[key]
        if actual != "":
            errors.append(f"{key}: expected an empty or omitted value")


def _verify_swift_response_file_settings(
    settings: Mapping[str, Any], expected: Expectations, errors: list[str]
) -> None:
    generated_keys = {
        key
        for key in settings
        if (base := _build_setting_base(key)) is not None
        and base.startswith("SWIFT_RESPONSE_FILE_PATH_")
    }
    if generated_keys != {SWIFT_RESPONSE_FILE_KEY}:
        errors.append(
            "resolved Swift response-file settings must contain exactly "
            f"{SWIFT_RESPONSE_FILE_KEY}"
        )
        return
    expected_path = (
        expected.products_root.parent
        / "Intermediates.noindex"
        / f"{expected.target}.build"
        / f"{expected.configuration}-iphoneos"
        / f"{expected.target}.build"
        / "Objects-normal"
        / "arm64"
        / f"{expected.target}.SwiftFileList"
    )
    actual = settings[SWIFT_RESPONSE_FILE_KEY]
    if actual != str(expected_path):
        errors.append(
            f"{SWIFT_RESPONSE_FILE_KEY}: generated response file is outside the "
            "independently expected DerivedData path; got <redacted>"
        )


def _resolved_setting_tokens(
    settings: Mapping[str, Any], key: str, errors: list[str]
) -> tuple[str, ...] | None:
    raw = settings.get(key, "")
    if not isinstance(raw, str):
        errors.append(f"{key} must resolve to a string")
        return None
    try:
        tokens = tuple(shlex.split(raw))
    except ValueError:
        errors.append(f"{key} contains invalid shell-style quoting")
        return None
    if any(token.startswith("@") for token in tokens):
        errors.append(f"{key} must not contain an opaque response-file argument")
        return None
    return tokens


def _forwarded_frontend_tokens(
    tokens: tuple[str, ...], key: str, errors: list[str]
) -> tuple[str, ...] | None:
    forwarded: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "-Xfrontend":
            index += 1
            if index >= len(tokens):
                errors.append(f"{key} contains an incomplete -Xfrontend argument")
                return None
            forwarded.append(tokens[index])
        elif token.startswith("-Xfrontend="):
            value = token.partition("=")[2]
            if not value:
                errors.append(f"{key} contains an empty -Xfrontend argument")
                return None
            forwarded.append(value)
        else:
            forwarded.append(token)
        index += 1

    if any(token.startswith("@") for token in forwarded):
        errors.append(f"{key} must not forward an opaque response-file argument")
        return None
    return tuple(forwarded)


def _verify_swift_compilation_conditions(
    settings: Mapping[str, Any], configuration: str, errors: list[str]
) -> None:
    active = _resolved_setting_tokens(
        settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS", errors
    )
    if active is not None:
        if any(not SWIFT_CONDITION_RE.fullmatch(token) for token in active):
            errors.append(
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS contains an invalid condition"
            )
        debug_is_active = "DEBUG" in active
        if configuration == "Debug" and not debug_is_active:
            errors.append("Debug configuration must define DEBUG")
        if configuration == "Release" and debug_is_active:
            errors.append("Release configuration must not define DEBUG")

    other_flags = _resolved_setting_tokens(settings, "OTHER_SWIFT_FLAGS", errors)
    if configuration == "Release" and other_flags is not None:
        other_flags = _forwarded_frontend_tokens(
            other_flags, "OTHER_SWIFT_FLAGS", errors
        )
    if configuration == "Release" and other_flags is not None:
        defines_debug = any(
            token == "DEBUG"
            or token.startswith("DEBUG=")
            or SWIFT_DEBUG_FLAG_RE.search(token)
            for token in other_flags
        )
        if defines_debug:
            errors.append("Release OTHER_SWIFT_FLAGS must not define DEBUG")


def verify_settings_file(
    settings_path: Path, expected: Expectations
) -> tuple[dict[str, Any] | None, list[str]]:
    errors = validate_expectations(expected)
    if errors:
        return None, errors
    settings, load_errors = load_target_settings(settings_path, expected.target)
    if load_errors or settings is None:
        return None, load_errors

    errors.extend(verify_source(expected.project_file))
    project_file_path = settings.get("PROJECT_FILE_PATH")
    resolved_project_directory = _resolved_absolute_path(project_file_path)
    expected_project_directory = _resolved_absolute_path(
        str(expected.project_file.parent)
    )
    if resolved_project_directory is None:
        errors.append("PROJECT_FILE_PATH must resolve to an absolute project path")
    elif (
        expected_project_directory is None
        or resolved_project_directory != expected_project_directory
    ):
        errors.append("PROJECT_FILE_PATH does not match the inspected Xcode project")

    _require_exact(
        settings,
        {
            "CONFIGURATION": expected.configuration,
            "PLATFORM_NAME": "iphoneos",
            "APS_ENVIRONMENT": expected.aps_environment,
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "ONLY_ACTIVE_ARCH": "NO",
            "PRODUCT_BUNDLE_IDENTIFIER": expected.bundle_id,
            "MARKETING_VERSION": expected.marketing_version,
            "CURRENT_PROJECT_VERSION": expected.build_number,
            "SENTI_API_URL": expected.api_url,
            "SENTI_GATEWAY_URL": expected.gateway_url,
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_PREPROCESS": "NO",
            "COMPILATION_CACHE_ENABLE_PLUGIN": "NO",
            "SWIFT_ENABLE_COMPILE_CACHE": "NO",
            "IPHONEOS_DEPLOYMENT_TARGET": expected.deployment_target,
            "ASSETCATALOG_COMPILER_APPICON_NAME": APP_ICON_NAME,
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "NO",
            "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": "NO",
            "ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR": "default",
            "TARGETED_DEVICE_FAMILY": "1",
        },
        errors,
    )
    optional_empty_settings = set(OPTIONAL_EMPTY_RESOLVED_SETTINGS)
    if expected.configuration == "Debug":
        optional_empty_settings.add("EXCLUDED_SOURCE_FILE_NAMES")
    _require_empty_or_absent(settings, optional_empty_settings, errors)
    if expected.configuration == "Release":
        _require_exact(
            settings,
            {"EXCLUDED_SOURCE_FILE_NAMES": FIXTURE_NAME},
            errors,
        )
        _require_empty_or_absent(
            settings,
            EMPTY_RELEASE_FLAG_KEYS,
            errors,
        )
    for key in sorted(EMPTY_INFO_PLIST_PREPROCESSOR_KEYS):
        if settings.get(key, "") != "":
            errors.append(f"{key}: plist preprocessor override must be empty")

    if settings.get("DEVELOPMENT_TEAM", "") != "":
        errors.append("DEVELOPMENT_TEAM must be empty for unsigned verification")

    _verify_swift_compilation_conditions(settings, expected.configuration, errors)
    _verify_swift_response_file_settings(settings, expected, errors)

    for key, value in settings.items():
        base = _build_setting_base(key)
        key_label = _safe_setting_key_label(key)
        if base is None:
            errors.append(f"{key_label}: resolved build-setting key is invalid")
            continue
        if any(
            base.startswith(f"{policy_key}_")
            for policy_key in RESOURCE_POLICY_SETTING_BASES
        ):
            errors.append(f"{key_label}: resource-policy override is not permitted")
        if _is_execution_override_base(base) and key != base:
            errors.append(
                f"{key_label}: conditional execution or resource-policy override "
                "is not permitted"
            )
        if (
            base in EMPTY_EXECUTION_OVERRIDE_KEYS
            or base in EMPTY_INFO_PLIST_PREPROCESSOR_KEYS
            or base in {"SWIFT_TOOLCHAIN_FLAGS", "SWIFT_RESPONSE_FILE_PATH"}
            or (
                base.startswith("SWIFT_RESPONSE_FILE_PATH_")
                and key != SWIFT_RESPONSE_FILE_KEY
            )
            or (
                base.startswith("LD_OBJC_RUNTIME_ARGS_")
                and base not in TRUSTED_OBJC_RUNTIME_ARGS
            )
            or (
                base not in SWIFT_TOOL_SELECTORS
                and base.startswith("SWIFT_EXEC_")
                and base.endswith("_EXEC")
            )
            or (
                base not in SWIFT_TOOL_SELECTORS
                and base.startswith("SWIFT_DRIVER_")
                and base.endswith("_EXEC")
            )
            or base.endswith("_COMPILER_LAUNCHER")
        ) and value not in (None, ""):
            errors.append(f"{key_label}: executable override must be empty")
        if base == "INFOPLIST_PREPROCESS" and value != "NO":
            errors.append(f"{key_label}: Info.plist preprocessing must be disabled")
    for key, basenames in {**TOOL_SELECTOR_BASENAMES, **SWIFT_TOOL_SELECTORS}.items():
        if key in settings and not _safe_resolved_tool_selector(
            settings[key], basenames, expected.developer_dir
        ):
            errors.append(
                f"{_safe_setting_key_label(key)}: resolved compiler tool is not trusted"
            )
    if settings.get("ASSETCATALOG_EXEC") != str(
        expected.developer_dir / "usr/bin/actool"
    ):
        errors.append("ASSETCATALOG_EXEC: resolved asset compiler is not trusted")
    if settings.get("CODESIGN") != "/usr/bin/codesign":
        errors.append("CODESIGN: resolved code-signing executable is not trusted")
    expected_codesign_allocate = str(
        expected.developer_dir
        / "Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate"
    )
    if settings.get("CODESIGN_ALLOCATE") != expected_codesign_allocate:
        errors.append("CODESIGN_ALLOCATE: resolved signing helper is not trusted")
    for key, trusted_value in TRUSTED_OBJC_RUNTIME_ARGS.items():
        if settings.get(key) != trusted_value:
            actual = settings.get(key)
            trusted_observed = actual is None or (
                isinstance(actual, str)
                and actual
                in {"", "-fobjc-link-runtime", "-link-objc-runtime"}
            )
            observed = _safe_repr(actual) if trusted_observed else "<redacted>"
            errors.append(
                f"{key}: resolved Objective-C runtime linker args are not trusted; "
                f"got {observed}"
            )
    swift_tools_dir = settings.get("SWIFT_TOOLS_DIR")
    expected_swift_tools_dir = str(
        expected.developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    )
    if swift_tools_dir != expected_swift_tools_dir:
        errors.append("SWIFT_TOOLS_DIR: resolved Swift tool directory is not trusted")
    if settings.get("SWIFT_USE_INTEGRATED_DRIVER") != "YES":
        errors.append("SWIFT_USE_INTEGRATED_DRIVER: integrated Swift driver is required")
    toolchains = settings.get("TOOLCHAINS")
    if toolchains not in (None, "", "com.apple.dt.toolchain.XcodeDefault"):
        errors.append("TOOLCHAINS: resolved toolchain selection is not trusted")
    sdk_root = settings.get("SDKROOT")
    if sdk_root != str(expected.sdk_root):
        sdk_candidate = (
            PurePosixPath(sdk_root) if isinstance(sdk_root, str) else None
        )
        symbolic_sdk = (
            sdk_root
            if isinstance(sdk_root, str)
            and re.fullmatch(r"iphoneos(?:[0-9]+(?:\.[0-9]+)*)?", sdk_root)
            else None
        )
        selected_sdk_basename = (
            sdk_candidate.name
            if sdk_candidate is not None
            and ".." not in sdk_candidate.parts
            and sdk_candidate.parent
            == expected.developer_dir
            / "Platforms/iPhoneOS.platform/Developer/SDKs"
            and re.fullmatch(
                r"iPhoneOS(?:[0-9]+(?:\.[0-9]+)*)?\.sdk", sdk_candidate.name
            )
            else None
        )
        if symbolic_sdk is not None:
            observed_sdk = _safe_repr(symbolic_sdk)
        elif selected_sdk_basename is not None:
            observed_sdk = _safe_repr(selected_sdk_basename)
        else:
            observed_sdk = "<redacted>"
        errors.append(
            "SDKROOT: resolved iPhoneOS SDK is not trusted; "
            f"got {observed_sdk}"
        )
    developer_dir = settings.get("DEVELOPER_DIR")
    if developer_dir != str(expected.developer_dir):
        errors.append("DEVELOPER_DIR: resolved Xcode root does not match the selected toolchain")
    for key in ("DT_TOOLCHAIN_DIR", "TOOLCHAIN_DIR"):
        value = settings.get(key)
        if value != str(
            expected.developer_dir / "Toolchains/XcodeDefault.xctoolchain"
        ):
            errors.append(
                f"{_safe_setting_key_label(key)}: resolved Xcode toolchain directory "
                "is not trusted"
            )
    path_value = settings.get("PATH")
    if not _safe_resolved_path(
        path_value, expected.developer_dir
    ):
        errors.append(
            "PATH: resolved tool search path is not anchored to selected Xcode; "
            f"got {_safe_path_diagnostic(path_value, expected.developer_dir)}"
        )

    info_plist = settings.get("INFOPLIST_FILE")
    if info_plist != INFO_PLIST_SUFFIX:
        errors.append(f"unexpected INFOPLIST_FILE: {_safe_repr(info_plist)}")

    entitlements = settings.get("CODE_SIGN_ENTITLEMENTS")
    if entitlements != ENTITLEMENTS_SUFFIX:
        errors.append(f"unexpected CODE_SIGN_ENTITLEMENTS: {_safe_repr(entitlements)}")

    target_build_dir = settings.get("TARGET_BUILD_DIR")
    resolved_build_dir = _resolved_absolute_path(target_build_dir)
    products_root = _resolved_absolute_path(str(expected.products_root))
    if resolved_build_dir is None:
        errors.append("TARGET_BUILD_DIR must be an absolute path")
    elif products_root is None:
        errors.append("independently expected products root could not be resolved")
    else:
        expected_build_dir = products_root / f"{expected.configuration}-iphoneos"
        if resolved_build_dir != expected_build_dir:
            errors.append(
                "TARGET_BUILD_DIR is outside the independently expected products root"
            )

    wrapper_name = settings.get("WRAPPER_NAME")
    if wrapper_name != APP_WRAPPER_NAME:
        errors.append(f"WRAPPER_NAME must be exactly {APP_WRAPPER_NAME}")

    executable_name = settings.get("EXECUTABLE_NAME")
    if executable_name != APP_EXECUTABLE_NAME:
        errors.append(f"EXECUTABLE_NAME must be exactly {APP_EXECUTABLE_NAME}")

    return settings, errors


def _is_forbidden_artifact_name(name: str) -> bool:
    lowered = name.lower()
    return (
        lowered in FORBIDDEN_BASENAMES
        or lowered.endswith(FORBIDDEN_SUFFIXES)
        or lowered == ".env"
        or lowered.startswith(".env.")
        or (lowered.startswith("ggml-") and lowered.endswith(".bin"))
        or ("whisper" in lowered and lowered.endswith(".bin"))
    )


def _bundle_artifact_errors(app_path: Path, *, signed: bool = False) -> list[str]:
    errors: list[str] = []
    pending: list[tuple[Path, str]] = [(app_path, "")]
    entry_count = 0
    while pending:
        directory, relative_directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    entry_count += 1
                    if entry_count > MAX_BUNDLE_ENTRIES:
                        errors.append(
                            f"app bundle exceeds the {MAX_BUNDLE_ENTRIES}-entry verification limit"
                        )
                        return errors
                    relative = (
                        f"{relative_directory}/{entry.name}"
                        if relative_directory
                        else entry.name
                    )
                    try:
                        if _directory_entry_is_indirection(entry):
                            errors.append(
                                "unsigned Release app contains a symlink or reparse point: "
                                f"{_safe_repr(relative)}"
                            )
                            continue
                        is_directory = entry.is_dir(follow_symlinks=False)
                        is_file = entry.is_file(follow_symlinks=False)
                        signature_parent = PurePosixPath(relative).parent
                        approved_code_signature_parent = (
                            signature_parent == PurePosixPath(".")
                            or signature_parent.suffix.casefold()
                            in {".app", ".appex", ".bundle", ".framework", ".xpc"}
                        )
                        approved_signed_artifact = signed and (
                            (
                                entry.name.casefold() == "_codesignature"
                                and is_directory
                                and approved_code_signature_parent
                            )
                            or (
                                relative.casefold() == "embedded.mobileprovision"
                                and is_file
                            )
                        )
                        if (
                            _is_forbidden_artifact_name(entry.name)
                            and not approved_signed_artifact
                        ):
                            errors.append(
                                "unsigned Release app contains forbidden artifact: "
                                f"{_safe_repr(relative)}"
                            )
                        if is_directory:
                            pending.append((Path(entry.path), relative))
                        elif not is_file:
                            errors.append(
                                "unsigned Release app contains a non-regular artifact: "
                                f"{_safe_repr(relative)}"
                            )
                    except OSError as exc:
                        errors.append(
                            "app bundle entry inspection failed for "
                            f"{_safe_repr(relative)}: {type(exc).__name__}"
                        )
        except OSError as exc:
            errors.append(
                "app bundle traversal failed for "
                f"{_safe_repr(relative_directory or '.')}: {type(exc).__name__}"
            )
    return errors


def _type_sensitive_plist_equal(left: Any, right: Any) -> bool:
    pending: list[tuple[Any, Any]] = [(left, right)]
    visited = 0
    while pending:
        left_value, right_value = pending.pop()
        visited += 1
        if visited > MAX_PLIST_OBJECTS:
            return False
        if type(left_value) is not type(right_value):
            return False
        if isinstance(left_value, dict):
            if left_value.keys() != right_value.keys():
                return False
            pending.extend(
                (left_value[key], right_value[key]) for key in left_value
            )
        elif isinstance(left_value, list):
            if len(left_value) != len(right_value):
                return False
            pending.extend(zip(left_value, right_value))
        elif left_value != right_value:
            return False
    return True


def _validated_icon_names(icons: Any, label: str, errors: list[str]) -> list[str]:
    if not isinstance(icons, dict) or not all(isinstance(key, str) for key in icons):
        errors.append(f"{label} must be a string-keyed dictionary")
        return []
    if set(icons) != {"CFBundlePrimaryIcon"}:
        errors.append(f"{label} must contain only the approved primary AppIcon")

    primary = icons.get("CFBundlePrimaryIcon")
    if not isinstance(primary, dict) or not all(
        isinstance(key, str) for key in primary
    ):
        errors.append(f"{label} CFBundlePrimaryIcon must be a string-keyed dictionary")
        return []
    if set(primary) != {"CFBundleIconName", "CFBundleIconFiles"}:
        errors.append(
            f"{label} CFBundlePrimaryIcon must contain only the exact primary icon keys"
        )
    if primary.get("CFBundleIconName") != APP_ICON_NAME:
        errors.append(f"{label} CFBundleIconName must be exactly {APP_ICON_NAME}")

    icon_files = primary.get("CFBundleIconFiles")
    if (
        not isinstance(icon_files, list)
        or not 1 <= len(icon_files) <= 8
        or any(not isinstance(name, str) for name in icon_files)
    ):
        errors.append(f"{label} CFBundleIconFiles must contain 1 to 8 icon names")
        return []

    validated: list[str] = []
    for name in icon_files:
        if name not in APPROVED_BUILT_ICON_SIZES:
            errors.append(
                f"{label} CFBundleIconFiles contains an unsafe or extension-bearing icon name: {_safe_repr(name)}"
            )
        else:
            validated.append(name)
    if len(set(validated)) != len(validated):
        errors.append(f"{label} CFBundleIconFiles contains duplicate icon names")
    required_primary = (
        "AppIcon76x76" if label == "CFBundleIcons~ipad" else "AppIcon60x60"
    )
    if required_primary not in validated:
        errors.append(
            f"{label} CFBundleIconFiles must include {required_primary}"
        )
    return validated


def _compiled_icon_png_errors(
    path: Path, *, expected_width: int, expected_height: int
) -> list[str]:
    encoded, read_errors = _read_bounded_regular_file(
        path,
        "built AppIcon candidate",
        maximum_bytes=MAX_INPUT_BYTES,
        minimum_bytes=1,
    )
    if encoded is None:
        return read_errors

    if not encoded.startswith(PNG_SIGNATURE):
        return ["built AppIcon candidate has an invalid PNG signature"]

    errors: list[str] = []
    offset = len(PNG_SIGNATURE)
    chunk_count = 0
    saw_ihdr = False
    saw_idat = False
    saw_iend = False
    saw_cgbi = False
    idat_closed = False
    idat_payloads: list[bytes] = []
    seen_unique_chunks: set[bytes] = set()
    width = 0
    height = 0
    channels = 0
    while offset < len(encoded):
        chunk_count += 1
        if chunk_count > MAX_PNG_CHUNKS:
            return ["built AppIcon candidate exceeds the chunk verification limit"]
        if len(encoded) - offset < 12:
            errors.append("built AppIcon candidate has a truncated chunk envelope")
            break
        chunk_size = struct.unpack_from(">I", encoded, offset)[0]
        chunk_end = offset + 12 + chunk_size
        if chunk_end > len(encoded):
            errors.append("built AppIcon candidate chunk exceeds the file")
            break
        chunk_type = encoded[offset + 4 : offset + 8]
        payload = encoded[offset + 8 : offset + 8 + chunk_size]
        recorded_crc = struct.unpack_from(">I", encoded, offset + 8 + chunk_size)[0]
        if zlib.crc32(chunk_type + payload) & 0xFFFFFFFF != recorded_crc:
            errors.append("built AppIcon candidate has an invalid chunk checksum")
            break
        if len(chunk_type) != 4 or any(
            byte not in range(ord("A"), ord("Z") + 1)
            and byte not in range(ord("a"), ord("z") + 1)
            for byte in chunk_type
        ):
            errors.append("built AppIcon candidate contains an invalid chunk type")
            break
        approved_chunks = APPROVED_PNG_CHUNKS | {b"CgBI"}
        if chunk_type not in approved_chunks:
            if chunk_type[0] & 0x20 == 0:
                errors.append("built AppIcon candidate contains an unknown critical chunk")
            else:
                errors.append("built AppIcon candidate contains an unapproved ancillary chunk")
        if chunk_type != b"IDAT":
            if chunk_type in seen_unique_chunks:
                errors.append("built AppIcon candidate contains a duplicate singleton chunk")
            seen_unique_chunks.add(chunk_type)
        if chunk_count == 1 and chunk_type not in {b"IHDR", b"CgBI"}:
            errors.append("built AppIcon candidate must begin with IHDR or CgBI")
        if saw_idat and chunk_type not in {b"IDAT", b"IEND"}:
            idat_closed = True
        if saw_idat and chunk_type in {b"PLTE", b"sRGB", b"gAMA", b"pHYs"}:
            errors.append("built AppIcon candidate metadata chunks must precede IDAT")
        if chunk_type == b"CgBI":
            if chunk_count != 1 or chunk_size not in {0, 4}:
                errors.append("built AppIcon candidate has an invalid CgBI chunk")
            saw_cgbi = True
        if chunk_type == b"IHDR":
            expected_position = 2 if saw_cgbi else 1
            if saw_ihdr or chunk_size != 13 or chunk_count != expected_position:
                errors.append("built AppIcon candidate has an invalid IHDR")
            else:
                saw_ihdr = True
                (
                    width,
                    height,
                    bit_depth,
                    color_type,
                    compression,
                    filtering,
                    interlace,
                ) = struct.unpack(">IIBBBBB", payload)
                if (width, height) != (expected_width, expected_height):
                    errors.append("built AppIcon candidate dimensions do not match its declared filename and scale")
                if bit_depth != 8 or color_type not in (2, 6):
                    errors.append("built AppIcon candidate has an unsupported pixel format")
                channels = 3 if color_type == 2 else 4
                if (compression, filtering, interlace) != (0, 0, 0):
                    errors.append("built AppIcon candidate uses unsupported encoding methods")
        elif chunk_type != b"CgBI" and not saw_ihdr:
            errors.append("built AppIcon candidate must place IHDR immediately after CgBI")
        elif chunk_type == b"IDAT":
            if not saw_ihdr or not payload or idat_closed:
                errors.append("built AppIcon candidate has invalid image data")
            saw_idat = True
            idat_payloads.append(payload)
        elif chunk_type == b"PLTE":
            if not 3 <= chunk_size <= 768 or chunk_size % 3 != 0:
                errors.append("built AppIcon candidate contains an invalid PLTE chunk")
        elif chunk_type == b"sRGB":
            if chunk_size != 1 or payload[0] > 3:
                errors.append("built AppIcon candidate contains an invalid sRGB chunk")
        elif chunk_type == b"gAMA":
            if chunk_size != 4 or struct.unpack(">I", payload)[0] == 0:
                errors.append("built AppIcon candidate contains an invalid gAMA chunk")
        elif chunk_type == b"pHYs":
            if chunk_size != 9 or payload[-1] not in (0, 1):
                errors.append("built AppIcon candidate contains an invalid pHYs chunk")
        elif chunk_type == b"IEND":
            if chunk_size != 0 or chunk_end != len(encoded):
                errors.append("built AppIcon candidate has an invalid IEND")
            saw_iend = True
            offset = chunk_end
            break
        offset = chunk_end

    if not saw_ihdr:
        errors.append("built AppIcon candidate is missing IHDR")
    if not saw_idat:
        errors.append("built AppIcon candidate is missing image data")
    if not saw_iend:
        errors.append("built AppIcon candidate is missing IEND")
    if idat_payloads and width > 0 and height > 0 and channels > 0:
        errors.extend(
            _png_image_data_errors(
                idat_payloads,
                width=width,
                height=height,
                channels=channels,
                label="built AppIcon candidate",
                exact_scanline_description=f"{height} decoded scanlines",
                require_opaque_alpha=channels == 4,
                wbits=-zlib.MAX_WBITS if saw_cgbi else zlib.MAX_WBITS,
            )
        )
    return errors


def _compiled_app_icon_errors(app_path: Path, info: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    device_family = info.get("UIDeviceFamily")
    if not _type_sensitive_plist_equal(device_family, [1]):
        errors.append(
            f"UIDeviceFamily must be the type-exact iPhone family [1], got {_safe_repr(device_family)}"
        )

    unexpected_icon_keys = sorted(
        key
        for key in info
        if isinstance(key, str)
        and (
            key.startswith("CFBundleAlternateIcons")
            or (
                key.startswith("CFBundleIcon")
                and key not in {"CFBundleIcons", "CFBundleIcons~ipad"}
            )
        )
    )
    if unexpected_icon_keys:
        errors.append("built app contains unverified qualified icon metadata")

    validated_icon_names = _validated_icon_names(
        info.get("CFBundleIcons"), "CFBundleIcons", errors
    )
    if "CFBundleIcons~ipad" in info:
        validated_icon_names.extend(
            _validated_icon_names(
                info.get("CFBundleIcons~ipad"), "CFBundleIcons~ipad", errors
            )
        )

    asset_bytes, asset_errors = _read_bounded_regular_file(
        app_path / "Assets.car",
        "compiled Assets.car",
        maximum_bytes=MAX_COMPILED_ASSET_BYTES,
        minimum_bytes=len(COMPILED_ASSET_MAGIC) + 1,
    )
    errors.extend(asset_errors)
    if asset_bytes is not None and not asset_bytes.startswith(COMPILED_ASSET_MAGIC):
        errors.append("compiled Assets.car has an invalid BOMStore header")

    entries, listing_errors = _bounded_directory_entries(
        app_path, MAX_APP_ROOT_ENTRIES, "built app root"
    )
    errors.extend(listing_errors)

    approved_rendered_names: set[str] = set()
    for declared_name in sorted(set(validated_icon_names)):
        logical_size = APPROVED_BUILT_ICON_SIZES.get(declared_name)
        if logical_size is None:
            continue
        allowed_names = {
            f"{declared_name}.png",
            f"{declared_name}@2x.png",
            f"{declared_name}@3x.png",
        }
        approved_rendered_names.update(allowed_names)
        candidates = [entry for entry in entries if entry.name in allowed_names]
        if not candidates:
            errors.append(
                f"built app is missing declared AppIcon files for {declared_name}"
            )
            continue
        required_candidate = (
            f"{declared_name}@2x.png"
            if declared_name in {"AppIcon60x60", "AppIcon76x76"}
            else None
        )
        if required_candidate is not None and not any(
            entry.name == required_candidate for entry in candidates
        ):
            errors.append(
                f"built app is missing required 2x AppIcon file {required_candidate}"
            )
        for entry in candidates:
            scale = 1
            if entry.name.endswith("@2x.png"):
                scale = 2
            elif entry.name.endswith("@3x.png"):
                scale = 3
            expected_size = logical_size * scale
            if not expected_size.is_integer():
                errors.append("built AppIcon candidate has a non-integral declared pixel size")
                continue
            errors.extend(
                _compiled_icon_png_errors(
                    Path(entry.path),
                    expected_width=int(expected_size),
                    expected_height=int(expected_size),
                )
            )

    if any(
        entry.name.lower().endswith(".png")
        and entry.name not in approved_rendered_names
        for entry in entries
    ):
        errors.append("built app contains an alternate icon artifact")
    return errors


def _thin_arm64_macho_errors(stream: Any, file_size: int) -> list[str]:
    if file_size < MACH_O_64_HEADER_SIZE:
        return ["built app executable has a truncated Mach-O header"]

    header = stream.read(MACH_O_64_HEADER_SIZE)
    if len(header) != MACH_O_64_HEADER_SIZE or header[:4] != MACH_O_64_LE_MAGIC:
        return ["built app executable is not a thin 64-bit little-endian Mach-O binary"]

    (
        _,
        cpu_type,
        _,
        file_type,
        load_command_count,
        load_command_bytes,
        _,
        _,
    ) = struct.unpack("<8I", header)
    errors: list[str] = []
    if cpu_type != CPU_TYPE_ARM64:
        errors.append("built app executable is not an arm64 Mach-O binary")
    if file_type != MH_EXECUTE:
        errors.append("built app Mach-O file type is not MH_EXECUTE")
    if not 1 <= load_command_count <= MAX_LOAD_COMMANDS:
        errors.append("built app Mach-O has an invalid load-command count")
    if not 8 <= load_command_bytes <= MAX_LOAD_COMMAND_BYTES:
        errors.append("built app Mach-O has an invalid load-command byte count")
    if load_command_bytes < load_command_count * 8:
        errors.append("built app Mach-O load-command table is too small")
    if MACH_O_64_HEADER_SIZE + load_command_bytes > file_size:
        errors.append("built app Mach-O load-command table exceeds the executable")
    if errors:
        return errors

    commands = stream.read(load_command_bytes)
    if len(commands) != load_command_bytes:
        return ["built app Mach-O load-command table is truncated"]

    cursor = 0
    has_file_backed_text_segment = False
    for _ in range(load_command_count):
        if cursor + 8 > len(commands):
            errors.append("built app Mach-O load-command header is truncated")
            break
        command, command_size = struct.unpack_from("<II", commands, cursor)
        if command_size < 8 or command_size % 8 != 0:
            errors.append("built app Mach-O contains an invalid load-command size")
            break
        command_end = cursor + command_size
        if command_end > len(commands):
            errors.append("built app Mach-O load command exceeds its command table")
            break

        if command == LC_SEGMENT_64:
            if command_size < SEGMENT_COMMAND_64_SIZE:
                errors.append("built app Mach-O contains a truncated LC_SEGMENT_64")
                break
            section_count = struct.unpack_from("<I", commands, cursor + 64)[0]
            expected_segment_size = (
                SEGMENT_COMMAND_64_SIZE + section_count * SECTION_64_SIZE
            )
            if command_size != expected_segment_size:
                errors.append("built app Mach-O LC_SEGMENT_64 size is inconsistent")
                break
            file_offset, segment_file_size = struct.unpack_from(
                "<QQ", commands, cursor + 40
            )
            if file_offset > file_size or segment_file_size > file_size - file_offset:
                errors.append("built app Mach-O segment exceeds the executable")
                break
            segment_name = commands[cursor + 8 : cursor + 24].rstrip(b"\0")
            if (
                segment_name == b"__TEXT"
                and file_offset == 0
                and segment_file_size >= MACH_O_64_HEADER_SIZE + load_command_bytes
            ):
                has_file_backed_text_segment = True
        cursor = command_end

    if cursor != len(commands):
        errors.append("built app Mach-O load-command byte count is inconsistent")
    if not has_file_backed_text_segment:
        errors.append("built app Mach-O lacks a file-backed __TEXT segment")
    return errors


def _executable_errors(executable_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        path_stat = executable_path.lstat()
        if _stat_is_indirection(path_stat):
            return ["built app executable must not be a symlink or reparse point"]
    except OSError:
        pass
    descriptor, executable_stat, open_errors = _open_regular_fd(
        executable_path, "built app executable"
    )
    if descriptor is None or executable_stat is None:
        return [f"built app executable could not be inspected: {open_errors[0]}"]
    try:
        if os.name == "posix" and executable_stat.st_mode & 0o111 == 0:
            errors.append("built app executable does not have an executable mode bit")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            errors.extend(_thin_arm64_macho_errors(stream, executable_stat.st_size))
            final_stat = os.fstat(stream.fileno())
        if _opened_file_changed(executable_path, executable_stat, final_stat):
            errors.append("built app executable changed during verification")
    except (OSError, struct.error) as exc:
        errors.append(
            f"built app executable could not be inspected: {type(exc).__name__}"
        )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return errors


def _verify_app_bundle_contents(
    app_path: Path,
    source_privacy_path: Path,
    expected: Expectations | BundleExpectations,
    *,
    expected_executable: str,
    signed: bool,
) -> list[str]:
    errors: list[str] = []
    try:
        app_path_stat = app_path.lstat()
    except OSError:
        return ["built app is missing or is not a regular directory"]
    if _stat_is_indirection(app_path_stat) or not stat.S_ISDIR(app_path_stat.st_mode):
        return ["built app is missing or is not a regular directory"]

    info, info_errors = _read_plist(app_path / "Info.plist", "built Info.plist")
    errors.extend(info_errors)
    if info is not None:
        _require_exact(
            info,
            {
                "CFBundleIdentifier": expected.bundle_id,
                "CFBundleShortVersionString": expected.marketing_version,
                "CFBundleVersion": expected.build_number,
                "SENTI_API_URL": expected.api_url,
                "SENTI_GATEWAY_URL": expected.gateway_url,
                "MinimumOSVersion": expected.deployment_target,
                "CFBundlePackageType": "APPL",
                "CFBundleDisplayName": APP_DISPLAY_NAME,
            },
            errors,
        )
        background_modes = info.get("UIBackgroundModes")
        if (
            not isinstance(background_modes, list)
            or any(not isinstance(mode, str) for mode in background_modes)
            or sorted(background_modes) != ["audio", "voip"]
        ):
            errors.append(
                f"UIBackgroundModes must be exactly audio and voip, got {_safe_repr(background_modes)}"
            )

        errors.extend(_compiled_app_icon_errors(app_path, info))

        executable = info.get("CFBundleExecutable")
        if executable != expected_executable:
            errors.append("CFBundleExecutable does not match the expected executable")
        elif isinstance(executable, str):
            errors.extend(_executable_errors(app_path / executable))

    source_privacy, source_errors = _read_plist(
        source_privacy_path, "source PrivacyInfo.xcprivacy"
    )
    bundled_privacy, bundled_errors = _read_plist(
        app_path / "PrivacyInfo.xcprivacy", "bundled PrivacyInfo.xcprivacy"
    )
    errors.extend(source_errors)
    errors.extend(bundled_errors)
    if source_privacy is not None and bundled_privacy is not None:
        if not _type_sensitive_plist_equal(bundled_privacy, source_privacy):
            errors.append(
                "bundled privacy manifest differs type-sensitively from source"
            )

    errors.extend(_bundle_artifact_errors(app_path, signed=signed))
    return errors


def verify_bundle(
    settings_path: Path,
    source_privacy_path: Path,
    expected: Expectations,
) -> list[str]:
    settings, errors = verify_settings_file(settings_path, expected)
    if settings is None or errors:
        return errors
    if expected.configuration != "Release":
        return ["bundle verification is defined only for the Release configuration"]

    app_path = Path(settings["TARGET_BUILD_DIR"]) / settings["WRAPPER_NAME"]
    return _verify_app_bundle_contents(
        app_path,
        source_privacy_path,
        expected,
        expected_executable=settings["EXECUTABLE_NAME"],
        signed=False,
    )


def verify_signed_bundle(
    app_path: Path,
    source_privacy_path: Path,
    expected: BundleExpectations,
) -> list[str]:
    expectation_errors = validate_bundle_expectations(expected)
    if expectation_errors:
        return expectation_errors
    return _verify_app_bundle_contents(
        app_path,
        source_privacy_path,
        expected,
        expected_executable=APP_EXECUTABLE_NAME,
        signed=True,
    )


def _add_expectation_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--settings-json", required=True, type=Path)
    parser.add_argument("--project-file", required=True, type=Path)
    parser.add_argument("--target", default="SentiPocketApp")
    parser.add_argument("--configuration", required=True, choices=("Debug", "Release"))
    parser.add_argument(
        "--aps-environment", required=True, choices=("development", "production")
    )
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--gateway-url", required=True)
    parser.add_argument("--deployment-target", default="16.0")
    parser.add_argument("--products-root", required=True, type=Path)
    parser.add_argument("--developer-dir", required=True, type=PurePosixPath)
    parser.add_argument("--sdk-root", required=True, type=PurePosixPath)


def _expectations_from_args(args: argparse.Namespace) -> Expectations:
    return Expectations(
        target=args.target,
        configuration=args.configuration,
        aps_environment=args.aps_environment,
        bundle_id=args.bundle_id,
        marketing_version=args.marketing_version,
        build_number=args.build_number,
        api_url=args.api_url,
        gateway_url=args.gateway_url,
        deployment_target=args.deployment_target,
        products_root=args.products_root,
        project_file=args.project_file,
        developer_dir=args.developer_dir,
        sdk_root=args.sdk_root,
    )


def _add_bundle_identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--gateway-url", required=True)
    parser.add_argument("--deployment-target", default="16.0")


def _bundle_expectations_from_args(args: argparse.Namespace) -> BundleExpectations:
    return BundleExpectations(
        bundle_id=args.bundle_id,
        marketing_version=args.marketing_version,
        build_number=args.build_number,
        api_url=args.api_url,
        gateway_url=args.gateway_url,
        deployment_target=args.deployment_target,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify unsigned Senti Pocket Xcode settings and Release bundle evidence."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight_parser = subparsers.add_parser(
        "preflight", help="verify source-only AppIcon and local package evidence"
    )
    preflight_parser.add_argument("--repository-root", required=True, type=Path)

    source_parser = subparsers.add_parser(
        "source", help="verify the generated Xcode project and source evidence"
    )
    source_parser.add_argument("--project-file", required=True, type=Path)

    signed_bundle_parser = subparsers.add_parser(
        "signed-bundle", help="verify an exported signed Release app bundle"
    )
    signed_bundle_parser.add_argument("--app-path", required=True, type=Path)
    signed_bundle_parser.add_argument("--source-privacy", required=True, type=Path)
    _add_bundle_identity_arguments(signed_bundle_parser)

    settings_parser = subparsers.add_parser(
        "settings", help="verify one target settings JSON"
    )
    _add_expectation_arguments(settings_parser)

    bundle_parser = subparsers.add_parser(
        "bundle", help="verify the built unsigned Release .app"
    )
    _add_expectation_arguments(bundle_parser)
    bundle_parser.add_argument("--source-privacy", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "preflight":
        errors = verify_preflight(args.repository_root)
        configuration = "source"
        aps_environment = "not-applicable"
    elif args.command == "source":
        errors = verify_source(args.project_file)
        configuration = "generated-project"
        aps_environment = "not-applicable"
    elif args.command == "signed-bundle":
        errors = verify_signed_bundle(
            args.app_path,
            args.source_privacy,
            _bundle_expectations_from_args(args),
        )
        configuration = "signed-release"
        aps_environment = "production"
    else:
        expected = _expectations_from_args(args)
        configuration = expected.configuration
        aps_environment = expected.aps_environment
        if args.command == "settings":
            _, errors = verify_settings_file(args.settings_json, expected)
        else:
            errors = verify_bundle(args.settings_json, args.source_privacy, expected)

    if errors:
        for error in errors:
            print(f"verify_unsigned_release: {error}", file=sys.stderr)
        return 1
    print(
        "verify_unsigned_release: "
        f"{args.command} passed for {configuration}/{aps_environment}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
