{
  description = "OpenAI Codex CLI binaries.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      systems = import ./systems.nix;
      forAllSystems = nixpkgs.lib.genAttrs systems;

      versionFiles = builtins.readDir ./versions;
      versionNames = builtins.map (f: nixpkgs.lib.removeSuffix ".json" f) (
        builtins.filter (f: nixpkgs.lib.hasSuffix ".json" f) (builtins.attrNames versionFiles)
      );

      latestVersion = builtins.head (builtins.sort (a: b: builtins.compareVersions a b > 0) versionNames);
      latestSourcesFile = ./versions/${latestVersion + ".json"};

      mkCodex =
        pkgs: sourcesFile:
        pkgs.callPackage ./package.nix {
          inherit sourcesFile;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          versionedPackages = builtins.listToAttrs (
            builtins.map (version: {
              name = version;
              value = mkCodex pkgs ./versions/${version + ".json"};
            }) versionNames
          );
        in
        {
          codex = mkCodex pkgs latestSourcesFile;
          latest = mkCodex pkgs latestSourcesFile;
          default = self.packages.${system}.codex;
        }
        // versionedPackages
      );

      # Evaluated against the consumer's nixpkgs rather than this flake's, so
      # adding the overlay does not pull a second nixpkgs into their closure.
      overlays.default = _final: prev: {
        codex = mkCodex prev latestSourcesFile;
      };
    };
}
