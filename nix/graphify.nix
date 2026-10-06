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
  version = "0.9.78";

  # Local patch revision. Bump whenever a patch below changes the installed
  # pi skill text or CLI behaviour: the wrapper compares this composite stamp
  # against ~/.pi/agent/skills/graphify/.graphify_version and re-runs
  # `graphify install --platform pi` when it differs (see nix/wrapper.nix).
  skillRevision = "2";

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
      hash = "sha256-WwcYQ3m/OtGmrO/kNd2ytUbHU3pnLeHc/vOCmJaQfg0=";
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

    # Defects found by the BANCO-WIKI corpus run (H1-H4 in the report), plus
    # the pi-skill interface mismatch (M1/M2). Carried here until upstream
    # releases them; each file is independently reviewable and has zero
    # whitespace-only noise so it can be sent as a PR.
    #
    # Order matters: h1-omission-recovery.patch calls `_unit_rel`, which
    # h4-reconcile-source-files.patch introduces.
    #
    #   skill-pi-subagents  skill dispatched chunks with an `Agent` tool and
    #                       `subagent_type="general-purpose"`, neither of which
    #                       exists in the pi harness (M1); also claimed only
    #                       GEMINI_API_KEY is read (M2).
    #   h4-reconcile       source_file values the model returned percent-encoded
    #                       or non-NFC were never mapped back to the dispatched
    #                       file, so nodes/edges pointed at dead paths and the
    #                       end-of-run diff reported them as omissions (H4).
    #   h1-omission         a clean, non-truncated chunk that silently omitted
    #                       some of its files was only warned about at the end of
    #                       the run, costing a whole-corpus re-extraction to
    #                       recover them (H1/H2).
    #   h3-save-cache       the all-groups-skipped warning blamed a wrong `root`
    #                       for what mangled source_file values actually caused,
    #                       and named no paths (H3).
    patches = [
      ./patches/skill-pi-subagents.patch
      ./patches/h4-reconcile-source-files.patch
      ./patches/h1-omission-recovery.patch
      ./patches/h3-save-cache-warning.patch
    ];
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

  # Composite version+patch stamp the wrapper uses to decide whether the
  # installed pi skill is current (see nix/wrapper.nix).
  passthru.skillStamp = "${version}-pi-nix.${skillRevision}";

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

  # The patch set is proven here, not assumed. This runs against the modules
  # in `graphifyEnv`, so it fails the build if a patch stopped applying in
  # effect (a hunk dropped as a fuzzy match, a helper renamed upstream, a
  # version bump that silently reverted a fix). It stubs the LLM call out and
  # writes its fixtures under TMPDIR: no network, no API key, no corpus.
  ${graphifyEnv}/bin/python3.14 ${./patches/selfcheck-graphify-fixes.py}
''
