{ self, inputs, ... }:
# TODO: support patching package with only .patch files?
let
  inherit (self.lib.packages) mkPackages;
in
{
  flake = rec {
    overlay = overlays.default;
    overlays.default = (
      final: prev:
      let
        fenixOverlay = inputs.fenix.overlays.default;
        fenixApplied = fenixOverlay final prev;
      in
      {
        inherit (fenixApplied) fenix;
        kyaru = (mkPackages final) // {
          hermes-agent = final.callPackage ../packages/hermes-agent { inherit inputs; };
        };
        # nix = prev.nix.overrideAttrs (old: {
        #   buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-sdk-cpp ];
        # });
        slirp4netns = prev.slirp4netns.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            ../packages/slirp4netns.patch
          ];
        });
        singularity = prev.singularity.override ({
          nvidia-docker = final.libnvidia-container;
        });
        d2 = prev.d2.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ../packages/d2-ascii-cjk-scale.patch
          ];
        });
        nushell = prev.nushell.overrideAttrs (old: {
          # reedline's Up/Down navigation defaults to PrefixSearch; switch to
          # SubstringSearch for fish-style mid-command history matching.
          postPatch = (old.postPatch or "") + ''
            reedline_dir=$(echo "$cargoDepsCopy"/*/reedline-*)
            substituteInPlace "$reedline_dir/src/engine.rs" \
              --replace-fail 'HistoryNavigationQuery::PrefixSearch(buffer)' \
                             'HistoryNavigationQuery::SubstringSearch(buffer)'
            sed -i 's/"files":{[^}]*}/"files":{}/' "$reedline_dir/.cargo-checksum.json"
          '';
        });
        # external-libs.patch drops upstream's `autoreconf -fi` on bundled RE-flex,
        # whose shipped aclocal.m4 targets automake 1.18 while nixpkgs ships 1.19.
        dragonflydb = prev.dragonflydb.overrideAttrs (old: {
          preConfigure = old.preConfigure + "\n(cd build/deps-nixpkgs/reflex && autoreconf -fi)\n";
        });
        # krdp: nixpkgs missing plasma-wayland-protocols → WITH_PLASMA_SESSION not built
        # --plasma flag is a no-op without this, falls back to broken PortalSession
        # upstream CMakeLists: find_package(PlasmaWaylandProtocols REQUIRED) when BUILD_PLASMA_SESSION=ON
        kdePackages = prev.kdePackages.overrideScope (
          kfinal: kprev: {
            krdp = kprev.krdp.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                kfinal.plasma-wayland-protocols
              ];
            });
          }
        );
        # cockroachdb/swiss in otelcol-contrib 0.155.0 uses runtime linknames removed in Go 1.27.
        opentelemetry-collector-releases = prev.opentelemetry-collector-releases.override {
          buildGoModule = final.buildGo126Module;
        };
      }
    );
  };
}
