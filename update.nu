#!/usr/bin/env nix
#! nix shell --inputs-from . nixpkgs#nushell nixpkgs#oxfmt -c nu

# Update script for the codex package.
#
# Enumerates `rust-v*` releases of openai/codex, then builds one source file per
# version under `versions/` from the official `codex-package_SHA256SUMS` asset
# published with each release. Only 1.4 KB is downloaded per version — the
# release archives themselves are never fetched here.
#
# Modelled on:
# https://github.com/ryoppippi/nix-claude-code/blob/main/update.nu

const script_dir = (path self .)
const RELEASES_API = "https://api.github.com/repos/openai/codex/releases"
const DOWNLOAD_BASE = "https://github.com/openai/codex/releases/download"
const CHECKSUM_ASSET = "codex-package_SHA256SUMS"

# Releases are tagged `rust-v<semver>`; anything else (alphas, other components)
# is not a Codex CLI release we can package.
const TAG_PATTERN = '^rust-v\d+\.\d+\.\d+$'

# Platform mappings (Nix system -> Rust target triple)
const platforms = {
    "x86_64-linux": "x86_64-unknown-linux-musl"
    "aarch64-linux": "aarch64-unknown-linux-musl"
    "x86_64-darwin": "x86_64-apple-darwin"
    "aarch64-darwin": "aarch64-apple-darwin"
}

# Sort a list of version strings using semver ordering (ascending).
def semver-sort []: list<string> -> list<string> {
    $in | each { into semver } | sort | each { into string }
}

# Check whether version `a` is greater than or equal to version `b`.
# Semver values support sort but not comparison operators, so the check sorts
# the pair and tests whether `a` comes out on top.
def semver-gte [
    a: string # the version being tested
    b: string # the baseline it must reach
]: nothing -> bool {
    let last_sorted = (
        [$b $a]
        | each { into semver }
        | sort
        | last
        | into string
    )
    $last_sorted == ($a | into semver | into string)
}

# GitHub's unauthenticated rate limit is 60 requests/hour, which the release
# listing can exhaust on a busy repository. Use GITHUB_TOKEN when CI provides it.
def gh-get [url: string]: nothing -> any {
    let token = $env.GITHUB_TOKEN? | default ""
    match ($token | is-empty) {
        true => { http get $url }
        false => { http get --headers [Authorization $"Bearer ($token)"] $url }
    }
}

# List every published (non-draft, non-prerelease) Codex CLI version, ascending.
def fetch-released-versions []: nothing -> list<string> {
    mut page = 1
    mut tags = []

    loop {
        let batch = (gh-get $"($RELEASES_API)?per_page=100&page=($page)")
        match ($batch | is-empty) {
            true => { break }
            false => { }
        }

        $tags = (
            $tags
            | append (
                $batch
                | where {|r| (not $r.draft) and (not $r.prerelease) }
                | get tag_name
            )
        )

        # A short page is the last page. Cap the walk regardless: the backfill
        # range only ever reaches back to the earliest version already tracked.
        match ((($batch | length) < 100) or ($page >= 5)) {
            true => { break }
            false => { $page = $page + 1 }
        }
    }

    $tags
    | where {|t| $t =~ $TAG_PATTERN }
    | each {|t| $t | str replace "rust-v" "" }
    | uniq
    | semver-sort
}

# Get all existing versions from the versions directory, ascending.
# `latest` is null when no version file is tracked yet.
def get-existing-versions []: nothing -> record<versions: list<string>, latest: any> {
    let names = (
        glob ($script_dir | path join "versions" "*.json")
        | each { path parse | get stem }
    )
    match ($names | is-empty) {
        true => {
            versions: []
            latest: null
        }
        false => {
            let sorted = $names | semver-sort
            {
                versions: $sorted
                latest: ($sorted | last)
            }
        }
    }
}

