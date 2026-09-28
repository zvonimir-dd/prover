{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # v0.23.1 and later vendor git dependencies with `cargo package --exclude-lockfile`, which the
    # pinned nightly's cargo does not know. Move this together with the fenix toolchain.
    crane.url = "github:ipetkov/crane/v0.23.0";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Solver releases, pinned by tag. Keep each tag and the matching `version` below in step.
    z3-src = {
      url = "github:Z3Prover/z3/z3-5.1.0";
      flake = false;
    };
    cvc5-src = {
      url = "github:cvc5/cvc5/cvc5-1.4.1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, fenix, z3-src, cvc5-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Switch to nightly toolchain
        craneLib = (crane.mkLib pkgs).overrideToolchain (_: fenix.packages.${system}.complete.toolchain);
        # nixpkgs' own recipes, built from the pinned sources. libz3 is linked into the prover, so
        # it must come from the same nixpkgs as the Rust build; the z3 and cvc5 executables are
        # put on the prover's PATH and raced against each other in `unify::smt`.
        # No Python bindings: the prover does not use them, and 5.x installs a versioned libz3
        # symlink into them that points back into the build tree, which nixpkgs' recipe rejects.
        z3 = (pkgs.z3.override { pythonBindings = false; }).overrideAttrs { version = "5.1.0"; src = z3-src; };
        cvc5 = pkgs.cvc5.overrideAttrs { version = "1.4.1"; src = cvc5-src; };
        packageDef = with pkgs; {
          src = craneLib.cleanCargoSource ./.;
          buildInputs = [ z3 cvc5 ];
          nativeBuildInputs = with pkgs; [ rustPlatform.bindgenHook makeWrapper ]
            ++ lib.optionals stdenv.hostPlatform.isDarwin [ libiconv ];
        };
        cargoArtifacts = craneLib.buildDepsOnly packageDef;
        qed-prover = craneLib.buildPackage (packageDef // {
          inherit cargoArtifacts;
          doNotLinkInheritedArtifacts = true;
          postInstall = with pkgs; "wrapProgram $out/bin/qed-prover --set PATH ${lib.makeBinPath [ cvc5 z3 ]}";
        });
      in {
        packages.default = qed-prover;

        devShells.default = pkgs.mkShell {
          inputsFrom = [ qed-prover ];
          packages = with pkgs; [ rust-analyzer julia-bin jless ] ++ lib.optionals stdenv.hostPlatform.isLinux [ perf ];
        };
      });

  nixConfig = {
    extra-substituters = [ "https://cosette.cachix.org" ];
    extra-trusted-public-keys = [ "cosette.cachix.org-1:d2Pfpw41eAAEZsDLXMnSMjjCpaemLAAxIrLCJaMIEWk=" ];
  };
}
