# Only used for development & CI
{
  inputs = {
    nixpkgs_unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs_25_11.url = "github:NixOS/nixpkgs/nixos-25.11";

    nix-darwin_unstable.url = "github:nix-darwin/nix-darwin";
    nix-darwin_25_11.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";

    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs_unstable";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs_unstable) lib;

      supportedSystems = [
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      releases = {
        "unstable" = {
          nixpkgs = inputs.nixpkgs_unstable;
          nix-darwin = inputs.nix-darwin_unstable;
        };
        "25.11" = {
          nixpkgs = inputs.nixpkgs_25_11;
          nix-darwin = inputs.nix-darwin_25_11;
        };
      };

      githubPlatforms = {
        "aarch64-darwin" = "macos-26";
        "x86_64-darwin" = "macos-26";
      };

      matrix =
        let
          names = {
            release = builtins.attrNames releases;
            test = builtins.attrNames (
              import ./tests.nix {
                self = null;
                pkgs = null;
                nix-darwin = null;
              }
            );
          };
        in
        lib.pipe names [
          lib.cartesianProduct
          (map (setup: {
            name = "${setup.test}-${setup.release}";
            value = setup;
          }))
          lib.listToAttrs
        ];

      forAllSystems =
        f: lib.genAttrs supportedSystems (system: f inputs.nixpkgs_unstable.legacyPackages.${system});

      # The module itself is Darwin-only, but formatting is platform
      # independent and CI's cheap matrix-generation runner is Linux. Exposing
      # the formatter on Linux too lets the format check run there instead of
      # burning a macOS runner, and lets Linux contributors run `nix fmt`.
      formatterSystems = supportedSystems ++ [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllFormatterSystems =
        f: lib.genAttrs formatterSystems (system: f inputs.nixpkgs_unstable.legacyPackages.${system});

      makeCi =
        { self, brew-src }:
        let
          assembleTest =
            {
              system,
              release,
              test,
            }:
            let
              inputs' = releases.${release};
              pkgs = inputs'.nixpkgs.legacyPackages.${system};
              tests = import ./tests.nix {
                inherit self pkgs;
                inherit (inputs') nix-darwin;
              };
            in
            tests.${test};

          ciTests = lib.genAttrs supportedSystems (
            system:
            lib.mapAttrs (
              name:
              { release, test }:
              assembleTest {
                inherit system release test;
              }
            ) matrix
          );
          ciScripts = lib.mapAttrs (
            system: tests: lib.mapAttrs (name: test: test.config.system.build.ci-script) tests
          ) ciTests;
        in
        {
          inherit ciTests;
          packages = forAllSystems (
            pkgs:
            pkgs.callPackages (self + "/pkgs") {
              inherit brew-src;
            }
          );
          # pkgs.nixfmt IS the RFC 166 formatter now; the old
          # `nixfmt-rfc-style` alias emits a deprecation warning on every eval.
          formatter = forAllFormatterSystems (pkgs: pkgs.nixfmt);

          devShell = forAllSystems (
            pkgs:
            pkgs.mkShell {
              # Same derivation `nix fmt` and CI use, so a commit formatted in
              # the dev shell is exactly what the format check expects.
              nativeBuildInputs = with pkgs; [
                nixfmt
              ];

              BREW_SRC = brew-src;

              # Opt the checkout into .githooks/, which carries the pre-commit
              # nixfmt check. .envrc runs `use_flake`, so for anyone using
              # direnv this happens just by entering the directory. Scoped with
              # --local so it only ever affects this clone.
              shellHook = ''
                if command -v git >/dev/null 2>&1 \
                  && git rev-parse --git-dir >/dev/null 2>&1 \
                  && [ -d .githooks ] \
                  && [ "$(git config --local --get core.hooksPath || true)" != ".githooks" ]; then
                  git config --local core.hooksPath .githooks
                  echo "nix-homebrew: enabled .githooks (pre-commit nixfmt check)"
                fi
              '';
            }
          );
          githubActions = inputs.nix-github-actions.lib.mkGithubMatrix {
            checks = ciScripts;
            platforms = githubPlatforms;
          };
        };
    in
    {
      inherit makeCi;
    };
}
