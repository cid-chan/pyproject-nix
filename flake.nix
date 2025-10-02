{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs =
    { self, nixpkgs, ... }:
    {
      lib = {
        makeFlake = import ./lib/make-flake.nix nixpkgs;
      };
      templates = {
        default = self.templates.pyproject-nix;
        pyproject-nix = {
          path = ./template;
          description = "Just a simple template for a pyproject.nix";
        };
      };
    };
}

