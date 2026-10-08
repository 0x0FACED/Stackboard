#!/usr/bin/env python3
"""Private, standard-library verifier used by package-release.sh on macOS."""

import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import unicodedata
import zipfile
from collections import deque
from pathlib import Path

BUNDLE_IDENTIFIER = "dev.0xfaced.Stackboard"
ARCHITECTURES = {"arm64", "x86_64"}
MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def run(*command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, "{} failed: {}".format(
        command[0], (result.stderr or result.stdout).decode("utf-8", "replace").strip()))
    return result.stdout, result.stderr


def verify_archive(archive_path, checksum_path):
    for path in (archive_path, checksum_path):
        require(stat.S_ISREG(os.lstat(path).st_mode), "Artifact must be a regular, non-symlink file: " + path)
    with open(checksum_path, "r", encoding="ascii") as stream:
        checksum = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]Stackboard\.zip\n?", stream.read())
    require(checksum is not None, "SHA256SUMS must contain exactly one shasum-compatible Stackboard.zip entry")
    sha256 = digest(archive_path)
    require(sha256 == checksum.group(1).lower(), "Stackboard.zip does not match SHA256SUMS")

    # Validate every member before ditto sees the archive. Include Apple's
    # sequestered resource-fork entries, but no other top-level roots.
    members, symlinks, known, aliases, metadata_targets = {}, {}, set(), {}, []
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            name = info.filename.rstrip("/")
            parts = name.split("/")
            require(info.filename == info.orig_filename and "\x00" not in name and "\\" not in name,
                    "Invalid ZIP member name")
            require(all(part not in ("", ".", "..") for part in parts), "Unsafe ZIP path: " + name)
            require(name not in members, "Duplicate ZIP member: " + name)
            require(not info.flag_bits & 1, "Encrypted ZIP members are not supported")
            require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    "Unsupported ZIP compression: " + name)
            # ZipFile.open checks that the local header's filename matches the
            # central directory; a malicious streaming header must not bypass
            # the path checks above when ditto extracts it.
            with archive.open(info):
                pass
            mode = (info.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "Unsafe ZIP member type: " + name)
            directory = info.is_dir()
            require(info.filename == name + ("/" if directory else ""), "Noncanonical ZIP path: " + name)
            require((kind != stat.S_IFDIR or directory) and (not directory or kind in (0, stat.S_IFDIR)),
                    "Inconsistent ZIP member type: " + name)
            if parts[0] == "Stackboard.app":
                require(len(parts) > 1 or directory, "Stackboard.app must be a directory")
            elif parts[0] == "__MACOSX":
                require(kind != stat.S_IFLNK, "Resource-fork entries must not be symlinks")
                if directory:
                    require(len(parts) == 1 or parts[1] == "Stackboard.app", "Unexpected resource-fork directory: " + name)
                else:
                    require((len(parts) == 2 and parts[1] == "._Stackboard.app") or
                            (len(parts) > 2 and parts[1] == "Stackboard.app" and
                             parts[-1].startswith("._") and len(parts[-1]) > 2),
                            "Unexpected resource-fork file: " + name)
                    metadata_targets.append("/".join(parts[1:-1] + [parts[-1][2:]]))
            else:
                raise ValueError("Unexpected ZIP root: " + name)
            members[name] = "directory" if directory else "symlink" if kind == stat.S_IFLNK else "file"
            for length in range(1, len(parts) + 1):
                prefix = "/".join(parts[:length])
                alias = unicodedata.normalize("NFD", prefix).casefold()
                require(alias not in aliases or aliases[alias] == prefix, "Case/Unicode ZIP path collision: " + name)
                aliases[alias] = prefix
                known.add(prefix)
            if kind == stat.S_IFLNK:
                require(info.file_size <= 4096, "Invalid ZIP symlink target: " + name)
                target = archive.read(info).decode("utf-8")
                require(target and not target.startswith("/") and "\\" not in target and "\x00" not in target,
                        "Unsafe ZIP symlink: " + name)
                symlinks[name] = target

    require("Stackboard.app/Contents/Info.plist" in members and
            "Stackboard.app/Contents/MacOS" in known, "Archive does not contain a complete Stackboard.app")
    for name in members:
        parts = name.split("/")
        for length in range(1, len(parts)):
            parent = "/".join(parts[:length])
            require(members.get(parent, "directory") == "directory", "ZIP member descends through a file or symlink: " + name)
    require(all(target in known for target in metadata_targets), "Resource-fork entry has no corresponding app member")
    for name, target in symlinks.items():
        # Resolve links as the filesystem would, including intermediate links;
        # lexical '..' normalization alone would miss chained escapes.
        pending = deque(name.split("/")[:-1] + target.split("/"))
        resolved, followed = [], 0
        while pending:
            part = pending.popleft()
            if part in ("", "."):
                continue
            if part == "..":
                require(len(resolved) > 1, "ZIP symlink escapes the app: " + name)
                resolved.pop()
                continue
            candidate = "/".join(resolved + [part])
            if candidate in symlinks:
                followed += 1
                require(followed <= 40, "ZIP symlink cycle: " + name)
                pending.extendleft(reversed(symlinks[candidate].split("/")))
            else:
                resolved.append(part)
                require(resolved[0] == "Stackboard.app", "ZIP symlink escapes the app: " + name)
        require("/".join(resolved) in known, "Dangling ZIP symlink: " + name)
    print(sha256)


