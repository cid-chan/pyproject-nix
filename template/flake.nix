{
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.pyproject-nix.url = "github:cid-chan/pyproject-nix";
  inputs.pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { pyproject-nix, ... }@inputs:
    # This project is managed via pyproject.toml
    pyproject-nix.lib.makeFlake {
      inherit inputs;
      toml = ./pyproject.toml;
    };
}
