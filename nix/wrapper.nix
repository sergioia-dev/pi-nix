{
  pkgs,
  basePi,
  settingsJson,
  allExtensions,
  configStampValue,
  modelsJsonContent,
  keybindingsJsonContent,
  planModeJsonContent,
  aiSkillsSrc,
}:
let
  # graphify imports its optional features lazily (LLM backends, MCP server,
  # watch mode, PDF/office ingestion, graph exports). nixpkgs ships them as
  # `optional-dependencies` extras but installs none of them, so the commands
  # the graphify skill documents die with "No module named ...". Pull the
  # extras into `dependencies` so wrap-python-hook puts them on graphify's own
  # sys.path (a PATH entry would not make them importable).
  graphifyExtras = [
    "openai"    # deepseek/openai/gemini/kimi/ollama backends + tiktoken
    "anthropic" # claude backend
    "bedrock"   # boto3 backend
    "mcp"       # graphify --mcp (mcp + starlette)
    "watch"     # graphify watch
    "pdf"       # pypdf + markdownify: papers, `graphify add <url>`
    "office"    # openpyxl + python-docx
    "svg"       # graphify --svg (matplotlib)
    "neo4j"     # graphify --neo4j
    "postgres"  # graphify --postgres
  ];

  # nixpkgs' extras also miss two deps graphify really imports: scipy (networkx
  # sparse layout behind --svg) and PyYAML (markdown frontmatter).
  graphifyExtraPackages = with pkgs.python3Packages; [ scipy pyyaml ];

  graphifyWithExtras = pkgs.graphify.overridePythonAttrs (old: {
    dependencies =
      (old.dependencies or [ ])
      ++ graphifyExtraPackages
      ++ pkgs.lib.concatMap (extra: pkgs.graphify.optional-dependencies.${extra}) graphifyExtras;
  });
