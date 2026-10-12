{
  pkgs,
  lib,
  npmExtensions,
}:
# Launcher for the `bili` CLI shipped by the `billion-context` npm extension.
#
# `billion-context` is already built by `pkgs.importNpmLock.buildNodeModules`
# (see nix/default.nix) and its tarball ships a prebuilt `dist/`. Its
# package.json declares:
#   "bin":     { "bili": "./dist/index.js", "bili-proxy": "./dist/index.js" }
#   "engines": { "node": ">=20" }
# so no build step is needed here — we only need to expose that entry point on
# PATH. `runtimeInputs` puts nodejs on PATH and the entry point's own imports
# (e.g. zod) resolve from its sibling node_modules in the store.
let
  billionContext = "${npmExtensions}/node_modules/billion-context";
  entryPoint = "${billionContext}/dist/index.js";

  # writeShellApplication only emits the single name it is given, so this is
  # wrapped in a symlinkJoin to also expose upstream's `bili-proxy` alias
  # (both names point at the same entry point).
  biliBin = pkgs.writeShellApplication {
    name = "bili";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec node "${entryPoint}" "$@"
    '';
  };
in
pkgs.symlinkJoin {
  name = "bili";
  paths = [ biliBin ];
  postBuild = ''
    ln -s bili "$out/bin/bili-proxy"
  '';
  meta = {
    description = "Billion-context (bili) — shared long-term memory / context proxy for coding agents.";
    homepage = "https://github.com/ranxianglei/billion-context";
    license = lib.licenses.mit;
    mainProgram = "bili";
    platforms = lib.platforms.unix;
  };
}
