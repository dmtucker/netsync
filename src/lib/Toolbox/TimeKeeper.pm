#!/usr/bin/perl

package Toolbox::TimeKeeper;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('timestamp');

use POSIX;


sub timestamp {
    warn 'too many arguments' if @_ > 0;
    
    chomp (my $timestamp = POSIX::strftime("%Y-%m-%d-%H:%M:%S\n",localtime));
    return $timestamp;
}


1;
