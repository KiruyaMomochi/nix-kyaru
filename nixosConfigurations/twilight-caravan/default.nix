{ config, pkgs, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  kyaru.enable = true;
  kyaru.vps.enable = true;
  services.qemuGuest.enable = true;
  boot.loader.grub.device = "/dev/sda";
  time.timeZone = "Asia/Taipei";

  system.stateVersion = "26.11";
}