# Write version sources to the versions directory.
def write-version-sources [
    version: string
    hashes: record # SRI hash per Nix system, keyed as in `$platforms`
]: nothing -> nothing {
    let versioned_path = $script_dir | path join "versions" $"($version).json"

    let platforms_data = (
        $platforms
        | items {|nix_system, target|
            {$nix_system: {
                url: $"($DOWNLOAD_BASE)/rust-v($version)/codex-package-($target).tar.gz"
                hash: ($hashes | get $nix_system)
            }}
        }
        | reduce -f {} {|it, acc| $acc | merge $it}
    )

    let sources_data = {version: $version, platforms: $platforms_data}
    (($sources_data | to json --indent 2) + "\n") | save -f $versioned_path
}

# GitHub serves release assets without a charset, so nushell hands the body back
# as binary rather than a string. Normalise it before parsing.
def as-text []: any -> string {
    let value = $in
    match ($value | describe) {
        "binary" => {
            $value | decode utf-8
        }
        _ => { $value }
    }
}

# Parse a `sha256sum`-style listing into a `name -> hex digest` table.
def parse-checksums [text: string]: nothing -> table<name: string, hex: string> {
    $text
    | lines
    | where {|line| ($line | str trim) != "" }
    | each {|line|
        let parts = $line | str trim | split row -r '\s+'
        {name: ($parts | get 1), hex: ($parts | get 0)}
    }
}

# Fetch the release checksums, convert them to SRI, and write the version file.
# Returns true if the version was written, false if it could not be packaged.
def process-version [version: string]: nothing -> bool {
    let checksum_url = $"($DOWNLOAD_BASE)/rust-v($version)/($CHECKSUM_ASSET)"

    let checksums = (try { http get $checksum_url } catch {|err|
        print -e $"  Skipping ($version): ($err.msg)"
        null
    })

    match $checksums {
        null => false
        _ => {
            let digests = parse-checksums ($checksums | as-text)

            let results = (
                $platforms
                | items {|nix_system, target|
                    let asset = $"codex-package-($target).tar.gz"
                    let row = $digests | where name == $asset | get -o 0
                    match $row {
                        null => {
                            print -e $"  Skipping ($version): no digest for ($asset)"
                            null
                        }
                        _ => {$nix_system: (
                            nix hash convert --hash-algo sha256 --to sri --from base16 $row.hex
                            | str trim
                        )}
                    }
                }
            )

            match ($results | any {|r| $r == null}) {
                true => false
                false => {
                    let hashes = $results | reduce -f {} {|it, acc| $acc | merge $it}
                    write-version-sources $version $hashes
                    true
                }
            }
        }
    }
}

# Backfill every version file missing from the tracked range and print the newest
# known version as the final line for CI consumption.
def main []: nothing -> nothing {
    let existing = (get-existing-versions)
    let existing_versions = $existing.versions
    let current_version = $existing.latest

    let released_versions = (fetch-released-versions)
    let latest_version = $released_versions | last

    print $"Current version: ($current_version)"
    print $"Latest release:  ($latest_version)"

    # Only backfill versions >= the earliest version we already track, so the
    # repository never tries to package releases predating the package layout.
    let earliest = $existing_versions | get -o 0

    let missing_versions = (
        $released_versions
        | where {|v| $v not-in $existing_versions and ($earliest == null or (semver-gte $v $earliest))}
    )

    match ($missing_versions | is-empty) {
        true => { print "All versions are up to date!" }
        false => {
            print $"Found ($missing_versions | length) missing version\(s\): ($missing_versions | str join ', ')"

            $missing_versions | each {|version|
                print $"Processing ($version)..."
                match (process-version $version) {
                    true => { print $"  Added ($version)" }
                    false => {}
                }
            } | ignore
        }
    }

    # Format with oxfmt
    print "Formatting with oxfmt..."
    cd $script_dir
    oxfmt --config ($script_dir | path join ".oxfmtrc.jsonc") versions/*.json | ignore
    print "Done!"

    # Print the latest version as the final line for CI consumption
    print $latest_version
}
