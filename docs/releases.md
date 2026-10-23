# Maintainer release guide

[Back to Stackboard](../README.md) · [Development guide](development.md)

This guide documents the existing release process for maintainers. Commands are instructions and examples, not a record of publication actions performed. For a local build that does not publish anything, see [Build from source](development.md#build-from-source).

## Publication workflows

- [`ci.yml`](../.github/workflows/ci.yml) runs on pushes to `main`, pull requests, and manual dispatch. It checks workflow definitions, shell syntax, and release-tool behavior, builds a Universal package, and verifies the finished ZIP again.
- [`release.yml`](../.github/workflows/release.yml) runs for a stable `vX.Y.Z` tag, or can be dispatched manually with an existing stable tag. It publishes a GitHub Release and updates [`0x0FACED/homebrew-stackboard`](https://github.com/0x0FACED/homebrew-stackboard). Prerelease tags are not accepted.

Jobs run only in **public repositories** on standard GitHub-hosted runners. They do not use paid larger runners, Actions artifacts, or Actions cache. They also do not use paid signing or notarization: the app is **ad-hoc signed and not notarized**, so macOS may require explicit approval to open it. Making the repository private disables the jobs rather than switching to paid builds. See the [README](../README.md) for installation and permission guidance.

macOS jobs use **`macos-26`** with **Xcode 26.4.1**, selected explicitly by:

```text
DEVELOPER_DIR=/Applications/Xcode_26.4.1.app/Contents/Developer
```

If that Xcode version disappears from the GitHub runner image, update `DEVELOPER_DIR` in **both** workflows and verify a new build. There is no automatic fallback to another compiler. Local development requirements and package verification are documented in the [development guide](development.md).

## One-time token setup

In the GitHub account settings, open **Settings → Developer settings → Personal access tokens → Fine-grained tokens** and create a token with:

- **Resource owner:** `0x0FACED`.
- **Repository access:** only `homebrew-stackboard`.
- **Repository permissions:** `Contents — Read and write`.
- An expiration date; replace the token before it expires.

In the `0x0FACED/stackboard` repository, save the token as **`HOMEBREW_TAP_TOKEN`** under **Settings → Secrets and variables → Actions → New repository secret**. Never put it in source files, logs, or messages.

The built-in `GITHUB_TOKEN` publishes the Release in the main repository. The separate token is needed for the Homebrew tap. The workflow pushes directly to the tap's `main` branch, so branch protection must allow the selected account to write. Administrator permissions and access to every repository are not required.

## Publish a new version

Commit the intended changes first. The tag must point to the commit containing the desired source code and release tools; uncommitted files are not included in the release.

For example, to publish a new, unused version `1.0.2`, a maintainer would run the following from the repository root. These commands push changes and trigger publication; they are not local build commands.

```sh
git push origin main
git tag v1.0.2
git push origin v1.0.2
```

The release workflow then:

1. Validates the tag and tap secret, checks out the tagged source, and builds a verified ZIP. The app version comes from the tag, and the build number comes from the Actions run number.
2. Validates the proposed `Casks/stackboard.rb` update, creates or updates a draft Release, uploads the archive and checksum, and publishes the Release.
3. Updates the tap's `version`, `sha256`, and major-version macOS dependency using the packaged app's actual `Info.plist` metadata.

A GitHub Release contains **`Stackboard.zip`** and **`SHA256SUMS`**. `release.json` is an internal automation file, not a published release asset. See [local package output and verification](development.md#build-from-source) for its contents and the checks applied to the archive.

## Homebrew publication rules

The tap's cask is `Casks/stackboard.rb`. The workflow validates its update before publishing new release assets, then commits and pushes the cask update to the tap's `main` branch. If the cask already matches the release, no update commit is needed.

Homebrew represents the minimum macOS requirement at major-version precision: for example, `13.5` maps to `:ventura`. The exact minimum, currently **macOS 13.5**, remains in `Info.plist` and is enforced by macOS when the app starts.

The publication process refuses to downgrade the tap's version or change the SHA-256 of a version already known to the tap. A changed application requires a **new version**, not moving an old tag.

All release runs are serialized across versions. Do not edit the tap manually while publication is running. A failed tap push does not modify the published ZIP.

## Reruns and failures

- **Unpublished draft:** a rerun may rebuild it and replace its assets before publication.
- **Published Release:** it is not rebuilt or re-signed. The workflow downloads and verifies the existing `Stackboard.zip` and `SHA256SUMS` without changing them.
- **Release published, tap push failed:** fix the token or conflicting tap change, then use **Actions → Release → Re-run failed jobs**, or **Run workflow** with the same tag. The existing published package is reused and verified.
- **Old manual release:** `v1.0.0` lacks the required `SHA256SUMS` and the new release infrastructure in its tagged source. It cannot be republished through this process.

For shell syntax, release-tool tests, workflow linting, and macOS package verification commands, see [Development checks](development.md#development-checks).
