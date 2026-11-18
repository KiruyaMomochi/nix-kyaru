{ lib
, rustPlatform
, fetchFromGitHub
, rust-jemalloc-sys
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "shadowquic";
  version = "0.4.12";

  src = fetchFromGitHub {
    owner = "spongebob888";
    repo = "shadowquic";
    tag = "v${finalAttrs.version}";
    hash = "sha256-0JXO/kFAQyCwHrYYEck4XVv/n7QrGHWOTJvYfJtFO9Q=";
  };

  cargoHash = "sha256-NBUnLWuuRfNZsiEa/t3uO7huZoUZ4ylv2LL3keaM3+U=";

  buildInputs = [ rust-jemalloc-sys ];

  # workspace default-members = [ "shadowquic" ]
  cargoBuildFlags = [ "-p" "shadowquic" ];
  doCheck = false;

  meta = {
    description = "0-RTT QUIC proxy with SNI camouflage (JLS)";
    homepage = "https://github.com/spongebob888/shadowquic";
    license = lib.licenses.mit;
    mainProgram = "shadowquic";
  };
})
