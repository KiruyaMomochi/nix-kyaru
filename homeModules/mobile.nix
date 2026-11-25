{ inputs, config, pkgs, lib, ... }:
let
  cfg = config.programs.kyaru.mobile;
  unpatchedPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = import ../nixpkgs-config.nix;
  };
in
{
  options.programs.kyaru.mobile.enable = lib.mkEnableOption "mobile mount-namespace runtime";

  config = lib.mkIf cfg.enable {
    # Use upstream prebuilt nushell until lucent populates Attic with the patched aarch64 build,
    # avoiding a multi-minute cargo compile on the phone's battery.
    programs.nushell.package = lib.mkDefault unpatchedPkgs.nushell;
    programs.kyaru.desktop.enable = lib.mkForce false;
    programs.kyaru.kde.enable = lib.mkForce false;
    programs.kyaru.hyprland.enable = lib.mkForce false;

    services.gpg-agent.enable = lib.mkForce false;
    services.ssh-agent.enable = lib.mkForce false;
    services.vscode-server.enable = lib.mkForce false;
    programs.starship.settings.container.disabled = true;

    nix.settings = {
      sandbox = false;
      filter-syscalls = false;
    };
  };
}
