{
  config,
  lib,
  pkgs,
  ...
}:
{
  # The on-screen keyboard lives inside fcitx, so KWin's one input method
  # slot stays "Fcitx 5" and it works on the desktop and the lock screen
  # alike.
  i18n.inputMethod.fcitx5.addons = [ pkgs.kyaru.fcitx5-hotaru ];

  # Let the logged-in seat user open /dev/uinput for hotaru's Ctrl/Alt chords
  # (KWin drops modifiers on zwp_input_method_context_v1.keysym for v3 clients).
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess"
  '';

  # The SDDM greeter runs its own KWin as the sddm user with no fcitx, so
  # before the first login there is nothing to type the password with.
  # Give that KWin the same fcitx as its input method.
  services.displayManager.sddm.wayland.compositorCommand =
    lib.mkIf (config.services.displayManager.sddm.wayland.compositor == "kwin")
      (
        lib.mkForce (
          lib.concatStringsSep " " [
            "${lib.getBin pkgs.kdePackages.kwin}/bin/kwin_wayland"
            "--no-global-shortcuts"
            "--no-kactivities"
            "--no-lockscreen"
            "--locale1"
            "--inputmethod"
            "${config.i18n.inputMethod.package}/libexec/fcitx5-wayland-launcher"
          ]
        )
      );
}
