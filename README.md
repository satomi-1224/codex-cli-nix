# codex-cli-nix

A Nix flake that provides pre-built [OpenAI Codex CLI](https://github.com/openai/codex) binaries from official OpenAI releases.

This flake downloads the official `codex-package-*` release archives from GitHub and installs them as-is, so `codex` behaves exactly as it does with upstream's own installer.

## Getting Started

```bash
# Run the latest version
nix run github:satomi-1224/codex-cli-nix

# Run a specific version
nix run 'github:satomi-1224/codex-cli-nix#"0.147.0"'
```

## Features

- ✅ Automatic updates via GitHub Actions (hourly checks)
- ✅ Multi-platform support: Linux (x86_64, aarch64) and macOS (x86_64, aarch64)
- ✅ Direct downloads from official OpenAI release assets
- ✅ SHA-256 verification against upstream's published `codex-package_SHA256SUMS`
- ✅ Every tracked version stays installable, so you can pin or roll back
- ✅ Flake and non-flake support

## Why Use This Flake?

[nixpkgs already packages `codex`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/co/codex/package.nix), but it builds the Rust workspace from source. That requires a fresh `cargoHash` and a matching prebuilt `librusty_v8` pair for every release, and a `cargoHash` cannot be determined without first running a build that fails — so the update cannot be fully automated. Codex ships a release roughly every day or two, and nixpkgs consistently trails it by several versions.

This flake takes the official release binaries instead:

- **Always current**: the updater only needs a 1.4 KB checksum file per release, so a new version can land within the hour
- **Identical to upstream**: the same signed executables that `install.sh` would place in `~/.codex`, including the bundled `rg`, the Linux `bwrap` helper and the patched zsh fork that backs `shell_zsh_fork`
- **No compilation**: installing is a download and a copy, not a 20-minute Rust build

The trade-off is that these are prebuilt binaries (`sourceProvenance = binaryNativeCode`) rather than a from-source build. If you need a source build, use nixpkgs' `codex`.

## Usage

### Quick Start

```bash
# Run Codex directly
nix run github:satomi-1224/codex-cli-nix

# Or enter a shell with codex available
nix shell github:satomi-1224/codex-cli-nix
codex --version
```

### With Flakes

#### Add to NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    codex-cli-nix.url = "github:satomi-1224/codex-cli-nix";
  };

  outputs = { nixpkgs, codex-cli-nix, ... }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ codex-cli-nix.overlays.default ];
          environment.systemPackages = [ pkgs.codex ];
        })
      ];
    };
  };
}
```

#### Add to nix-darwin

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    codex-cli-nix.url = "github:satomi-1224/codex-cli-nix";
  };

  outputs = { nix-darwin, codex-cli-nix, ... }: {
    darwinConfigurations.yourhostname = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ codex-cli-nix.overlays.default ];
          environment.systemPackages = [ pkgs.codex ];
        })
      ];
    };
  };
}
```

#### Add to devShell

**Method 1: Direct package reference (recommended)**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    codex-cli-nix.url = "github:satomi-1224/codex-cli-nix";
  };

  outputs = { nixpkgs, codex-cli-nix, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              codex-cli-nix.packages.${system}.default
            ];
          };
        }
      );
    };
}
```

**Method 2: Using the overlay**

```nix
{
  outputs = { nixpkgs, codex-cli-nix, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [ codex-cli-nix.overlays.default ];
      };
    in
    {
      devShells.aarch64-darwin.default = pkgs.mkShell {
        packages = [ pkgs.codex ];
      };
    };
}
```

The overlay is evaluated against _your_ nixpkgs, so adding it does not pull a second nixpkgs into your closure.

### Without Flakes

```nix
let
  codex-cli-nix = builtins.fetchTarball {
    url = "https://github.com/satomi-1224/codex-cli-nix/archive/main.tar.gz";
  };
  pkgs = import <nixpkgs> { };
in
import codex-cli-nix { inherit pkgs; }
```

## Available Packages

| Attribute                        | Description                              |
| -------------------------------- | ---------------------------------------- |
| `packages.${system}.default`     | Latest tracked release (same as `codex`) |
| `packages.${system}.codex`       | Latest tracked release                   |
| `packages.${system}.latest`      | Latest tracked release                   |
| `packages.${system}."<version>"` | A specific version, e.g. `"0.147.0"`     |
| `pkgs.codex` (overlay)           | Latest tracked release                   |

### Version Pinning

```nix
# Pin a specific version
codex-cli-nix.packages.${system}."0.147.0"

# Always follow the newest tracked release
codex-cli-nix.packages.${system}.default
```

```bash
nix run 'github:satomi-1224/codex-cli-nix#"0.147.0"'
```

Every version this repository has tracked stays available. See [`versions/`](./versions) for the full list. Tracking starts at `0.133.0`, the oldest release that ships the `codex-package-*` archive layout.

### Adding tools to Codex's PATH

Codex bundles its own `rg`, so nothing extra is required out of the box. If you want more tools visible to Codex's shell — `git`, for example — use `additionalPaths`, which wraps the entrypoint with a PATH prefix:

```nix
pkgs.codex.override {
  additionalPaths = [ "${pkgs.git}/bin" "${pkgs.gh}/bin" ];
}
```

## How It Works

1. `update.nu` lists every `rust-v<semver>` release of `openai/codex`, skipping drafts and prereleases
2. For each version not yet tracked, it downloads that release's `codex-package_SHA256SUMS` (1.4 KB) and converts the published hex digests to SRI, writing one source file per version under `versions/`
3. GitHub Actions runs the updater hourly and commits any new version files
4. `package.nix` fetches the `codex-package-<target>.tar.gz` for the host system and installs the archive verbatim

### Package layout

Codex locates its bundled helpers relative to the package root it derives from `current_exe`, so the upstream layout is preserved under `libexec` and `bin/codex` is a symlink into it (`current_exe` is canonicalised before that lookup, so the symlink resolves correctly):

```text
$out
├── bin/codex -> ../libexec/codex/bin/codex
└── libexec/codex
    ├── codex-package.json
    ├── bin/{codex,codex-code-mode-host}
    ├── codex-path/rg
    └── codex-resources
        ├── bwrap          # Linux only
        └── zsh/bin/zsh
```

Nothing shipped in the archive is stripped or rewritten: the Linux binaries are static-pie and the macOS binaries carry OpenAI's Developer ID signature, which any modification would invalidate. The single exception is `codex-resources/zsh/bin/zsh` on Linux, which is dynamically linked and gets its interpreter and rpath patched so it can run on NixOS.

## Supported Platforms

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin` (macOS Intel)
- `aarch64-darwin` (macOS Apple Silicon)

## Notes

- A single version occupies roughly 270 MB in the Nix store. With hourly updates it is worth having `nix.gc` configured, or running `nix store gc` occasionally.
- `codex update` is not the way to upgrade here: the Nix store is read-only. Update the flake input instead.

## Development

Development tooling (formatters, linters, git hooks) lives in `dev/flake.nix` so the consumer-facing `flake.lock` only pins `nixpkgs`.

```bash
# Enter the dev shell (installs pre-commit hooks)
nix develop ./dev

# Or, with direnv
direnv allow

# Update version sources manually
./update.nu

# Build and smoke-test
nix build
./result/bin/codex --version

# Run all checks (formatting, linting, secret scanning, renovate config)
nix flake check ./dev
```

## Credits

- Codex CLI by [OpenAI](https://openai.com)
- Repository layout and update-script approach adapted from [ryoppippi/nix-claude-code](https://github.com/ryoppippi/nix-claude-code)

## Licence

MIT
