{ lib
, stdenv
, fetchurl
, fetchzip
, bc
, perl
, tcl
, lua5_4
, lua54Packages
, rsync
, procps
, pkg-config
}:

let
  lua = lua5_4;
  luafilesystem = lua54Packages.luafilesystem;
  # Lmod 9.4.5 still calls posix.stat / posix.uname removed in luaposix 38.
  luaposix = lua54Packages.luaposix.overrideAttrs (_: {
    version = "37.0-1";
    knownRockspec = (fetchurl {
      url = "mirror://luarocks/luaposix-37.0-1.rockspec";
      sha256 = "0g3f5dh811hk35wm257wcfcbzpmgankpw578vf461kpa0jg84xph";
    }).outPath;
    src = fetchzip {
      url = "https://github.com/luaposix/luaposix/archive/v37.0.zip";
      sha256 = "0kr2r9mmpfpzmps4n5fb8acd7nr615mbs7f9b3fg7z6igfx4jllv";
    };
  });
in
stdenv.mkDerivation (finalAttrs: {
  pname = "Lmod";
  version = "9.4.5";

  src = fetchurl {
    url = "https://github.com/TACC/Lmod/archive/${finalAttrs.version}.tar.gz";
    hash = "sha256-BSkreh2ShahpEpcm8UKfhjk/4nS/EtMRgo4W3yfNqvM=";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ lua tcl perl rsync procps bc ];
  propagatedBuildInputs = [ luaposix luafilesystem ];

  configureFlags = [
    "--with-duplicatePaths=yes"
    "--with-caseIndependentSorting=yes"
    "--with-redirect=yes"
  ];

  preConfigure = ''
    patchShebangs proj_mgmt/
  '';

  postInstall = ''
    sed -i \
      -e 's:/usr/share/lua/${lua.luaversion}/?.lua;/usr/share/lua/${lua.luaversion}/?/init.lua;/usr/lib/lua/${lua.luaversion}/?.lua;/usr/lib/lua/${lua.luaversion}/?/init.lua;./?.lua;::g' \
      -e 's:/usr/lib/lua/${lua.luaversion}/?.so;/usr/lib/lua/${lua.luaversion}/loadall.so;./?.so;::g' \
      $(grep -rl "nix/store" "$out" | grep '\.lua') \
      $out/lmod/lmod/libexec/{computeHashSum,lmod,addto,spider,ml_cmd,spiderCacheSupport,sh_to_modulefile,update_lmod_system_cache_files} \
      $out/lmod/lmod/settarg/{settarg_cmd,targ}
  '';

  LUA_PATH = "${luaposix}/share/lua/${lua.luaversion}/?.lua;${luaposix}/share/lua/${lua.luaversion}/?/init.lua;;";
  LUA_CPATH = "${luafilesystem}/lib/lua/${lua.luaversion}/?.so;${luaposix}/lib/lua/${lua.luaversion}/?.so;;";

  meta = {
    description = "Lua-based environment modules system";
    homepage = "https://github.com/TACC/Lmod";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
