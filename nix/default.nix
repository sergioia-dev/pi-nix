{
  system,
  pkgs,

  # ==================================================================
  # All tunable settings from flake.nix — each has a documented default
  # matching the pi upstream default.
  # ==================================================================

  # --- Model & Thinking ---
  defaultProvider ? "opencode",
  defaultModel ? "deepseek-v4-flash-free",
  defaultThinkingLevel ? null, # null = pi default ("off")
  hideThinkingBlock ? false,
  showCacheMissNotices ? false,
  thinkingBudgets ? null, # null = pi default levels

  # --- UI & Display ---
  theme ? "catppuccin-mocha",
  externalEditor ? null, # null = pi default ($VISUAL/$EDITOR/nano)
  quietStartup ? false,
  defaultProjectTrust ? "always",
  collapseChangelog ? false,
  enableInstallTelemetry ? true,
  enableAnalytics ? false,
  trackingId ? null,
  doubleEscapeAction ? "tree", # "tree", "fork", or "none"
  treeFilterMode ? "default", # "default", "no-tools", "user-only", "labeled-only", "all"
  editorPaddingX ? 0,
  outputPad ? 1,
  autocompleteMaxVisible ? 5,
  showHardwareCursor ? false,

  # --- Network ---
  httpProxy ? null, # null = no proxy

  # --- Warnings ---
  warningsAnthropicExtraUsage ? true,

  # --- Compaction ---
  compactionEnabled ? true,
  compactionReserveTokens ? 16384,
  compactionKeepRecentTokens ? 20000,

  # --- Branch Summary ---
  branchSummaryReserveTokens ? 16384,
  branchSummarySkipPrompt ? false,

  # --- Retry ---
  retryEnabled ? true,
  retryMaxRetries ? 10,
  retryBaseDelayMs ? 2000,
  retryProviderTimeoutMs ? 86400000,
  retryProviderMaxRetries ? 10,
  retryProviderMaxRetryDelayMs ? 300000,

  # --- Message Delivery ---
  steeringMode ? "one-at-a-time",
  followUpMode ? "one-at-a-time",
  transport ? "auto", # "auto", "sse", "websocket", "websocket-cached"
  httpIdleTimeoutMs ? 300000,
  websocketConnectTimeoutMs ? 15000,

  # --- Terminal & Images ---
  terminalShowImages ? true,
  terminalImageWidthCells ? 60,
  terminalClearOnShrink ? false,
  imagesAutoResize ? true,
  imagesBlockImages ? false,

  # --- Shell ---
  shellPath ? null,
  shellCommandPrefix ? null,
  npmCommand ? null,

  # --- Sessions ---
  sessionDir ? null,

  # --- Model Cycling ---
  enabledModels ? null,

  # --- Markdown ---
  markdownCodeBlockIndent ? "  ",

  # --- Resources ---
  enableSkillCommands ? true,
  extraExtensions ? [ ],
  extraSkills ? [ ],
  extraPrompts ? [ ],
    extraThemes ? [ ],
    # --- pi-plan-mode (declarative /plan config) ---
    planThinkingLevel ? "inherit",
    planDefaultTools ? [ "read" "bash" "grep" "find" "ls" ],
    planRetention ? "clear-on-start",
    planExportPath ? "PLAN.md",
    planSafeSubcommands ? { },
    planShortcut ? null,
  gitExtensions,
  npmExtensionSrc,
  npmExtensionSpecs, # list of "name" or "name@version"
  modelsJsonContent,
  keybindingsJsonContent,

}:

