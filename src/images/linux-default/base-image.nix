# ubuntu:26.04 pinned by digest, for offline VM tests only. The Dockerfile
# itself uses the floating 26.04 tag, so the box always builds from the
# latest point release. Refresh with:
#   nix run nixpkgs/nixos-26.05#nix-prefetch-docker -- --image-name ubuntu --image-tag 26.04 --quiet
{
  imageName = "ubuntu";
  imageDigest = "sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db";
  hash = "sha256-dSj1HYgjg5ic985BHe9HBGJt2zh/YeyYyqotpZwqyEI=";
  finalImageName = "ubuntu";
  finalImageTag = "26.04";
}
