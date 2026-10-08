#!/usr/bin/env python3
"""Update literal Stackboard cask metadata without fetching or executing Ruby."""

import argparse
import os
from pathlib import Path
import re
import stat
import tempfile


SOURCE_URL = (
    "https://github.com/0x0FACED/stackboard/releases/download/"
    "v#{version}/Stackboard.zip"
)
_STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
_MACOS_VERSION = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}\Z")
_MACOS_RELEASES = {13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe"}
_OWNED_FIELD = re.compile(r"^\s*(cask|version|sha256|url|app)\b")
_HEREDOC = re.compile(
    r"<<(?P<indent>[-~]?)(?:(?P<quote>['\"])(?P<quoted>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?P=quote)|(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"
)
_BLOCK_START = re.compile(r"^\s*(?:if|unless|case|begin|def|class|module|while|until|for)\b")
_DO = re.compile(r"(?<![\w.:])do\b")


class UpdateError(ValueError):
    """The input or cask cannot be safely updated."""


def _version(value, *, allow_prefix):
    normalized = value[1:] if allow_prefix and value.startswith("v") else value
    if not _STABLE_VERSION.fullmatch(normalized):
        raise UpdateError("version must be canonical stable X.Y.Z (optional input v prefix)")
    return normalized


def _sha256(value):
    if not _SHA256.fullmatch(value):
        raise UpdateError("sha256 must contain exactly 64 hexadecimal characters")
    return value.lower()


def _macos_symbol(value):
    if not _MACOS_VERSION.fullmatch(value) or int(value.split(".")[0]) == 0:
        raise UpdateError("minimum macOS must be a numeric version with 1–3 canonical components")
    major = int(value.split(".")[0])
    if major not in _MACOS_RELEASES:
        raise UpdateError(f"unsupported minimum macOS release {value}; supported majors are 13, 14, 15, 26")
    return _MACOS_RELEASES[major]


def _mask_literals(line):
    """Hide quoted text/comments so caveats cannot impersonate metadata or blocks."""
    masked = list(line)
    quote = None
    escaped = False
    comment = len(line)
    for index, char in enumerate(line):
        if quote:
            masked[index] = " "
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "\"'`":
            quote = char
            masked[index] = " "
        elif char == "#":
            comment = index
            masked[index:] = " " * (len(line) - index)
            break
    if quote:
        raise UpdateError("multiline or unterminated quoted statements are unsupported")
    return "".join(masked), line[:comment].rstrip()


def _literal(keyword):
    return re.compile(rf"\s*{keyword}\s+(?P<quote>['\"])(?P<value>[^'\"]*)(?P=quote)\s*")


def _parse_cask(lines):
    """Read only literal top-level owned stanzas; never evaluate arbitrary Ruby."""
    fields = {}
    depth = 0
    opened = False
    closed = False
    delimiters = []
    heredoc = None
    for index, line in enumerate(lines):
        body = line.rstrip("\r\n")
        if heredoc:
            marker, indented = heredoc
            if (body.lstrip(" \t") if indented else body) == marker:
                heredoc = None
            continue
        code, statement = _mask_literals(body)
        if not code.strip():
            continue
        if closed:
            raise UpdateError("unexpected statements after the cask")
        if ";" in code:
            raise UpdateError("multiple statements on one line are unsupported")
        markers = list(re.finditer(r"<<", code))
        if markers:
            match = _HEREDOC.match(body, markers[0].start())
            if len(markers) != 1 or match is None:
                raise UpdateError("unsupported heredoc statement")
            heredoc = (match.group("quoted") or match.group("bare"), bool(match.group("indent")))
        field_match = _OWNED_FIELD.match(code)
        field = field_match.group(1) if field_match else None
        if re.match(r"\s*depends_on\b", code) and re.search(r"\bmacos\b", code):
            field = "minimum_macos"
        if field == "cask":
            if opened or delimiters or not re.fullmatch(r"\s*cask\s+(['\"])stackboard\1\s+do\s*", statement):
                raise UpdateError('expected one cask "stackboard" do')
            opened = True
            depth = 1
            continue
        if not opened:
            raise UpdateError("expected the Stackboard cask before other statements")
        if field:
            if depth != 1 or delimiters:
                raise UpdateError(f"{field} must be an unconditional top-level stanza")
            if field in fields:
                raise UpdateError(f"ambiguous duplicate {field} stanza")
            if field == "minimum_macos":
                match = re.fullmatch(
                    r"\s*depends_on\s+macos:\s*:(?P<value>[a-z][a-z0-9_]*)\s*",
                    statement,
                )
            else:
                match = _literal(field).fullmatch(statement)
            if match is None:
                raise UpdateError(f"unsupported or malformed {field} stanza")
            if field == "url" and (match.group("quote") != '"' or match.group("value") != SOURCE_URL):
                raise UpdateError("source URL must be the versioned Stackboard GitHub ZIP")
            if field == "app" and match.group("value") != "Stackboard.app":
                raise UpdateError('app must be "Stackboard.app"')
            fields[field] = (index, match.span("value"), match.group("value"))
        for char in code:
            if char in "([{":
                delimiters.append(char)
            elif char in ")]}":
                if not delimiters or delimiters.pop() != {")": "(", "]": "[", "}": "{"}[char]:
                    raise UpdateError("unbalanced cask delimiters")
        if re.match(r"\s*end\b", code):
            if delimiters or not re.fullmatch(r"\s*end\s*", code):
                raise UpdateError("unsupported cask block terminator")
            depth -= 1
            if depth == 0:
                closed = True
        elif _BLOCK_START.match(code) or _DO.search(code):
            depth += 1
    if heredoc or delimiters or not closed or depth != 0:
        raise UpdateError("unterminated cask, block, delimiter, or heredoc")
    for field in ("version", "sha256", "url", "app"):
        if field not in fields:
            raise UpdateError(f"missing {field} stanza")
    _version(fields["version"][2], allow_prefix=False)
    _sha256(fields["sha256"][2])
    if "minimum_macos" in fields and fields["minimum_macos"][2] not in _MACOS_RELEASES.values():
        raise UpdateError("unsupported macOS release symbol in cask")
    return fields


def update_cask(cask_path, *, version, sha256, minimum_macos):
    """Atomically update a cask, returning True if its bytes changed.

    Inputs accept stable X.Y.Z (optionally v-prefixed), a 64-digit hex SHA,
    and numeric macOS versions with 1–3 components in known majors 13, 14,
    15, or 26. Homebrew represents only major releases, so the minimum is
    mapped to its release symbol; minors remain enforced by the app itself.
    Owned cask stanzas must be unique literal top-level declarations, with
    the exact source/app and a supported symbolic macOS dependency.
    Comments, ordinary quoted lines, heredocs, and unrelated blocks are
    preserved; this is not a general Ruby parser. Unsupported owned forms
    fail closed. Downgrades and changed artifacts at the same version fail
    before writing. UpdateError covers input/metadata errors; I/O and UTF-8
    errors propagate. No network, Ruby execution, or Git operations occur.
    """
    version = _version(version, allow_prefix=True)
    sha256 = _sha256(sha256)
    macos_symbol = _macos_symbol(minimum_macos)
    path = Path(cask_path)
    with path.open("rb") as source:
        original = source.read()
        mode = stat.S_IMODE(os.fstat(source.fileno()).st_mode)
    lines = original.decode("utf-8").splitlines(keepends=True)
    fields = _parse_cask(lines)
    old_version = fields["version"][2]
    if tuple(map(int, version.split("."))) < tuple(map(int, old_version.split("."))):
        raise UpdateError(f"refusing version downgrade from {old_version} to {version}")
    if version == old_version and sha256 != fields["sha256"][2].lower():
        raise UpdateError(f"version {version} is immutable; its ZIP sha256 cannot change")
    for field, value in (("version", version), ("sha256", sha256), ("minimum_macos", macos_symbol)):
        if field in fields:
            index, (start, end), _ = fields[field]
            lines[index] = lines[index][:start] + value + lines[index][end:]
    if "minimum_macos" not in fields:
        app_index = fields["app"][0]
        app_line = lines[app_index]
        indent = re.match(r"[ \t]*", app_line).group()
        newline = "\r\n" if app_line.endswith("\r\n") else "\n"
        lines.insert(app_index, f"{indent}depends_on macos: :{macos_symbol}{newline}")
    elif fields["minimum_macos"][0] > fields["app"][0]:
        dependency = lines.pop(fields["minimum_macos"][0])
        lines.insert(fields["app"][0], dependency)
    updated = "".join(lines).encode("utf-8")
    if updated == original:
        return False
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(updated)
            destination.flush()
            os.fchmod(destination.fileno(), mode)
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cask_path", metavar="CASK_PATH")
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--minimum-macos", required=True)
    args = parser.parse_args(argv)
    try:
        changed = update_cask(
            args.cask_path,
            version=args.version,
            sha256=args.sha256,
            minimum_macos=args.minimum_macos,
        )
    except (UpdateError, OSError, UnicodeError) as error:
        parser.exit(1, f"error: {error}\n")
    print("Updated Stackboard cask" if changed else "Stackboard cask already matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
