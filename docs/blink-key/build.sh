#!/bin/sh

IMGSIZE=50x50

mkdir -p generated

convert -size 2x2 gradient:#aa7700-#aaaa00 -resize ${IMGSIZE} generated/0-install-start.png
convert -size 2x2 gradient:#006666-#aaaa00 -resize ${IMGSIZE} generated/1-install-finished.png
convert -size 2x2 gradient:#aa7700-#0000aa -resize ${IMGSIZE} generated/2-ip-allocator-start.png
convert -size 2x2 gradient:#006666-#0000aa -resize ${IMGSIZE} generated/3-kubelet-started.png

pandoc key.md -f markdown -t latex -o generated/key.pdf
