{
  description = "zigga development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      zig = zig-overlay.packages.${system}."0.16.0";
    in {
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.git
          pkgs.gh
          pkgs.jq
          pkgs.python3
          zig
          pkgs.zls
          pkgs.just
        ];
      };
    });
}
