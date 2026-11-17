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
        # nixpkgs PR #562910 aligns dragonflydb's automake with RE-flex.
        # The former RE-flex 5.2.2 pin now requests the missing aclocal-1.16.
        # nu_plugin_polars ethnum 1.5.2 -> 1.5.3 lockfile bump used to live here
        # (nixpkgs PR #546343, for the rustc 1.97 E0512 on mem::transmute(())).
        # That patch is now in nixpkgs itself as update-ethnum.patch, byte-for-byte
        # identical to the copy we carried, so keeping ours made patchPhase apply
        # the same hunk twice and fail with "Reversed (or previously applied)".
        # Removed 2026-08-11 along with packages/nushell-plugin-polars-ethnum-1.5.3.patch.
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
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (python-final: python-prev: {
            open-interpreter = python-prev.open-interpreter.overridePythonAttrs (old: {
              pythonRelaxDeps = old.pythonRelaxDeps ++ [
                "html2text"
              ];
            });
          })
        ];
      }
    );
  };
}
