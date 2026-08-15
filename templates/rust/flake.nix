{
  description = "CHANGEME — a Rust project";

  # The toolchain pin lives in rust-dev, not here. Do not add a
  # rust-toolchain.toml: the dev shell materializes the shared one at the
  # project root so rustup and Nix agree, and there is only ever one pin to
  # bump.
  inputs.rust-dev.url = "path:../../nix";

  outputs =
    { rust-dev, ... }:
    rust-dev.forEachSystem (
      lib:
      lib.mkRustProject {
        name = "CHANGEME";
        src = ./.;

        # Native dependencies go here, e.g.:
        # extra = [ lib.pkgs.cmake lib.pkgs.pkg-config ];
      }
    );
}
