{
  lib,
  kmscon,
  librime,
  rime-data,
  formats,
  runCommand,
  schemas ? [
    "double_pinyin_flypy"
    "bopomofo_tw"
  ],
  pageSize ? 5,
}:
let
  defaultCustomYaml = (formats.yaml { }).generate "default.custom.yaml" {
    patch = {
      schema_list = map (schema: { inherit schema; }) schemas;
      "menu/page_size" = pageSize;
      "switcher/hotkeys" = [ "Control+grave" ];
      "ascii_composer/switch_key" = {
        Shift_L = "noop";
        Shift_R = "noop";
        Caps_Lock = "noop";
      };
    };
  };

  prebuiltRimeData =
    runCommand "kmscon-rime-data"
      {
        nativeBuildInputs = [ librime ];
      }
      ''
        mkdir -p $out/share/rime-data
        cp -r --no-preserve=mode ${rime-data}/share/rime-data/. $out/share/rime-data/
        cp ${defaultCustomYaml} $out/share/rime-data/default.custom.yaml
        rime_deployer --build $out/share/rime-data $out/share/rime-data $out/share/rime-data/build
      '';
in
kmscon.overrideAttrs (old: {
  pname = "kmscon-rime";

  patches = (old.patches or [ ]) ++ [
    ./wiring.patch
  ];

  postPatch = (old.postPatch or "") + ''
    cp ${./ime.h} src/ime.h
    cp ${./ime.c} src/ime.c
  '';

  buildInputs = (old.buildInputs or [ ]) ++ [
    librime
  ];

  mesonFlags = (old.mesonFlags or [ ]) ++ [
    (lib.mesonEnable "ime" true)
    (lib.mesonOption "ime_shared_dir" "${prebuiltRimeData}/share/rime-data")
  ];

  passthru = (old.passthru or { }) // {
    rimeData = prebuiltRimeData;
  };
})
