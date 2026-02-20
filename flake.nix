{
  description = "kelgroups — KEL-based group management library";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url =
      "github:hamishmack/flake-utils/hkm/nested-hydraJobs";
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    keri-hs = {
      url = "github:paolino/keri-hs";
      flake = false;
    };
  };
  outputs =
    { self, nixpkgs, flake-utils, haskellNix, purescript-overlay
    , keri-hs, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          overlays = [
            haskellNix.overlay
            purescript-overlay.overlays.default
          ];
          inherit system;
        };
        project =
          import ./nix/project.nix { inherit pkgs keri-hs; };
      in {
        packages = project.packages;
        devShells = project.devShells;
      });
}
