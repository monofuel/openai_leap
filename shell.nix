let
  # pin specific versions
  pkgs = import (fetchTarball "https://nixos.org/channels/nixos-25.05/nixexprs.tar.xz") {
    config.allowUnfree = true;
  };
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    nim
    nimble
    # curly links against curl + openssl; -d:ssl needs libssl/libcrypto.
    curl
    openssl
  ];
  shellHook = ''
    export LD_LIBRARY_PATH=${pkgs.curl.out}/lib:${pkgs.openssl.out}/lib:$LD_LIBRARY_PATH
  '';
}
