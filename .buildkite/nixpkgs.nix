let
  rev = "5f14d99efed32721172a819b6e78a5520bab4bc6";
  sha256 = "1nxqbcsc8bfmwy450pv6s12nbvzqxai5mr6v41y478pya26lb108";
in
import (fetchTarball {
  inherit sha256;
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
})
