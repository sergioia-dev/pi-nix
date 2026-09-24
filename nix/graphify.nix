{
  pkgs,
  lib,
}:
# Self-owned build of Graphify.
#
# Historically the flake pulled in nixpkgs' `pkgs.graphify` and patched its
# `optional-dependencies` on with `overridePythonAttrs`. That tied us to
# nixpkgs' release cadence (nixpkgs was several releases behind upstream) and
# to the exact extra names nixpkgs happened to define. This derivation builds
# Graphify straight from the upstream repo at a tag *we* pin, with the extras
# the Pi skill documents already folded in.
let
  version = "0.9.67";

  # Per-language tree-sitter bindings live under `tree-sitter-grammars`.
  tsg = pkgs.python3Packages.tree-sitter-grammars;

  # Core runtime dependencies, mirroring upstream's `dependencies` table.
  core = with pkgs.python3Packages; [
    networkx
    numpy
    rapidfuzz
    tree-sitter
  ] ++ (with tsg; [
    tree-sitter-bash
    tree-sitter-c
    tree-sitter-c-sharp
    tree-sitter-cpp
    tree-sitter-elixir
    tree-sitter-fortran
    tree-sitter-go
    tree-sitter-groovy
    tree-sitter-java
    tree-sitter-javascript
    tree-sitter-json
    tree-sitter-julia
    tree-sitter-kotlin
    tree-sitter-lua
    tree-sitter-objc
    tree-sitter-php
    tree-sitter-powershell
    tree-sitter-python
    tree-sitter-ruby
    tree-sitter-rust
    tree-sitter-scala
    tree-sitter-swift
    tree-sitter-typescript
    tree-sitter-verilog
    tree-sitter-zig
  ]);

  # Optional feature groups Graphify imports lazily. Upstream ships these as
  # PEP 621 extras, but a plain `buildPythonPackage` installs none of them, so
  # the commands the skill documents die with "No module named ...". Folding
  # them into `dependencies` puts them on Graphify's own sys.path.
  #
  # Unavailable in nixpkgs, therefore deliberately omitted (Graphify guards
  # every one of these with try/except, so the features degrade gracefully):
  #   falkordb  -> falkordb
  #   dm        -> tree-sitter-dm
  #   vbnet     -> tree-sitter-vb-dotnet
  #   r/erlang  -> tree-sitter-language-pack
  extras = with pkgs.python3Packages; [
    # LLM backends: openai/gemini/kimi/ollama/deepseek share the openai SDK.
    openai
    tiktoken
    anthropic
    boto3 # bedrock
    # MCP server: `graphify --mcp` (stdio, plus HTTP via uvicorn/starlette).
    mcp
    starlette
    uvicorn
    # Graph exports / database sinks.
    neo4j
    psycopg # --postgres
    # Ingestion.
    pypdf
    markdownify # pdf
    python-docx
    openpyxl # office / google
    watchdog # watch
    faster-whisper
    yt-dlp # video / --whisper-model
    jieba # chinese tokenisation
    # Visualisation: --svg.
    matplotlib
    pillow
    scipy # networkx sparse layout behind --svg
    pyyaml # markdown frontmatter / manifest ingestion
    # Community detection (Leiden). On python >= 3.13 upstream depends on
    # graspologic-native; Graphify imports `graspologic_native` directly and
    # falls back to networkx Louvain when it is absent.
    graspologic-native
    # Extra tree-sitter languages the skill advertises.
    tree-sitter-sql
    tsg.tree-sitter-hcl # terraform
    tsg.tree-sitter-ocaml
    tsg.tree-sitter-commonlisp
    tsg.tree-sitter-pascal
    tsg.tree-sitter-solidity
    robotframework # robot
  ];

  # The library itself. `buildPythonPackage` (not `buildPythonApplication`):
  # the latter sets `pythonModule = false`, which makes `python3.withPackages`
  # silently drop the package.
  graphifyPkg = pkgs.python3Packages.buildPythonPackage rec {
    pname = "graphify";
    inherit version;
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "Graphify-Labs";
      repo = "graphify";
      tag = "v${version}";
      hash = "sha256-Ea4PbIEJ/0stwTo8KF7DMD9oRsKvxCkFVozdR+Mka9U=";
    };

    build-system = [ pkgs.python3Packages.setuptools ];

    # The tree-sitter grammar bindings track their own upstream repos and drift
    # from the loose pins Graphify declares. Relax every version constraint: the
    # interpreter and every dependency is already pinned by this flake.
    pythonRelaxDeps = true;

    dependencies = core ++ extras;

    pythonImportsCheck = [ "graphify" ];

    # The attribute and command are `graphify`, but upstream publishes the
    # distribution as `graphifyy`, so the metadata check cannot resolve it by
    # pname.
    dontCheckPythonMetadata = true;

    meta = {
      description = "Turn any folder of code, docs, papers, images, or videos into a queryable knowledge graph.";
      homepage = "https://github.com/Graphify-Labs/graphify";
      changelog = "https://github.com/Graphify-Labs/graphify/blob/v${version}/CHANGELOG.md";
      license = with lib.licenses; [
        asl20
        mit
      ];
    };
  };

  # An interpreter that has Graphify (and every extra) on its `sys.path`.
  #
  # This is not cosmetic. Graphify's own agent skill discovers "the Python that
  # can import graphify" by reading the shebang of `$(which graphify)`, then
  # persists `sys.executable` into `graphify-out/.graphify_python` and runs every
  # later pipeline step as `$(cat graphify-out/.graphify_python) -m graphify ...`.
  # The stock `buildPythonApplication` launcher is a bash script, so that shebang
  # probe fails, the skill falls back to a bare `python3`, and every subsequent
  # `-m graphify` invocation dies with "No module named graphify".
  graphifyEnv = pkgs.python3.withPackages (ps: [ graphifyPkg ]);

  # Note the interpreter path is the env's, and `withPackages` normally rewrites
  # console scripts into ELF launchers — which would defeat the shebang-based
  # discovery above. So install plain Python scripts instead.
  launcher = name: module: attr: ''
    cat > $out/bin/${name} <<'GRAPHIFY_LAUNCHER'
    #!${graphifyEnv}/bin/python3.14
    # Launcher installed by the pi-nix flake. The shebang deliberately points at
    # a `python3.withPackages` environment that can `import graphify`: Graphify's
    # agent skill reads this very line to discover the interpreter it must use.
    import sys

    from ${module} import ${attr}

    if __name__ == "__main__":
        sys.exit(${attr}())
    GRAPHIFY_LAUNCHER
    chmod +x $out/bin/${name}
  '';
in
pkgs.runCommand "graphify-${version}" {
  inherit version;

  passthru.python = graphifyEnv;

  meta = {
    description = "Turn any folder of code, docs, papers, images, or videos into a queryable knowledge graph.";
    homepage = "https://github.com/Graphify-Labs/graphify";
    changelog = "https://github.com/Graphify-Labs/graphify/blob/v${version}/CHANGELOG.md";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "graphify";
    platforms = lib.platforms.unix;
  };
} ''
  mkdir -p $out/bin

  ${launcher "graphify" "graphify.__main__" "main"}
  ${launcher "graphify-mcp" "graphify.serve" "_main"}

  # Fail the build if the launcher cannot even report its version.
  "$out/bin/graphify" --version
''