def verify_app(app_path, version, sha256, metadata_path, expected_build=None):
    app = Path(app_path)
    require(app.is_dir() and not app.is_symlink(), "Missing Stackboard.app")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleShortVersionString") == version, "App version does not match requested release")
    build = info.get("CFBundleVersion")
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build), "App has an invalid build number")
    require(expected_build is None or build == expected_build, "App build number does not match BUILD_NUMBER")
    require(info.get("CFBundleIdentifier") == BUNDLE_IDENTIFIER, "Unexpected app bundle identifier")
    minimum = info.get("LSMinimumSystemVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}", minimum),
            "App has an invalid numeric minimum macOS version")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable not in ("", ".", "..") and
            "/" not in executable and "\\" not in executable, "App has an invalid executable name")
    binary = app / "Contents/MacOS" / executable
    require(binary.is_file(), "App executable is missing")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))

    # Validate every packaged Mach-O, including nested frameworks/helpers, so
    # one universal executable cannot hide an Intel-only or developer-signed dependency.
    code_objects = [(app, binary)]
    for directory, _, files in os.walk(app, followlinks=False):
        for filename in files:
            path = Path(directory) / filename
            if path.is_symlink() or path == binary:
                continue
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    code_objects.append((path, path))
    for code, executable_path in code_objects:
        architectures, _ = run("/usr/bin/lipo", "-archs", str(executable_path))
        require(set(architectures.decode("ascii").split()) == ARCHITECTURES, "Code is not Universal arm64+x86_64: " + str(code))
        for architecture in sorted(ARCHITECTURES):
            stdout, stderr = run("/usr/bin/codesign", "--display", "--verbose=4", "--architecture", architecture, str(code))
            signature = (stdout + stderr).decode("utf-8", "replace").splitlines()
            require("Signature=adhoc" in signature and "TeamIdentifier=not set" in signature and
                    not any(line.startswith("Authority=") for line in signature), "Code is not ad-hoc/no-Team signed: " + str(code))
            if code == app:
                require("Identifier=" + BUNDLE_IDENTIFIER in signature, "Unexpected code-signing identifier")
            entitlements, _ = run("/usr/bin/codesign", "--display", "--architecture", architecture,
                                  "--entitlements", "-", "--xml", str(code))
            if entitlements.strip():
                values = plistlib.loads(entitlements)
                require(isinstance(values, dict), "Invalid signed entitlements")
                for key in ("com.apple.security.get-task-allow", "get-task-allow"):
                    require(key not in values or values[key] is False, "Debug get-task-allow entitlement is enabled")
    metadata = {
        "version": version,
        "build_number": build,
        "bundle_identifier": BUNDLE_IDENTIFIER,
        "minimum_macos": minimum,
        "architectures": ["arm64", "x86_64"],
        "sha256": sha256,
    }
    with open(metadata_path, "x", encoding="utf-8") as stream:
        json.dump(metadata, stream, indent=2)
        stream.write("\n")


def tree_contents(root):
    entries = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            mode = os.lstat(path).st_mode
            require(stat.S_ISDIR(mode) or stat.S_ISLNK(mode) or stat.S_ISREG(mode), "Unsupported existing app entry: " + str(path))
            content = os.readlink(path) if stat.S_ISLNK(mode) else digest(path) if stat.S_ISREG(mode) else None
            entries[str(path.relative_to(root))] = (stat.S_IFMT(mode), stat.S_IMODE(mode), content)
    return entries


def publish(stage_path, output_path):
    stage, output = Path(stage_path), Path(output_path)
    allowed = {"Stackboard.app", "Stackboard.zip", "SHA256SUMS", "release.json"}
    require(all(path.name in allowed for path in output.iterdir()), "Output directory acquired unexpected contents")
    pending = []
    # Preflight every collision before creating any final output. Existing
    # matching files/apps are left untouched, making verification repeatable.
    for source in stage.iterdir():
        destination = output / source.name
        require(not destination.is_symlink(), "Refusing to replace output symlink: " + str(destination))
        if destination.exists():
            if source.name == "Stackboard.app":
                require(destination.is_dir() and tree_contents(source) == tree_contents(destination),
                        "Existing Stackboard.app differs from the verified archive")
            elif source.name == "release.json":
                with source.open(encoding="utf-8") as left, destination.open(encoding="utf-8") as right:
                    require(json.load(left) == json.load(right), "Existing release.json differs from the verified artifact")
            else:
                require(destination.is_file() and digest(source) == digest(destination),
                        "Refusing to replace existing output artifact: " + str(destination))
        else:
            pending.append((source, destination))
    for source, destination in pending:
        if source.name == "Stackboard.app":
            destination.mkdir()  # Exclusive creation: ditto must never merge into an unrelated app.
            run("/usr/bin/ditto", str(source), str(destination))
        else:
            with source.open("rb") as reader, destination.open("xb") as writer:
                shutil.copyfileobj(reader, writer, length=1024 * 1024)


def main():
    arguments = sys.argv[1:]
    if len(arguments) == 3 and arguments[0] == "archive":
        verify_archive(*arguments[1:])
    elif len(arguments) in (5, 6) and arguments[0] == "app":
        verify_app(*arguments[1:])
    elif len(arguments) == 3 and arguments[0] == "publish":
        publish(*arguments[1:])
    else:
        raise ValueError("Private helper expects archive ZIP SHA256SUMS, app APP VERSION SHA256 JSON [BUILD], or publish STAGE DIRECTORY")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print("verify-release: " + str(error), file=sys.stderr)
        sys.exit(1)
