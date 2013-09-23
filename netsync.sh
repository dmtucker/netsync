#!/bin/bash

PROJECT=netsync
INSTALL=/usr

#set -o xtrace
case $1 in
    "install" )
        if [ "$(whoami)" != "root" ]
          then
            echo "Root privleges are necessary to proceed."
            echo "Grant them by repeating the command prefixed with 'sudo '."
            exit 1
        fi
        
        echo -n "creating environment... "
        mkdir -p /etc/$PROJECT
        mkdir -p $INSTALL/lib/$PROJECT
        mkdir -p $INSTALL/share/$PROJECT
        mkdir -p $INSTALL/src/$PROJECT
        mkdir -p /var/cache/$PROJECT
        mkdir -p /var/log/$PROJECT
        echo "done"
        
        echo -n "building executables... "
        cp -R src/$PROJECT.pl $INSTALL/bin/$PROJECT
        chmod +x $INSTALL/bin/$PROJECT
        echo "done"
        
        echo -n "configuring defaults... "
        cp -R etc/* /etc/$PROJECT
        echo "done"
        
        echo -n "relocating libraries... "
        cp -R lib/* $INSTALL/lib/$PROJECT
        echo "done"
        
        echo -n "copying source codes... "
        cp -R src/$PROJECT.pl $INSTALL/src/$PROJECT
        echo "done"
        
        echo -n "adding documentation... "
        cp -R doc/* $INSTALL/share/$PROJECT
        pod2man README.pod > $INSTALL/share/man/man1/$PROJECT.1
        gzip $INSTALL/share/man/man1/$PROJECT.1
        echo "done"
        
        ;;
    "remove" )
        if [ "$(whoami)" != "root" ]
          then
            echo "Root privleges are necessary to proceed."
            echo "Grant them by repeating the command prefixed with 'sudo '."
            exit 1
        fi
        
        echo -n "remvoing documentation... "
        rm -fR $INSTALL/share/$PROJECT
        rm -fR $INSTALL/share/man/man1/$PROJECT.1
        echo "done"
        
        echo -n "deleting source codes... "
        rm -fR $INSTALL/src/$PROJECT
        echo "done"
        
        echo -n "removing libraries... "
        rm -fR $INSTALL/lib/$PROJECT
        echo "done"
        
        responded=0
        while [ $responded -eq 0 ]
          do
            echo -n "erase configuration? [y/n] "
            read -n 1 choice
            echo
            case $choice in
                [nN] ) responded=1  ;;
                [yY] ) responded=1
                    echo -n "erasing configuration... "
                    rm -fR /etc/$PROJECT
                    echo "done"
                    ;;
            esac
        done
        
        echo -n "demolishing executables... "
        rm -fR $INSTALL/bin/$PROJECT
        echo "done"
        
        echo -n "destroying environment... "
        rm -fR /var/cache/$PROJECT
        rm -fR /var/log/$PROJECT
        echo "done"
        
        ;;
    * )
        perl -I ./lib ./bin/$PROJECT.pl $@
        ;;
esac
