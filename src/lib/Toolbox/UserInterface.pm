#!/usr/bin/perl

package Toolbox::UserInterface;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('ask','choose');

use autodie;
use strict;

use feature 'say';

use POSIX;


sub ask {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($question) = @_;
    
    open (STDIN,'<',POSIX::ctermid); #XXX
    while (1) {
        print $question.' [y/n] ';
        chomp (my $response = <STDIN>);
        return 1 if $response =~ /^([yY]+([eE]+[sS]+)?)$/;
        return 0 if $response =~ /^([nN]+([oO]+)?)$/;
        say 'A decision could not be determined from your response. Try again.';
    }
}


sub choose {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($message,$choices) = @_;
    
    open (STDIN,'<',POSIX::ctermid); #XXX
    while (1) {
        say $message;
        say 'Choose one of the following:';
        say '  '.$_.': '.$choices->[$_] foreach keys @$choices;
        print "What is your choice? [0] ";
        chomp (my $response = <STDIN>);
        return $choices->[0] if $response =~ /^$/;
        return $choices->[$response] if $response =~ /^[0-9]+$/ and $response < @$choices;
        say 'A decision could not be determined from your response. Try again.';
    }
}


1
