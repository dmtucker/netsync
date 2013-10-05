#!/usr/bin/perl

package Netsync::UI;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('ask','choose');

use autodie;
use strict;

use feature 'say';

use POSIX;


=head1 NAME

Netsync::UI - methods for interacting with a user

=head1 SYNOPSIS

 use Netsync::UI;
 
 if (ask 'Do you want to?') {
     print "Yes\n";
 }
 else {
     print choose ("What would you rather?",['a','b','c'])."\n";
 }

=cut


our $VERSION = '1.0.0';


=head1 DESCRIPTION

This module is responsible for providing an interface between netsync and users.

=head1 METHODS

=head2 ask $question

asks the user a yes or no question and returns an affirmative boolean

=head3 Arguments

=head4 question

a yes or no question to ask

=head3 Example

=over 3

=item C<say 'You like it.' if ask 'Do you like green eggs and ham?';>

 > Do you like green eggs and ham? [y/n] n

Z<>

 > Do you like green eggs and ham? [y/n] y
 > You like it.

=back

=cut

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


=head2 choose ($message,\@choices)

asks the user to choose from a list of provided options using numeric input

=head3 Arguments

=head4 message

a custom message to the user to help them understand what is going on

=head4 choices

a list of acceptable choices

=head3 Example

=over 4

=item C<say 'choice: '.choose ('Do you like green eggs and ham?',['yes','no','maybe']);>

 > Do you like green eggs and ham?
 > Choose one of the following:
 >   0: yes
 >   1: no
 >   2: maybe
 > What is your choice? [0] 1
 > choice: no

Note: Only appropriate input is accepted.

 > Do you like green eggs and ham?
 > Choose one of the following:
 >   0: yes
 >   1: no
 >   2: maybe
 > What is your choice? [0] a
 > A decision could not be determined from your response. Try again.
 > What is your choice? [0] 2
 > choice: maybe

=back

=cut

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


=head1 AUTHOR

David Tucker

=head1 LICENSE

This file is part of netsync.
netsync is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
netsync is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with netsync.
If not, see L<http://www.gnu.org/licenses/>.

=cut


1
