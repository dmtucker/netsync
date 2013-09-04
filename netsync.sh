#!/bin/bash

PROJECT=netsync

#set -o xtrace
clear
find var/log -maxdepth 1 -type f -mmin +360 -delete
cp src/$PROJECT.pl bin/$PROJECT
chmod +x bin/$PROJECT
perl -Isrc/lib bin/$PROJECT $@
