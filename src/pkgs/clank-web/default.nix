# clank-web: the Clankstation service (design section 8). A Go binary with
# the Svelte web app (ui/) embedded.
{
  lib,
  buildGoModule,
  buildNpmPackage,
}:
let
  version = "0.1.0";

  ui = buildNpmPackage {
    pname = "clankstation-ui";
    inherit version;
    src = lib.fileset.toSource {
      root = ./ui;
      fileset = lib.fileset.unions [
        ./ui/package.json
        ./ui/package-lock.json
        ./ui/index.html
        ./ui/vite.config.js
        ./ui/src
      ];
    };
    # After changing package-lock.json:
    #   nix run nixpkgs/nixos-26.05#prefetch-npm-deps -- ui/package-lock.json
    npmDepsHash = "sha256-PgfwhXwhOoolgJad4E6DZhhq5wvwsO7H6t9uKrL7Dhk=";
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };
in
buildGoModule {
  pname = "clank-web";
  inherit version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (f: f.hasExt "go" || f.name == "go.mod") ./.;
  };
  # Standard library only, so no dependencies to vendor.
  vendorHash = null;
  env.CGO_ENABLED = 0;
  preBuild = ''
    mkdir -p ui
    cp -r ${ui} ui/dist
  '';

  passthru = { inherit ui; };

  meta = {
    description = "Clankstation web service and app";
    mainProgram = "clank-web";
  };
}
