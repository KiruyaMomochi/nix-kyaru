{ lib
, stdenvNoCC
, fetchurl
, unzip
, installFonts
}:
stdenvNoCC.mkDerivation rec {
  pname = "MapleMono-NF-TC";
  version = "8.0-beta.3";

  src = fetchurl {
    url = "https://github.com/subframe7536/maple-font/releases/download/v${version}/${pname}.zip";
    hash = "sha256-5fNxEkvXJVoPJh5QW8zSwnyVpZVIxavIFgZwfSvdB9I=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [
    installFonts
    unzip
  ];

  meta = {
    description = "Open source Nerd Font Traditional Chinese monospace font with round corners and ligatures";
    homepage = "https://github.com/subframe7536/maple-font";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
