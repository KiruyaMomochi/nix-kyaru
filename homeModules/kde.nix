{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.programs.kyaru.kde;
in
{
  options.programs.kyaru.kde = with lib; {
    enable = mkEnableOption "Kiruya's kde packages";
    konsoleRandomBreeze = mkEnableOption "Randomize the Breeze color scheme";
  };

  config = lib.mkIf cfg.enable {
    # KDE caches each app's Exec line (an absolute store path) in ksycoca and doesn't see
    # ~/.nix-profile move to a new generation, so the menu keeps launching old wrappers.
    # Rebuild it with the Plasma session's XDG_DATA_DIRS (the cache file is keyed on it);
    # with no session running there is nothing to refresh.
    home.activation.kbuildsycoca = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      dataDirs=$(${pkgs.systemd}/bin/systemctl --user show-environment 2>/dev/null \
        | ${pkgs.gnused}/bin/sed -n 's/^XDG_DATA_DIRS=//p')
      if [ -n "$dataDirs" ]; then
        run env XDG_DATA_DIRS="$dataDirs" ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 >/dev/null 2>&1 || true
      fi
    '';
    # https://wiki.nixos.org/w/index.php?title=KDE
    home.packages = (with pkgs; [
      krita
      qalculate-qt
      libreoffice-qt
      hunspell
      hunspellDicts.en-us-large
      qbittorrent # qbittorrent-enhanced
      kyaru.kwi
    ]) ++ (with pkgs.kdePackages; [
      ark
      kcolorchooser
      kate
      krdc
      dolphin
      yakuake
      konsole
      filelight
    ]);

    xdg.dataFile."konsole/Breeze.colorscheme" = lib.mkIf cfg.konsoleRandomBreeze {
      source =
        let
          concatString = pkgs.lib.concatStringsSep "\n";
          sections = [
            "Background"
            "BackgroundFaint"
            "BackgroundIntense"
            "Foreground"
            "ForegroundFaint"
            "ForegroundIntense"
          ];
          appendRandom = {
            RandomHueRange = 360;
            RandomSaturationRange = 100;
            # RandomLightnessRange = 10;
          };
          general =
            {
              Blur = true;
              ColorRandomization = true;
              Opacity = 0.83;
              Description = "Breeze Randomized";
              FillStyle = "Title";
            };
          breeze = pkgs.runCommand "my-derivation" { } ''
            install -Dm644 "${pkgs.konsole}/share/konsole/Breeze.colorscheme" $out

            # Remove all keys of appendRandom
            ${concatString (
              pkgs.lib.mapAttrsToList (k: v: "sed -i '/${k}=/d' $out") appendRandom
            )}

            # For each section append the new key
            for section in ${pkgs.lib.concatStringsSep " " sections}; do
              ${concatString (
                pkgs.lib.mapAttrsToList (k: v: "sed -i '/\\['$section'\\]/a ${k}=${toString v}' $out") appendRandom
              )}
            done          

            # Remove the full [General] section
            sed -i '/\[General\]/,/\[/d' $out
            # Append the new [General] section
            echo "[General]" >> $out
            ${concatString (
              pkgs.lib.mapAttrsToList (k: v: "echo '${k}=${toString v}' >> $out") general
            )}
          '';
        in
        breeze.out;
    };
  };
}
