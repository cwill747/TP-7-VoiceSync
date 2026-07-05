{
  description = "TP-7 VoiceSync — dev shell & native lib build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go_1_25
            pkg-config
            libusb1
          ];

          shellHook = ''
            export CGO_ENABLED=1
            export GOROOT="${pkgs.go_1_25}/share/go"
          '';
        };

        # Build with: nix develop --command ./scripts/build-tp7mtp.sh
      });
}
