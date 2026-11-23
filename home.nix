{
  inputs,
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    {
      nixpkgs.overlays = [
      ];
    }
  ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = lib.mkDefault "kyaru";
  home.homeDirectory = "/home/${config.home.username}";

  nixpkgs.config = lib.mkDefault (import ./nixpkgs-config.nix);
  xdg.configFile."nixpkgs/config.nix".source = lib.mkDefault ./nixpkgs-config.nix;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  nix.package = pkgs.nixVersions.latest;

  # Packages that should be installed to the user profile.
  home.packages =
    (with pkgs; [
      # utils
      bat # cat
      fd # find
      procs # ps
      sd # sed
      (btop.override {
        cudaSupport = true;
      }) # htop
      delta # diff
      ripgrep # grep
      erdtree # tree and du
      choose # cut and sometimes awk
      lurk # strace
      aria2
      lnav

      # common commands
      file
      unzip
      ldns
      tldr
      p7zip
      jq
      yq

      # nix related
      nil
      nixd
      nixfmt
      nixpkgs-review
      cachix
      nix-output-monitor
      expect
      nh
      (pkgs.writeShellScriptBin "manix" ''
        export NIX_PATH="/home/${config.home.username}/.nix-defexpr/50-home-manager''${NIX_PATH:+:$NIX_PATH}"
        exec ${lib.getExe pkgs.manix} "$@"
      '')
      (writeScriptBin "nx" (builtins.readFile ./scripts/nx.nu))

      # for developing
      gh
      glab
      gitui
      shellcheck
      shfmt
      tombi

      # others
      android-tools # adb for phone CDP/automation
      dconf # fix dconf error
      # typst-lsp # not working
      rclone
      vscode-json-languageserver

      # ai
      mods
      (writeShellScriptBin "opencode" (builtins.readFile ./scripts/opencode-wrapper.sh))
      (writeShellScriptBin "claude" (builtins.readFile ./scripts/claude-wrapper.sh))
      (writeShellScriptBin "pi" (builtins.readFile ./scripts/pi-wrapper.sh))
      (writeShellScriptBin "agy" (builtins.readFile ./scripts/agy-wrapper.sh))
    ])
    ++ lib.optionals (!config.programs.kyaru.mobile.enable) (with pkgs; [
      pciutils
      typst
      awscli2
      agent-browser
      d2
      nushellPlugins.polars
    ])
    ++ (with pkgs.nushellPlugins; [
      formats
      gstat
      query
    ]);

  home.shellAliases = {
    "ip" = "ip -c";
    "cp" = "cp -v";
  };

  programs.fish = {
    enable = true;
    plugins = [ ];
  };

  programs.tmux = {
    enable = true;
    plugins = with pkgs; [
      tmuxPlugins.tmux-thumbs
    ];
    terminal = "tmux-256color";

    extraConfig = ''
      set -g mouse on
      setw -g mode-keys vi
    '';
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = "百地 希留耶";
      user.email = "65301509+KiruyaMomochi@users.noreply.github.com";
      init.defaultBranch = "main";
    };
    # Each machine signs with its own ~/.ssh/id_ed25519; add the pubkey to
    # GitHub as a *Signing* key. Old commits stay verified via the GPG key
    # 0xE3F508DE86FF810F as long as it remains on GitHub.
    signing = {
      format = "ssh";
      key = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      signByDefault = true;
      allowedSigners = ''
        65301509+KiruyaMomochi@users.noreply.github.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt7EEGFGu0Yg/XlowRZugaAWaHtdwOwx52VH6/5Yzn9 kyaru@caon
        65301509+KiruyaMomochi@users.noreply.github.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUwCNvrK5agVa8IkhffJCJYptMC7XrDul7XSjSM5tpG kyaru@sarendia-orphanage
      '';
    };
    includes = [
      {
        path = "config.extra";
      }
    ];

    lfs = {
      enable = true;
      skipSmudge = true;
    };
  };
  programs.delta.enable = true;
  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
  };
  programs.zoxide = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.gpg = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
    # defaultCacheTtl = 1800;
    # enableSshSupport = true;
  };

  programs.ssh = {
    enable = lib.mkDefault false;
    enableDefaultConfig = false;
    includes = [ "~/.ssh/config.d/*" ];
    settings = {
      "github.com" = {
        hostname = "ssh.github.com";
        port = 443;
        user = "git";
      };
    };
  };

  services.ssh-agent = {
    enable = true;
  };

  programs.uv = {
    enable = true;
  };

  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
    settings = {
      prompt = true;
      editor = "${config.programs.helix.package}/bin/hx";
      # https://github.com/nix-community/home-manager/pull/4749
      version = "1";
    };
  };

  programs.direnv = {
    enable = true;
    enableBashIntegration = true; # see note on other shells below
    # Upstream hook (home-manager#10162) runs `direnv export json e> /dev/stderr | complete`,
    # which re-opens /dev/stderr -> /proc/self/fd/2 -> /dev/pts/N and fails with EACCES
    # when the PTY is owned by another UID (e.g. `machinectl shell`, `su`, `sudo -iu`).
    # Configured manually in programs.nushell.extraConfig below using `complete` + `print -e -n`.
    enableNushellIntegration = false;
    nix-direnv.enable = true;
  };

  # ls
  programs.eza = {
    enable = true;
    enableNushellIntegration = false;
  };

  # top
  programs.htop.enable = true;

  # shell completion
  programs.carapace = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = true;
  };
  programs.kyaru.carapace.bridges = {
    nix = "fish";
    ssh = "fish";
    scp = "fish";
    rsync = "fish";
  };
  home.sessionVariables = {
    # https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/flag/flag.ts
    OPENCODE_ENABLE_EXPERIMENTAL_MODELS = "1";
    OPENCODE_EXPERIMENTAL = "1";
    OPENCODE_ENABLE_EXA = "1";
    PI_CACHE_RETENTION = "long";
  };

  programs.nushell = {
    enable = true;
    # # https://github.com/nushell/nushell/blob/main/crates/nu-utils/src/default_files/default_config.nu
    configFile.source = ./homeModules/nushell/config.nu;
    # # https://github.com/nushell/nushell/blob/main/crates/nu-utils/src/default_files/default_env.nu
    envFile.source = ./homeModules/nushell/env.nu;
    loadSessionVariables = true;
    environmentVariables = {
      CARAPACE_BRIDGES = (
        lib.strings.concatStringsSep "," [
          "fish"
          "bash"
          "inshellisense"
        ]
      );
    };

    extraConfig = lib.strings.concatStringsSep "\n" [
      # Make home.sessionVariables work with nushell
      # https://github.com/nix-community/home-manager/issues/4313
      # home.sessionVariables.EDITOR = "${config.programs.helix.package}/bin/hx";
      ''
        if not ("EDITOR" in $env) {
          $env.EDITOR = "${config.programs.helix.package}/bin/hx"
        }
      ''
      ''
        $env.config.hooks.command_not_found = { |cmd_name|
          try {
            let commands = (^"${config.programs.nix-index.package}/bin/nix-locate" --type x --type s --whole-name --at-root $"/bin/($cmd_name)" | lines | split column --collapse-empty " " name size type path)
            if ($commands | is-empty) {
              return null
            }
            let $pkgs = ($commands | get name | str join " ")
            return (
              $"(ansi $env.config.color_config.shape_external)($cmd_name)(ansi reset) " +
              $"may be found in the following packages:\n($pkgs)"
            )
          }
        }

        $env.config.buffer_editor = "${config.programs.helix.package}/bin/hx"
      ''
      # Manual direnv hook replacing home-manager's enableNushellIntegration (see programs.direnv above).
      # Uses `complete` to preserve stdout on non-zero exit (pipefail in nushell >= 0.111) and
      # `print -e -n` to write to the inherited fd 2 without re-opening /dev/stderr.
      ''
        $env.config = ($env.config? | default {})
        $env.config.hooks = ($env.config.hooks? | default {})
        $env.config.hooks.pre_prompt = (
            $env.config.hooks.pre_prompt?
            | default []
            | append {||
                let direnv_result = (
                    ${lib.getExe config.programs.direnv.package} export json
                    | complete
                )
                if not ($direnv_result.stderr | is-empty) {
                    print -e -n $direnv_result.stderr
                }
                let direnv = (
                    $direnv_result.stdout
                    | from json --strict
                    | default {}
                )

                for key in ($direnv | columns) {
                    if ($direnv | get $key) == null {
                        hide-env --ignore-errors $key
                    }
                }

                $direnv
                | items {|key, value|
                    let value = do (
                        {
                          "PATH": {
                            from_string: {|s| $s | split row (char esep) | path expand --no-symlink }
                            to_string: {|v| $v | path expand --no-symlink | str join (char esep) }
                          }
                        }
                        | merge ($env.ENV_CONVERSIONS? | default {})
                        | get ([[value, optional, insensitive]; [$key, true, true] [from_string, true, false]] | into cell-path)
                        | if ($in | is-empty) { {|x| $x} } else { $in }
                    ) $value
                    return [ $key $value ]
                }
                | where {|pair| $pair.1 != null }
                | into record
                | load-env
            }
        )
      ''
    ];
  };

  # editor
  programs.helix = {
    enable = true;
    settings = {
      editor.soft-wrap.enable = true;
    };
    languages.language = [
      {
        name = "nix";
        formatter = {
          command = "${pkgs.nixfmt}/bin/nixfmt";
        };
      }
      {
        name = "sshclientconfig";
        file-types = [
          { glob = ".ssh/config"; }
          { glob = ".ssh/config.d/*"; }
          { glob = "/etc/ssh/ssh_config"; }
          { glob = "/etc/ssh/ssh_config.d/*"; }
        ];
      }
    ];
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;
    validateFiles.config = true;
    settings = builtins.fromTOML (builtins.readFile ./homeModules/starship/config.toml);
  };
  xdg.dataFile."nushell/vendor/autoload/starship.nu".source = pkgs.runCommand "starship.nu" { } ''
    ${config.programs.starship.package}/bin/starship init nu > $out
    cat ${./homeModules/starship/transient.nu} >> $out
  '';

  # tmux
  programs.zellij = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableZshIntegration = false;
    settings = {
      default_shell = "${config.programs.nushell.package}/bin/nu";
      pane_frames = false;
      keybinds = {
        normal = {
          unbind = "Alt f";
        };
        pane = {
          unbind = "x";
        };
      };
      # Windows terminal, https://github.com/zellij-org/zellij/pull/4150
      support_kitty_keyboard_protocol = false;
    };
  };

  programs.nix-index-database.comma.enable = true;
  programs.nix-index.enable = true;

  xdg.dataFile."fcitx5/rime/default.custom.yaml".source =
    (pkgs.formats.yaml { }).generate "default.custom.yaml"
      {
        patch = {
          schema_list = [
            {
              "schema" = "double_pinyin_flypy";
            }
            # 注音（大千）；hotaru 認得這個方案會換成注音鍵盤
            {
              "schema" = "bopomofo_tw";
            }
          ];
          # 中英只靠 fcitx 的 Win+Space 切，rime 自己的 ascii 模式不让按键进
          "ascii_composer/switch_key" = {
            Shift_L = "noop";
            Shift_R = "noop";
            Caps_Lock = "noop";
          };
        };
      };

  services.vscode-server.enable = true;

  # User directories
  # https://wiki.archlinux.org/title/XDG_user_directories
  # xdg.userDirs.enable = true;
  xdg.userDirs.createDirectories = true;

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "26.05";
  home.enableNixpkgsReleaseCheck = false;
}
