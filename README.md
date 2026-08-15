# rust-dev

One deterministic Rust toolchain pin, shared by every Rust project in `~/dev/projects`.

## Why

The estate had four different ways of getting a Rust compiler — fenix, rust-overlay, plain `pkgs.rustc`, and a `chess-flake` bundle — with versions diverging between 1.95.0 and whatever `stable` resolved to that week. Copying a flake between projects copied the pin with it, so the copies drifted: `music/levine` carried litchee's channel, litchee's manifest hash, litchee's `cmake` dependency and litchee's `description`.

A template would not have fixed that, because a template copies the pin too. This is a library: consumers reference it, so bumping Rust here moves every project at once.

## Consuming it

A consumer flake is the whole integration:

```nix
{
  description = "my-crate — …";

  inputs.rust-dev.url = "path:../../nix";

  outputs =
    { rust-dev, ... }:
    rust-dev.forEachSystem (
      lib:
      lib.mkRustProject {
        name = "my-crate";
        src = ./.;
      }
    );
}
```

with `use flake` in `.envrc`. That yields `devShells.default`, `packages.default`, `checks.{build,clippy,fmt}` and `formatter`, on every supported system.

Do **not** add a `rust-toolchain.toml`. The dev shell materializes the canonical one at your project root as a symlink into the Nix store, so rustup and Nix read the same pin and there is only ever one file to bump. A real (non-symlink) `rust-toolchain.toml` is never overwritten, so a project that deliberately pins its own MSRV keeps it.

## Bumping Rust

Two lines, one commit, all consumers:

1. Change `channel` in `rust-toolchain.toml`.
2. Set `defaultSha256` in `flake.nix` to `lib.fakeSha256`, build once, paste the hash Nix prints.

The hash is of the channel manifest and is platform-independent, so one value covers every system. fenix turns it into a fixed-output derivation, which is what makes the pin real — `nix flake update` cannot move the compiler, and a wrong hash fails loudly:

```
error: hash mismatch in fixed-output derivation 'channel-rust-1.95.0.toml.drv':
  specified: sha256-AAAA…
     got:    sha256-gh/xTkxKHL4eiRXzWv8KP7vfjSk61Iq48x47BEDFgfk=
```

This is why the channel must be an exact version and never `stable`.

## Library API

`rust-dev.lib.${system}` exposes:

| Name | Purpose |
| --- | --- |
| `mkRustProject` | The one-call entry point above — shell, package, checks, formatter |
| `mkRustShell` | Dev shell only. `{ name, toolchain?, extra?, env?, hook?, materializeToolchain? }` |
| `mkRustPackage` | `buildRustPackage` on the pinned toolchain. Reads pname/version from `Cargo.toml` |
| `mkChecks` | `{ build, clippy, fmt }`, all on the pinned toolchain |
| `mkToolchain` | `{ file?, sha256? }` — override for projects pinning a different MSRV |
| `rustPlatformFor` | `makeRustPlatform` bound to a toolchain, if you need to build something custom |
| `toolchain`, `pkgs`, `cargoTools`, `lspTools`, `formatTools`, `cacheTools` | The pieces, for hand-rolled shells |

`rust-dev.forEachSystem` applies a function to the per-system lib and transposes the result into flake output shape, so consumers need no `flake-utils` input of their own.

### Native dependencies

Pass them as `extra`:

```nix
lib.mkRustProject {
  name = "litchee";
  src = ./.;
  extra = [ lib.pkgs.cmake lib.pkgs.pkg-config ];
}
```

### Workspaces

`mkRustPackage` reads `pname`/`version` from `Cargo.toml`. A virtual manifest has no `[package]`, so pass them explicitly:

```nix
lib.mkRustProject {
  name = "mtpkit";
  src = ./.;
  pname = "mtpkit-cli";
  version = "0.1.0";
  cargoBuildFlags = [ "-p" "mtpkit-cli" ];
}
```

Unrecognized arguments are forwarded to `buildRustPackage`.

### A different MSRV

```nix
lib.mkRustProject {
  name = "litchee";
  src = ./.;
  toolchain = lib.mkToolchain {
    file = ./rust-toolchain.toml; # this project's own, committed
    sha256 = "sha256-…";
  };
}
```

## What the shell provides

- **Toolchain** — rustc, cargo, clippy, rustfmt, rust-src and **rust-analyzer**, all from the same release. The analyzer is a toolchain component rather than a separate nixpkgs package, so it can never drift from the compiler.
- **LSPs** — `nixd`, `marksman`, `bash-language-server`, and `taplo` for TOML.
- **Cargo tools** — `cargo-nextest`, `cargo-audit`, `cargo-deny`, `cargo-outdated`, `cargo-edit`, `cargo-watch`.
- **Formatters/linters** — `taplo`, `nixfmt`, `shellcheck`.
- **Two caches** — `CARGO_HOME` pinned to the project root, so the registry is per-project and disposable; and `sccache` via `RUSTC_WRAPPER`, whose store is host-global. Because every consumer shares one toolchain pin, they also share compiled dependencies: the pin and the cache reinforce each other. `sccache --show-stats` for the hit rate.

## Supported systems

`aarch64-darwin`, `aarch64-linux`, `x86_64-linux`. `x86_64-darwin` is excluded — nixpkgs dropped it in 2026-07.

## Notes

`checks.clippy` reuses the package derivation and swaps its build phase, so dependencies come from the same vendored `Cargo.lock` rather than being re-resolved. `checks.build` runs the suite through nextest, which does **not** run doctests — add `cargo test --doc` to CI separately if you rely on them.