in
pkgs.writeShellScriptBin "pi" ''
    set -e

    PI_PARENT="$HOME/.local/share/pi-nix"
    PI_AGENT_DIR="$PI_PARENT/agent"
    export PI_CODING_AGENT_DIR="$PI_AGENT_DIR"
    export PI_HOME="$PI_AGENT_DIR"
    export PI_SKIP_VERSION_CHECK=1
    export PATH="${pkgs.lib.makeBinPath [ pkgs.nodejs graphifyWithExtras ]}:$PATH"

    mkdir -p "$PI_AGENT_DIR"

    # Ensure ~/.pi symlink points to parent
    if ! test -L "$HOME/.pi" || test "$(readlink "$HOME/.pi")" != "$PI_PARENT"; then
      if test -e "$HOME/.pi" || test -L "$HOME/.pi"; then
        n=1; while test -e "$HOME/.pi.bak.$n"; do n=$((n+1)); done
        mv "$HOME/.pi" "$HOME/.pi.bak.$n"
      fi
      ln -s "$PI_PARENT" "$HOME/.pi"
    fi

    # ---- Stamp check: if config changed or store path GCd, rebuild ----
    INSTALL_STAMP="$PI_AGENT_DIR/.install-stamp"
    DESIRED_STAMP="${configStampValue}"

    if ! test -f "$INSTALL_STAMP" || test "$(cat "$INSTALL_STAMP")" != "$DESIRED_STAMP"; then
      rm -f "$PI_AGENT_DIR/settings.json"
      rm -f "$PI_AGENT_DIR/models.json"
      rm -f "$PI_AGENT_DIR/keybindings.json"
      rm -f "$PI_AGENT_DIR/pi-plan-mode.json"

      ln -sfn ${settingsJson} "$PI_AGENT_DIR/settings.json"

      cat > "$PI_AGENT_DIR/models.json" << 'PI_MODELS_EOF'
    ${modelsJsonContent}
  PI_MODELS_EOF
      cat > "$PI_AGENT_DIR/keybindings.json" << 'PI_KEYS_EOF'
    ${keybindingsJsonContent}
  PI_KEYS_EOF
      cat > "$PI_AGENT_DIR/pi-plan-mode.json" << 'PI_PLAN_EOF'
    ${planModeJsonContent}
  PI_PLAN_EOF

      echo "$DESIRED_STAMP" > "$INSTALL_STAMP"
    else
      # Stamp matches but verify symlink targets (GC resilience)
      for _cfg in settings.json models.json keybindings.json; do
        _f="$PI_AGENT_DIR/$_cfg"
        if test -L "$_f" && ! test -e "$(readlink "$_f")"; then
          rm -f "$_f"
        fi
      done
      if ! test -f "$PI_AGENT_DIR/settings.json"; then
        rm -f "$INSTALL_STAMP"
        ln -sfn ${settingsJson} "$PI_AGENT_DIR/settings.json"
        cat > "$PI_AGENT_DIR/models.json" << 'PI_MODELS_EOF'
    ${modelsJsonContent}
  PI_MODELS_EOF
        cat > "$PI_AGENT_DIR/keybindings.json" << 'PI_KEYS_EOF'
    ${keybindingsJsonContent}
  PI_KEYS_EOF
        echo "$DESIRED_STAMP" > "$INSTALL_STAMP"
      fi
    fi

    # ---- npm extensions ----
    PI_NPM_DIR="$PI_AGENT_DIR/npm"
    mkdir -p "$PI_NPM_DIR"
    NPM_TARGET="${allExtensions}/node_modules"
    CURRENT="$(test -L "$PI_NPM_DIR/node_modules" && readlink "$PI_NPM_DIR/node_modules" || true)"
    # Replace any stale symlink, real (npm-installed) dir, or GC'd target with
    # the store-backed symlink so pi uses the pre-built packages offline.
    if [ "$CURRENT" != "$NPM_TARGET" ] || { [ -n "$CURRENT" ] && ! test -e "$CURRENT"; }; then
      rm -rf "$PI_NPM_DIR/node_modules"
      ln -s "$NPM_TARGET" "$PI_NPM_DIR/node_modules"
    fi

    # ---- Git extensions (generic walk of all subdirs) ----
    PI_GIT_BASE="$PI_AGENT_DIR/git/github.com"
    if [ -d "${allExtensions}/git/github.com" ]; then
      for owner_dir in "${allExtensions}/git/github.com"/*/; do
        [ -d "$owner_dir" ] || break
        owner="$(basename "$owner_dir")"
        for repo_dir in "$owner_dir"*/; do
          [ -d "$repo_dir" ] || break
          repo="$(basename "$repo_dir")"
          mkdir -p "$PI_GIT_BASE/$owner"
          GIT_TARGET="${allExtensions}/git/github.com/$owner/$repo"
          CURRENT_GIT="$(test -L "$PI_GIT_BASE/$owner/$repo" && readlink "$PI_GIT_BASE/$owner/$repo" || true)"
          if [ "$CURRENT_GIT" != "$GIT_TARGET" ] || { [ -n "$CURRENT_GIT" ] && ! test -e "$CURRENT_GIT"; }; then
            ln -sfn "$GIT_TARGET" "$PI_GIT_BASE/$owner/$repo"
          fi
        done
      done
    fi

    # ---- ai-skills integration ----
    # The skills tree is content-addressed in the Nix store (with all git
    # submodules), so we just symlink it into the agent runtime dir. The
    # path is also already in settings.json (built at eval time), so no
    # runtime mutation of settings.json is needed.
    AI_SKILLS_AGENT="$PI_AGENT_DIR/skills/ai-skills"
    mkdir -p "$PI_AGENT_DIR/skills"
    if [ ! -L "$AI_SKILLS_AGENT" ] || [ "$(readlink "$AI_SKILLS_AGENT")" != "${aiSkillsSrc}" ]; then
      ln -sfn "${aiSkillsSrc}" "$AI_SKILLS_AGENT"
    fi

    # ---- graphify pi skill ----
    # graphify ships its own pi skill (SKILL.md + references/). Install it into
    # the agent skills dir so pi loads it natively as a user skill, instead of
    # pulling it from the graphify-pi npm extension. Guarded by graphify's own
    # version stamp so the python startup cost is paid only when the skill is
    # missing or outdated.
    GRAPHIFY_SKILL_DIR="$PI_AGENT_DIR/skills/graphify"
    if [ "$(cat "$GRAPHIFY_SKILL_DIR/.graphify_version" 2>/dev/null)" != "${graphifyWithExtras.version}" ]; then
      graphify install --platform pi >/dev/null 2>&1 ||
        echo "warning: could not install the graphify pi skill; run 'graphify install --platform pi' manually" >&2
    fi

    exec ${basePi}/bin/pi "$@"
''
