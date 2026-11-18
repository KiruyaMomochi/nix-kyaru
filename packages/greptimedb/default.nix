{ lib
, stdenv
, fetchFromGitHub
, fetchurl
, makeRustPlatform
, fenix
, pkg-config
, protobuf
, cmake
, clang
, mold
, perl
, openssl
, zlib
, zstd
, libgit2
, rustfmt
}:

let
  rustToolchainChannel = "1.98.1";
  toolchainHash = "sha256-p8h3Sl/YRByZfZTAKXdsvF6xEenXKrXSVvpphmZENH4=";

  rustToolchain = (fenix.fromToolchainName {
    name = rustToolchainChannel;
    sha256 = toolchainHash;
  }).withComponents [
    "cargo"
    "rustc"
    "rust-src"
    "rustfmt"
    "clippy"
    "llvm-tools"
  ];

  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  # Cargo vendor flattens crate subdirectories and drops repo-level proto/
  # needed by otel-arrow-rust's build.rs (../../proto).
  otelArrowSrc = fetchFromGitHub {
    owner = "GreptimeTeam";
    repo = "otel-arrow";
    rev = "5da284414e9b14f678344b51e5292229e4b5f8d2";
    fetchSubmodules = true;
    hash = "sha256-rUf1jE/StIwWPaqiXyzU4rM7fXu4t5VgKNfIaq3M0V0=";
  };

  dashboardVersion = "v0.14.6";
  dashboardAssets = fetchurl {
    url = "https://github.com/GreptimeTeam/dashboard/releases/download/${dashboardVersion}/build.tar.gz";
    hash = "sha256-UGMCHRVzsL1rFfP9MOf2hRrb3W4bKimVh2z9vMoS07k=";
  };
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "greptimedb";
  version = "1.3.1";

  src = fetchFromGitHub {
    owner = "GreptimeTeam";
    repo = "greptimedb";
    rev = "v${finalAttrs.version}";
    hash = "sha256-cMQOqtNiCxbr44lf4zELR6qEBOPm1mCrgaQqarSCCP8=";
  };

  cargoHash = "sha256-qtvPTEWWdCn2WnDZZQQv2FMmySH0pPXWpTBjak1JPQI=";

  nativeBuildInputs = [
    pkg-config
    protobuf
    cmake
    clang
    mold
    perl
    rustfmt
  ];

  buildInputs = [
    openssl
    zlib
    zstd
    libgit2
  ];

  cargoBuildFlags = [ "-p" "cmd" "--bin" "greptime" ];
  buildFeatures = [ "servers/dashboard" ];

  postPatch = ''
    ln -sfn ${otelArrowSrc}/proto "$cargoDepsCopy/proto"

    for sub_dir in "$cargoDepsCopy"/source-git-*/substrait-*; do
      chmod -R u+w "$sub_dir"
      patch -d "$sub_dir" -p1 < ${./substrait-offline-version.patch}
    done

    tar -xzf ${dashboardAssets} -C src/servers/dashboard/
    substituteInPlace src/servers/build.rs \
      --replace-fail 'fetch_dashboard_assets();' '{};'
  '';

  doCheck = false;

  # GreptimeDB vendors aws-lc-sys, libsqlite3-sys, onig_sys, and its own
  # GreptimeTeam/jemallocator fork; opt out of nixpkgs's system-lib sentinels.
  dontCargoUseSystemLibs = true;

  # jemalloc's mremap probe trips glibc _FORTIFY_SOURCE checks.
  hardeningDisable = [ "fortify" ];

  env = {
    PROTOC = "${protobuf}/bin/protoc";
    ZSTD_SYS_USE_PKG_CONFIG = "1";
    RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
  };

  preBuild = ''
    export HOME=$TMPDIR
    export LD_LIBRARY_PATH="${lib.makeLibraryPath [ libgit2 zlib zstd openssl stdenv.cc.cc.lib ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';

  meta = {
    description = "Open-source unified time-series database for metrics, logs, and traces";
    homepage = "https://github.com/GreptimeTeam/greptimedb";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "greptime";
  };
})
