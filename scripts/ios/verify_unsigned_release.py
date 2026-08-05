#!/usr/bin/env python3
"""Verify resolved unsigned iOS settings and the resulting Release .app.

This verifier intentionally stops at the unsigned-build boundary. It proves Xcode
configuration resolution and packaged resources; it does not prove signing,
provisioning, embedded entitlements, APNs delivery, or physical-device behavior.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import plistlib
import re
import shlex
import stat
import struct
import sys
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlsplit


MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_PROJECT_BYTES = 16 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 100_000
FIXTURE_NAME = "canonical_checkpoint.json"
ENTITLEMENTS_SUFFIX = "Sources/SentiPocketApp.entitlements"
INFO_PLIST_SUFFIX = "Sources/Info.plist"
APP_WRAPPER_NAME = "SentiPocketApp.app"
APP_EXECUTABLE_NAME = "SentiPocketApp"
APP_DISPLAY_NAME = "Senti Pocket"
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
SENSITIVE_SETTING_KEYS = frozenset({"SENTI_API_URL", "SENTI_GATEWAY_URL"})


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


def _safe_repr(value: Any) -> str:
    rendered = repr(value)
    if len(rendered) > 180:
        return rendered[:177] + "..."
    return rendered


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
    return errors


def _read_json(path: Path) -> tuple[Any | None, list[str]]:
    try:
        if path.is_symlink() or not path.is_file():
            return None, [f"settings JSON is not a regular file: {path.name}"]
        if path.stat().st_size > MAX_INPUT_BYTES:
            return None, ["settings JSON exceeds the 8 MiB verification limit"]
        with path.open(encoding="utf-8") as stream:
            return json.load(stream), []
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        return None, [f"settings JSON could not be decoded: {type(exc).__name__}"]


def _generated_project_errors(path: Path) -> list[str]:
    try:
        project_stat = path.lstat()
        if stat.S_ISLNK(project_stat.st_mode) or not stat.S_ISREG(project_stat.st_mode):
            return ["generated Xcode project is not a regular file"]
        if project_stat.st_size > MAX_PROJECT_BYTES:
            return ["generated Xcode project exceeds the 16 MiB verification limit"]
        with path.open("rb") as stream:
            encoded_project = stream.read(MAX_PROJECT_BYTES + 1)
        if len(encoded_project) > MAX_PROJECT_BYTES:
            return ["generated Xcode project exceeds the 16 MiB verification limit"]
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
    return errors


def _read_plist(path: Path, label: str) -> tuple[dict[str, Any] | None, list[str]]:
    try:
        if path.is_symlink() or not path.is_file():
            return None, [f"{label} is not a regular file"]
        if path.stat().st_size > MAX_INPUT_BYTES:
            return None, [f"{label} exceeds the 8 MiB verification limit"]
        with path.open("rb") as stream:
            payload = plistlib.load(stream)
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

    errors.extend(_generated_project_errors(expected.project_file))

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
            "IPHONEOS_DEPLOYMENT_TARGET": expected.deployment_target,
        },
        errors,
    )

    if settings.get("DEVELOPMENT_TEAM", "") != "":
        errors.append("DEVELOPMENT_TEAM must be empty for unsigned verification")

    _verify_swift_compilation_conditions(settings, expected.configuration, errors)

    info_plist = settings.get("INFOPLIST_FILE")
    if info_plist != INFO_PLIST_SUFFIX:
        errors.append(f"unexpected INFOPLIST_FILE: {_safe_repr(info_plist)}")

    entitlements = settings.get("CODE_SIGN_ENTITLEMENTS")
    if entitlements != ENTITLEMENTS_SUFFIX:
        errors.append(f"unexpected CODE_SIGN_ENTITLEMENTS: {_safe_repr(entitlements)}")

    excluded_raw = settings.get("EXCLUDED_SOURCE_FILE_NAMES", "")
    if not isinstance(excluded_raw, str):
        errors.append("EXCLUDED_SOURCE_FILE_NAMES must resolve to a string")
        excluded: set[str] = set()
    else:
        try:
            excluded = set(shlex.split(excluded_raw))
        except ValueError:
            excluded = set()
            errors.append(
                "EXCLUDED_SOURCE_FILE_NAMES contains invalid shell-style quoting"
            )
    fixture_is_excluded = any(
        fnmatchcase(FIXTURE_NAME, pattern) for pattern in excluded
    )
    if expected.configuration == "Release" and not fixture_is_excluded:
        errors.append(f"{FIXTURE_NAME} is not excluded from Release")
    if expected.configuration == "Debug" and fixture_is_excluded:
        errors.append(f"{FIXTURE_NAME} is unexpectedly excluded from Debug")

    target_build_dir = settings.get("TARGET_BUILD_DIR")
    if (
        not isinstance(target_build_dir, str)
        or not Path(target_build_dir).is_absolute()
    ):
        errors.append("TARGET_BUILD_DIR must be an absolute path")
    else:
        products_root = expected.products_root.resolve(strict=False)
        expected_build_dir = products_root / f"{expected.configuration}-iphoneos"
        resolved_build_dir = Path(target_build_dir).resolve(strict=False)
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


def _bundle_artifact_errors(app_path: Path) -> list[str]:
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
                        if entry.is_symlink():
                            errors.append(
                                f"unsigned Release app contains a symlink: {_safe_repr(relative)}"
                            )
                            continue
                        if _is_forbidden_artifact_name(entry.name):
                            errors.append(
                                "unsigned Release app contains forbidden artifact: "
                                f"{_safe_repr(relative)}"
                            )
                        if entry.is_dir(follow_symlinks=False):
                            pending.append((Path(entry.path), relative))
                        elif not entry.is_file(follow_symlinks=False):
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
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(
            _type_sensitive_plist_equal(left[key], right[key]) for key in left
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(
            _type_sensitive_plist_equal(left_item, right_item)
            for left_item, right_item in zip(left, right)
        )
    return left == right


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
        executable_stat = executable_path.lstat()
        if stat.S_ISLNK(executable_stat.st_mode):
            return ["built app executable must not be a symlink"]
        if not stat.S_ISREG(executable_stat.st_mode):
            return ["built app executable is missing or is not a regular file"]
        if os.name == "posix" and executable_stat.st_mode & 0o111 == 0:
            errors.append("built app executable does not have an executable mode bit")
        with executable_path.open("rb") as stream:
            errors.extend(_thin_arm64_macho_errors(stream, executable_stat.st_size))
    except (OSError, struct.error) as exc:
        errors.append(
            f"built app executable could not be inspected: {type(exc).__name__}"
        )
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

    target_build_dir = settings["TARGET_BUILD_DIR"]
    wrapper_name = settings["WRAPPER_NAME"]
    app_path = Path(target_build_dir) / wrapper_name
    if app_path.is_symlink() or not app_path.is_dir():
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

        executable = info.get("CFBundleExecutable")
        if executable != settings.get("EXECUTABLE_NAME"):
            errors.append("CFBundleExecutable does not match resolved EXECUTABLE_NAME")
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

    errors.extend(_bundle_artifact_errors(app_path))
    return errors


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
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify unsigned Senti Pocket Xcode settings and Release bundle evidence."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

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
    expected = _expectations_from_args(args)
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
        f"{args.command} passed for {expected.configuration}/{expected.aps_environment}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
