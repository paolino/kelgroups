{ pkgs, project, version, ... }:

pkgs.dockerTools.buildImage {
  name = "ghcr.io/paolino/kelgroups";
  tag = version;
  config = {
    EntryPoint =
      [ "kelgroups-server" "3001" "/data/kelgroups.db" "bootstrap" ];
    ExposedPorts = { "3001/tcp" = { }; };
    Volumes = { "/data" = { }; };
    WorkingDir = "/app";
  };
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      project.packages."kelgroups:exe:kelgroups-server"
      (pkgs.runCommand "client-bundle" { } ''
        mkdir -p $out/app/client/kelgroups-trivial/dist
        cp -r ${../client/kelgroups-trivial/dist}/* \
          $out/app/client/kelgroups-trivial/dist/
      '')
    ];
  };
}
