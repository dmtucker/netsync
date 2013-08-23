#! /bin/bash

RUN="perl -Isrc/lib/ bin/netsync"

#set -o xtrace
clear
find var/log -maxdepth 1 -type f -mmin +360 -delete
cp src/netsync.pl bin/netsync
chmod +x bin/netsync
$RUN --help
echo
$RUN $@
