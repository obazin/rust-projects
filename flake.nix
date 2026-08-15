{
  description = "Shared Rust dev environment — one deterministic toolchain pin for every Rust project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      flake-utils,
    }:
    let
      # ── The canonical pin ────────────────────────────────────────────────
      # `sha256` is the hash of the 1.95.0 channel manifest. It is
      # platform-independent, so one value covers every system. Because fenix
      # turns it into a fixed-output derivation, bumping `fenix` or `nixpkgs`
      # cannot move the compiler — only editing these two values can.
      #
      # To bump Rust: change `channel` in rust-toolchain.toml, set
      # defaultSha256 to lib.fakeSha256, build once, and paste the hash Nix
      # prints. Both edits land in one reviewable commit.
      defaultToolchainFile = ./rust-toolchain.toml;
      defaultSha256 = "sha256-gh/xTkxKHL4eiRXzWv8KP7vfjSk61Iq48x47BEDFgfk=";

      # x86_64-darwin is excluded: nixpkgs dropped it in 2026-07.
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    let
      perSystem = flake-utils.lib.eachSystem supportedSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          # ── Toolchain ────────────────────────────────────────────────────
          # Consumers that must pin a different version (an MSRV that differs
          # from the canonical pin, say) call this with their own file+hash.
          # Everyone else gets `toolchain` below.
          mkToolchain =
            {
              file ? defaultToolchainFile,
              sha256 ? defaultSha256,
            }:
            fenix.packages.${system}.fromToolchainFile { inherit file sha256; };

          toolchain = mkToolchain { };

          # Builds packages with the *pinned* compiler. Without this,
          # pkgs.rustPlatform silently uses the nixpkgs rustc and the pin only
          # applies to the dev shell — the exact trap this lib exists to close.
          rustPlatformFor =
            tc:
            pkgs.makeRustPlatform {
              cargo = tc;
              rustc = tc;
            };

          # ── Tool sets ────────────────────────────────────────────────────
          cargoTools = with pkgs; [
            cargo-nextest # test runner
            cargo-audit # RUSTSEC advisories
            cargo-deny # licence / ban / advisory policy
            cargo-outdated
            cargo-edit # cargo add/rm/upgrade
            cargo-watch
          ];

          # rust-analyzer is NOT listed here: it ships as a toolchain component,
          # so the analyzer and rustc always come from the same release.
          lspTools = with pkgs; [
            nixd # Nix
            marksman # Markdown
            bash-language-server # sh
            # taplo is both the TOML LSP and the TOML formatter (see formatTools)
          ];

          formatTools = with pkgs; [
            taplo # TOML
            nixfmt # Nix
            shellcheck # sh; also bash-language-server's linter backend
          ];

          # sccache caches compiled rustc outputs by content hash, keyed on the
          # crate source and flags. The store is host-global, so every project
          # sharing this toolchain pin also shares its compiled dependencies —
          # the pin and the cache reinforce each other.
          cacheTools = [ pkgs.sccache ];

          # ── Dev shell ────────────────────────────────────────────────────
          mkRustShell =
            {
              name,
              toolchain ? mkToolchain { },
              # Native deps and per-project extras (cmake, pkg-config, systemd…)
              extra ? [ ],
              env ? { },
              hook ? "",
              # Materialize the canonical rust-toolchain.toml at the project
              # root so rustup sees the same pin as Nix. Never clobbers a real
              # file — see the guard in the hook.
              materializeToolchain ? true,
            }:
            pkgs.mkShell (
              {
                inherit name;
                packages = [ toolchain ] ++ cargoTools ++ lspTools ++ formatTools ++ cacheTools ++ extra;

                # rust-analyzer resolves std sources through this path.
                RUST_SRC_PATH = "${toolchain}/lib/rustlib/src/rust/library";
                RUST_BACKTRACE = "1";
                RUSTC_WRAPPER = "sccache";

                shellHook = ''
                  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

                  # Registry, git checkouts and installed binaries live in the
                  # project root rather than ~/.cargo, so the cache is
                  # per-project and disposable.
                  export CARGO_HOME="''${CARGO_HOME:-$root/.cargo}"
                  export PATH="$CARGO_HOME/bin:$PATH"

                  ${pkgs.lib.optionalString materializeToolchain ''
                    # Only link when there is nothing there, or when what is
                    # there is already our symlink. A project that deliberately
                    # committed its own rust-toolchain.toml is left untouched.
                    if [ ! -e "$root/rust-toolchain.toml" ] || [ -L "$root/rust-toolchain.toml" ]; then
                      ln -sfn ${defaultToolchainFile} "$root/rust-toolchain.toml"
                    fi
                  ''}

                  echo "${name} · $(rustc --version)"
                  ${hook}
                '';
              }
              // env
            );

          # ── Package ──────────────────────────────────────────────────────
          mkRustPackage =
            {
              src,
              toolchain ? mkToolchain { },
              pname ? null,
              version ? null,
              nativeBuildInputs ? [ ],
              buildInputs ? [ ],
              # nextest does not run doctests; `cargo test --doc` is separate.
              useNextest ? true,
              meta ? { },
              ...
            }@args:
            let
              cargoToml = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
              pkgAttrs = cargoToml.package or { };
              resolvedPname =
                if pname != null then
                  pname
                else
                  pkgAttrs.name or (throw "mkRustPackage: virtual manifest (workspace) — pass `pname` explicitly");
              resolvedVersion =
                if version != null then
                  version
                else
                  pkgAttrs.version
                    or (throw "mkRustPackage: virtual manifest (workspace) — pass `version` explicitly");
              passthru = builtins.removeAttrs args [
                "src"
                "toolchain"
                "pname"
                "version"
                "nativeBuildInputs"
                "buildInputs"
                "useNextest"
                "meta"
              ];
            in
            (rustPlatformFor toolchain).buildRustPackage (
              {
                pname = resolvedPname;
                version = resolvedVersion;

                src = pkgs.lib.cleanSource src;
                cargoLock.lockFile = src + "/Cargo.lock";

                inherit useNextest nativeBuildInputs buildInputs;

                meta = {
                  mainProgram = resolvedPname;
                }
                // meta;
              }
              // passthru
            );

          # ── Checks ───────────────────────────────────────────────────────
          # `build` compiles and runs the suite; `fmt` and `clippy` gate style
          # and lints. All three use the pinned toolchain.
          mkChecks =
            {
              src,
              toolchain ? mkToolchain { },
              package ? null,
              clippyFlags ? "--all-targets -- -D warnings",
              ...
            }@args:
            let
              pkg = if package != null then package else mkRustPackage args;
            in
            {
              build = pkg;

              fmt = pkgs.runCommand "${pkg.pname}-fmt-check" { nativeBuildInputs = [ toolchain ]; } ''
                cd ${pkgs.lib.cleanSource src}
                cargo fmt --all --check
                touch $out
              '';

              # Reuses the package derivation so dependencies are vendored from
              # Cargo.lock; only the build and install phases are swapped out.
              clippy = pkg.overrideAttrs (old: {
                pname = "${pkg.pname}-clippy";
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ toolchain ];
                buildPhase = ''
                  runHook preBuild
                  cargo clippy --offline ${clippyFlags}
                  runHook postBuild
                '';
                doCheck = false;
                installPhase = ''
                  runHook preInstall
                  touch $out
                  runHook postInstall
                '';
              });
            };

          # ── One-call project ─────────────────────────────────────────────
          # The whole point: a consumer flake is this call plus its inputs.
          mkRustProject =
            {
              name,
              src,
              toolchain ? mkToolchain { },
              extra ? [ ],
              env ? { },
              hook ? "",
              materializeToolchain ? true,
              nativeBuildInputs ? [ ],
              buildInputs ? [ ],
              ...
            }@args:
            let
              pkgArgs = builtins.removeAttrs args [
                "name"
                "extra"
                "env"
                "hook"
                "materializeToolchain"
              ];
              package = mkRustPackage pkgArgs;
            in
            {
              devShells.default = mkRustShell {
                inherit
                  name
                  toolchain
                  extra
                  env
                  hook
                  materializeToolchain
                  ;
              };
              packages.default = package;
              checks = mkChecks (pkgArgs // { inherit package; });
              formatter = pkgs.nixfmt;
            };
        in
        {
          # ── Public library ───────────────────────────────────────────────
          # Stable API surface; treat renames here as breaking for consumers.
          lib = {
            inherit
              pkgs
              toolchain
              mkToolchain
              rustPlatformFor
              cargoTools
              lspTools
              formatTools
              cacheTools
              mkRustShell
              mkRustPackage
              mkChecks
              mkRustProject
              ;
            toolchainFile = defaultToolchainFile;
            toolchainSha256 = defaultSha256;
          };

          # Shell for hacking on this flake itself.
          devShells.default = pkgs.mkShell {
            name = "rust-dev-flake";
            packages = formatTools ++ lspTools;
            shellHook = ''
              echo "rust-dev-flake · lib API: mkRustProject · mkRustShell · mkRustPackage · mkChecks · mkToolchain"
            '';
          };

          formatter = pkgs.nixfmt;
        }
      );
    in
    perSystem
    // {
      # ── Consumer entry point ─────────────────────────────────────────────
      # Applies `f` to this flake's per-system lib and transposes the result
      # into flake output shape, so a consumer needs exactly one input:
      #
      #   outputs = { rust-dev, ... }:
      #     rust-dev.forEachSystem (lib: lib.mkRustProject { ... });
      #
      # turns {system → {devShells, packages, …}} into {devShells.<system>, …}
      forEachSystem =
        f:
        let
          results = builtins.mapAttrs (_system: l: f l) perSystem.lib;
          classes = nixpkgs.lib.unique (builtins.concatMap builtins.attrNames (builtins.attrValues results));
        in
        builtins.listToAttrs (
          map (class: {
            name = class;
            value = builtins.mapAttrs (_system: r: r.${class}) (
              nixpkgs.lib.filterAttrs (_system: r: r ? ${class}) results
            );
          }) classes
        );

      # ── Templates ────────────────────────────────────────────────────────
      # Bootstrapping only. The template deliberately ships no
      # rust-toolchain.toml: the pin belongs to this flake, and the dev shell
      # materializes it. Copying the pin is what lets projects drift.
      templates.rust = {
        path = ./templates/rust;
        description = "Rust project consuming the shared deterministic toolchain";
      };
      templates.default = self.templates.rust;
    };
}
