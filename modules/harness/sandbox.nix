{
  lib,
  pkgs,
}: let
  inherit (lib) concatMap escapeShellArg escapeShellArgs makeBinPath;
  inherit (lib) optional optionalAttrs optionalString optionals unique;

  # ["--setenv" NAME VALUE, ...] for every attribute in the set.
  setenvArgs = attrs:
    concatMap (name: ["--setenv" name attrs.${name}]) (builtins.attrNames attrs);

  # ["FLAG" VALUE]
  flagValue = flag: value: [flag value];

  # ["FLAG" SOURCE DESTINATION]
  bind = flag: source: destination: [flag source destination];

  # ["FLAG" PATH PATH]
  bindSame = flag: path: bind flag path path;

  bindAll = flag: paths: concatMap (bindSame flag) paths;
in {
  # Build the command that runs cfg.command inside bubblewrap.
  #
  # `extraReadWritePaths` lets the module wiring add paths that are not part
  # of the public option set (for example devenv's project root).
  mkBwrapCommand = {
    cfg,
    extraReadWritePaths ? [],
  }: let
    staticHome = cfg.homeDir != null;

    readOnlyPaths = unique (map toString cfg.readOnlyPaths);
    readWritePaths = unique (map toString (
      cfg.readWritePaths
      ++ extraReadWritePaths
      ++ optional staticHome cfg.homeDir
    ));

    # The wrapped CLI gets the sandbox PATH; the wrapper only needs to locate
    # the executable.
    wrapper = pkgs.writeShellScriptBin cfg.wrapperName ''
      export PATH="${makeBinPath ([cfg.package] ++ cfg.extraPackages)}''${PATH:+:$PATH}"
      exec ${escapeShellArg cfg.command} "$@"
    '';
    wrappedCommand = "${wrapper}/bin/${cfg.wrapperName}";

    prefixArgs =
      [
        "--unshare-all"
        "--die-with-parent"
        "--new-session"
      ]
      ++ flagValue "--dev" "/dev"
      ++ flagValue "--proc" "/proc"
      ++ flagValue "--tmpfs" "/tmp"
      ++ flagValue "--cap-drop" "ALL"
      ++ bindSame "--ro-bind" "/nix/store"
      ++ bindSame "--ro-bind-try" "/etc/resolv.conf"
      ++ bindSame "--ro-bind-try" "/etc/hosts"
      ++ bindSame "--ro-bind-try" "/etc/nsswitch.conf"
      ++ bindSame "--ro-bind-try" "/etc/os-release"
      ++ bind "--ro-bind" "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" "/etc/ssl/certs/ca-certificates.crt"
      ++ bind "--symlink" "${pkgs.bashNonInteractive}/bin/sh" "/bin/sh"
      ++ bind "--symlink" "${pkgs.coreutils}/bin/env" "/usr/bin/env"
      ++ optional cfg.clearEnv "--clearenv";

    # HOME is intentionally absent: it is emitted separately so the env file
    # can override it, while cfg.environment still takes precedence.
    defaultEnv = optionalAttrs cfg.clearEnv {
      PATH = makeBinPath (cfg.extraPackages ++ [cfg.package]);
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    };

    suffixArgs =
      bindAll "--ro-bind" readOnlyPaths
      ++ bindAll "--bind" readWritePaths
      ++ optional cfg.enableNetwork "--share-net";

    # The wrapper sources the file outside the sandbox. Mask it afterwards so
    # a process inside cannot read the secrets from a mounted directory.
    maskArgs =
      optionals (cfg.environmentFile != null)
      (bind "--ro-bind" (toString pkgs.emptyFile) cfg.environmentFile);

    runtimeHomeSetup = optionalString (!staticHome) ''
      HARNESS_JAIL_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}/harness-jail"
      umask 077
      mkdir -p "$HARNESS_JAIL_HOME"
    '';

    # With clearEnv the inner script starts from an empty environment;
    # otherwise it inherits the host environment. The runtime home path is
    # always passed through so the inner script can bind it.
    envFlags =
      optionalString cfg.clearEnv " -i"
      + optionalString (!staticHome) " HARNESS_JAIL_HOME=\"$HARNESS_JAIL_HOME\"";

    # Sourcing the env file here (rather than in the outer script) lets the
    # same inner script handle both clearEnv modes.
    innerScript = pkgs.writeShellScript "bwrap-harness-inner" ''
      set -eo pipefail

      sandbox_home=${
        if staticHome
        then escapeShellArg (toString cfg.homeDir)
        else ''"$HARNESS_JAIL_HOME"''
      }
      unset HARNESS_JAIL_HOME

      ${optionalString (cfg.environmentFile != null) ''
        set -a
        . ${escapeShellArg cfg.environmentFile}
        set +a
      ''}

      ${optionalString cfg.clearEnv "unset PWD SHLVL _"}

      bwrap_args=(${escapeShellArgs prefixArgs})
      ${optionalString cfg.clearEnv ''
        # HOME comes after the prefix but before defaults and the env file.
        bwrap_args+=(--setenv HOME "$sandbox_home")
      ''}
      bwrap_args+=(${escapeShellArgs (setenvArgs defaultEnv)})
      ${optionalString cfg.clearEnv ''
        # Inherited/file environment comes after defaults so it can override
        # them, while cfg.environment below still wins.
        while IFS= read -r -d "" entry; do
          bwrap_args+=(--setenv "''${entry%%=*}" "''${entry#*=}")
        done < <(${pkgs.coreutils}/bin/env -0)
      ''}
      bwrap_args+=(${escapeShellArgs (setenvArgs cfg.environment)})
      ${optionalString (!staticHome) ''
        bwrap_args+=(--bind "$sandbox_home" "$sandbox_home")
      ''}
      bwrap_args+=(${escapeShellArgs suffixArgs})
      bwrap_args+=(${escapeShellArgs maskArgs})
      bwrap_args+=(-- ${escapeShellArgs ([wrappedCommand] ++ cfg.args)} "$@")

      exec ${pkgs.bubblewrap}/bin/bwrap "''${bwrap_args[@]}"
    '';
  in
    pkgs.writeShellScript "bwrap-harness" ''
      set -eo pipefail
      ${runtimeHomeSetup}
      exec ${pkgs.coreutils}/bin/env${envFlags} \
        ${pkgs.bash}/bin/bash --noprofile --norc ${innerScript} "$@"
    '';
}
