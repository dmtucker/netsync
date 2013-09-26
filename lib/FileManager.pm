#!/usr/bin/perl

package Netsync::FileManager;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('timestamp','note');

use feature 'say';

use POSIX;


=head1 NAME

Netsync::FileManager - methods for handling I/O automatically and efficiently

=head1 SYNOPSIS

 use Netsync::FileManager;
 
 say timestamp;
 note('foo.txt','Don't stamp this note.',0);

=cut


our $VERSION = '1.0.0';
our %files;


=head1 DESCRIPTION

This package is an I/O framework.

=head1 METHODS

=head2 timestamp [$format]

returns an POSIX-compliant string representing the current time

=head3 Arguments

=head4 format

the POSIX time-string format to use (default: '%Y-%m-%d-%H:%M:%S')

=head3 Example

=over 4

=item C<say timestamp;>

 > 2013-09-22-19:53:46

=item C<say timestamp '%Y/%m/%d @ %h:%M';>

 > 2013/09/22 @ 7:53

=back

=cut

sub timestamp {
    warn 'too many arguments' if @_ > 1;
    my ($format) = @_;
    $format //= '%Y-%m-%d-%H:%M:%S'; #/#XXX
    
    my $timestamp = POSIX::strftime($format,localtime);
    return $timestamp;
}


=head2 note ($file,$note[,$stamp[,$mode]])

writes to a specified file and (optionally) timestamps the addition or overwrite

=head3 Arguments

=head4 file

the path to the file to write to

=head4 note

the string to write

=head4 [stamp]

whether to timestamp the note (default: 1)

=head4 [mode]

the method to use when opening the file (if it hasn't been opened already, default: '>>')

=head3 Example

=over 4

=item C<say 'success' if note ('note.tmp','hi!');>

 > success

F<note.tmp>

 2013-09-22-19:53:47 hi!

=item C<say 'success' if note ('note.tmp','hi!',0);>

 > success

F<note.tmp>

 2013-09-22-19:53:47 hi!
 hi!

=item C<say 'success' if note ('note.tmp','fresh',1,'E<gt>');>

 > success

F<note.tmp>

 2013-09-22-19:53:47 fresh

=back

=cut

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