let

  inherit (pkgs) lib;
  basePi = pkgs.pi-coding-agent;

  # ---- ai-skills source (declarative fetch with submodules) ----
  # The hash covers the gitlab repo + submodule commits. After changing
  # `rev`, run `nix build .` once with `hash = lib.fakeHash` and replace
  # it with the printed `got: sha256-…` value.
  aiSkillsSrc = pkgs.fetchFromGitLab {

    owner = "sergioia-dev";
    repo = "ai-skills";
    rev = "e8c81ed95efff1e83245d0dd92beefdeb537d963";
    hash = "sha256-OdLunaZ3xCa1Uo/A2mqLHspMWH0zUiUDDhgAOc9qZoc=";

    fetchSubmodules = true;
  };

  # ---- Helpers ----
  utils = import ./utils.nix { inherit pkgs lib; };

  # ---- Npm extension metadata ----
  # "pi-vim@0.14.1" -> { name = "pi-vim"; version = "0.14.1"; }
  # "@scope/name@1.0.0" -> { name = "@scope/name"; version = "1.0.0"; }
  # "pi-vim" -> { name = "pi-vim"; version = null; }
  parseSpec =
    spec:
    let
      parts = lib.splitString "@" spec;
      isScoped = lib.hasPrefix "@" spec;
    in
    if isScoped then
      {
        name = "@${lib.elemAt parts 1}";
        version = if builtins.length parts > 2 then lib.elemAt parts 2 else null;
      }
    else
      {
        name = lib.elemAt parts 0;
        version = if builtins.length parts > 1 then lib.elemAt parts 1 else null;
      };

  npmExtSpecs = builtins.map (spec: "npm:${spec}") npmExtensionSpecs;

  # package.json content generated at eval time from npmExtensionSpecs
  packageJsonContent = builtins.toJSON {
    name = "pi-extensions";
    version = "0.0.0";
    private = true;
    dependencies = builtins.listToAttrs (
      map (spec: {
        name = (parseSpec spec).name;
        value = (parseSpec spec).version or "latest";
      }) npmExtensionSpecs
    );
  };

  # ---- Sync guard: extensions/package-lock.json must match npmExtensionSpecs ----
  lockfile = builtins.fromJSON (builtins.readFile (npmExtensionSrc + "/package-lock.json"));
  lockfileRootDeps = lockfile.packages."".dependencies or { };

  isExactVersion = v: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" v != null;

  specNamesSorted = lib.sort (a: b: a < b) (map (s: (parseSpec s).name) npmExtensionSpecs);
  lockNamesSorted = lib.sort (a: b: a < b) (lib.attrNames lockfileRootDeps);
  namesMatch = specNamesSorted == lockNamesSorted;

  # Specs with an exact version must match the locked version; versionless
  # specs and non-semver ranges are accepted as long as the name is present.
  versionsMatch = builtins.all (
    spec:
    let
      p = parseSpec spec;
    in
    p.version == null || !isExactVersion p.version || (lockfileRootDeps.${p.name} or null) == p.version
  ) npmExtensionSpecs;

  syncOk = namesMatch && versionsMatch;

  syncError = ''
    extensions/package-lock.json is out of sync with npmExtensionSpecs in flake.nix.
    Run:  nix run .#add-npm-dep
    Then: nix build .
  '';

  # ---- Git extension metadata ----
  gitExtSpecs = builtins.attrNames gitExtensions;
  gitExtFetched = builtins.mapAttrs (spec: hash: utils.fetchGitExt spec hash) gitExtensions;

  # ---- Combined specs ----
  extensionSpecs = npmExtSpecs ++ gitExtSpecs;
  extensionPackageNames = builtins.map utils.extName extensionSpecs;

  # ---- Build npm packages (no hash needed: integrity comes from the lockfile) ----
  npmExtensions =
    if syncOk then
      pkgs.importNpmLock.buildNodeModules {
        npmRoot = npmExtensionSrc;
        package = builtins.fromJSON packageJsonContent;
        packageLock = lockfile;
        nodejs = pkgs.nodejs;
        derivationArgs = {
          npmFlags = [ "--legacy-peer-deps" ];
        };
      }
    else
      throw syncError;

  # ---- Tooling: add-npm-dep script + nix run apps ----
  addNpmDep = pkgs.writeShellApplication {
    name = "add-npm-dep";
    runtimeInputs = [
      pkgs.nix
      pkgs.nodejs
    ];
    text = builtins.readFile ../add-npm-dep.sh;
  };

  syncAndBuild = pkgs.writeShellApplication {
    name = "build";
    runtimeInputs = [
      pkgs.nix
      addNpmDep
    ];
    text = ''
      if [ ! -f flake.nix ]; then
        echo "error: run from the flake root (no flake.nix in $(pwd))" >&2
        exit 1
      fi
      add-npm-dep
      exec nix build .
    '';
  };

  # ---- Combined extensions tree ----
  allExtensions = import ./extensions.nix {
    inherit
      pkgs
      lib
      npmExtensions
      gitExtensions
      gitExtFetched
      extensionPackageNames
      ;
  };

  # ---- Build settings JSON from all the tunables ----
  # All options are included here -- null where unset -- so you can verify
  # every setting in flake.nix is wired through to the generated JSON.
  # Pi treats null the same as an absent attribute for all settings EXCEPT
  # enabledModels (crashes on null in interactive mode), so that is
  # normalized to [] below.
  settingsJsonContent = builtins.toJSON {
    # --- Model & Thinking ---
    inherit defaultProvider defaultModel theme;
    defaultThinkingLevel = defaultThinkingLevel;
    hideThinkingBlock = hideThinkingBlock;
    showCacheMissNotices = showCacheMissNotices;
    thinkingBudgets = thinkingBudgets;

    # --- UI & Display ---
    quietStartup = quietStartup;
    defaultProjectTrust = defaultProjectTrust;
    collapseChangelog = collapseChangelog;
    enableInstallTelemetry = enableInstallTelemetry;
    enableAnalytics = enableAnalytics;
    trackingId = trackingId;
    doubleEscapeAction = doubleEscapeAction;
    treeFilterMode = treeFilterMode;
    editorPaddingX = editorPaddingX;
    outputPad = outputPad;
    autocompleteMaxVisible = autocompleteMaxVisible;
    showHardwareCursor = showHardwareCursor;
    externalEditor = externalEditor;

    # --- Network ---
    httpProxy = httpProxy;

    # --- Warnings ---
    warnings = {
      anthropicExtraUsage = warningsAnthropicExtraUsage;
    };

    # --- Compaction ---
    compaction = {
      enabled = compactionEnabled;
      reserveTokens = compactionReserveTokens;
      keepRecentTokens = compactionKeepRecentTokens;
    };

    # --- Branch Summary ---
    branchSummary = {
      reserveTokens = branchSummaryReserveTokens;
      skipPrompt = branchSummarySkipPrompt;
    };

    # --- Retry ---
    retry = {
      enabled = retryEnabled;
      maxRetries = retryMaxRetries;
      baseDelayMs = retryBaseDelayMs;
      provider = {
        timeoutMs = retryProviderTimeoutMs;
        maxRetries = retryProviderMaxRetries;
        maxRetryDelayMs = retryProviderMaxRetryDelayMs;
      };
    };

    # --- Message Delivery ---
    inherit steeringMode followUpMode transport;
    httpIdleTimeoutMs = httpIdleTimeoutMs;
    websocketConnectTimeoutMs = websocketConnectTimeoutMs;

    # --- Shell ---
    shellPath = shellPath;
    shellCommandPrefix = shellCommandPrefix;
    npmCommand = npmCommand;

    # --- Sessions ---
    sessionDir = sessionDir;

    # --- Model Cycling ---
    # null is NOT safe for pi -- interactive mode crashes on null.length.
    # Normalize null -> [] (empty list behaves identically to unset)
    enabledModels = if enabledModels != null then enabledModels else [ ];

    # --- Terminal & Images ---
    terminal = {
      showImages = terminalShowImages;
      imageWidthCells = terminalImageWidthCells;
      clearOnShrink = terminalClearOnShrink;
    };
    images = {
      autoResize = imagesAutoResize;
      blockImages = imagesBlockImages;
    };

    # --- Markdown ---
    markdown = {
      codeBlockIndent = markdownCodeBlockIndent;
    };

    # --- Resources ---
    packages = extensionSpecs;
    inherit enableSkillCommands;
    extensions = extraExtensions;
    skills = [ "${aiSkillsSrc}" ] ++ extraSkills;

    prompts = extraPrompts;
    themes = extraThemes;
  };
  # ---- pi-plan-mode config JSON ----
  # Separate from settings.json; the extension reads it at session start
  # from $PI_CODING_AGENT_DIR/pi-plan-mode.json. toggleShortcut is omitted
  # (null) when not configured so the global Plan-mode keybinding stays off.
  planModeJsonContent = builtins.toJSON (
    {
      thinkingLevel = planThinkingLevel;
      defaultPlanTools = planDefaultTools;
      implementationPlanRetention = planRetention;
      defaultPlanExportPath = planExportPath;
      safeSubcommands = planSafeSubcommands;
    } // (if planShortcut != null then {
      toggleShortcut = planShortcut;
    } else { })
  );

  settingsJson = pkgs.writeText "settings.json" settingsJsonContent;
  planModeJson = pkgs.writeText "pi-plan-mode.json" planModeJsonContent;


  # ---- Config stamp ----
  # Hash the full settings JSON + models + keybindings + ai-skills store
  # path so ANY setting change or skills-tree update triggers a runtime
  # config reinstall.
  configStampValue = builtins.hashString "sha256" (
    settingsJsonContent + modelsJsonContent + keybindingsJsonContent + planModeJsonContent + "${aiSkillsSrc}"
  );
  # ---- Wrapper script ----
  piWrapper = import ./wrapper.nix {

    inherit
      pkgs
      basePi
      settingsJson
      allExtensions
      configStampValue
      modelsJsonContent
      keybindingsJsonContent
      planModeJsonContent
      aiSkillsSrc
      ;
  };

in
{
  packages = {
    default = piWrapper;
    pi = piWrapper;
  };
  apps = {
    default = {
      type = "app";
      program = "${piWrapper}/bin/pi";
    };
    pi = {
      type = "app";
      program = "${piWrapper}/bin/pi";
    };
    # Alias of add-npm-dep: regenerate extensions/package.json +
    # package-lock.json from npmExtensionSpecs in flake.nix and re-sync.
    update = {
      type = "app";
      program = "${addNpmDep}/bin/add-npm-dep";
    };
    build = {
      type = "app";
      program = "${syncAndBuild}/bin/build";
    };
  };
  devShells = {
    default = pkgs.mkShell {
      packages = [
        pkgs.nodejs
        pkgs.nixfmt
      ];
      shellHook = ''
        echo "Nix-Pi devShell — Node.js $(node --version) ready"
      '';
    };
  };
  formatter = pkgs.nixfmt;
}
