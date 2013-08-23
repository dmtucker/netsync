#!/usr/bin/perl

package Toolbox::FileManager;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('note');

use feature 'say';

use Toolbox::TimeKeeper;


our %files;


sub note {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 4;
    my ($file,$note,$stamp,$mode) = @_;
    $stamp //= 1; #/#XXX
    $mode  //= '>>'; #/#XXX
    
    open  ($files{$file},$mode,$file) unless defined $files{$file};
    print {$files{$file}} timestamp.' ' if $stamp;
    say   {$files{$file}} $note;
    return 1;
}


END {
    foreach my $file (keys %files) {
        close $files{$file} if defined $files{$file};
    }
}


1;
