package Helpers::Scribe; #XXX Log::Message?

=head1 NAME

Helpers::Scribe - I/O framework

=head1 DESCRIPTION

This package handles I/O automatically.

=head1 SYNOPSIS

 use Helpers::Scribe;
 
 print timestamp;
 note('foo.txt','Don't stamp this note.',0);

=cut


use 5.006;
use strict;
use warnings FATAL => 'all';
use autodie; #XXX Is autodie adequate?
use feature 'say';

use File::Basename;
use POSIX;

our ($SCRIPT,$VERSION);
our %files;

BEGIN {
    ($SCRIPT)  = fileparse ($0,"\.[^.]*");
    ($VERSION) = (1.00);
    
    require Exporter;
    our @ISA = ('Exporter');
    our @EXPORT_OK = ('note','timestamp');
}


=head1 METHODS

=head2 timestamp [$format]

returns an string representing the current time

B<Arguments>

=over 3

=item format

the POSIX time-string format to use

default: '%Y-%m-%d-%H:%M:%S'

=back

=cut

sub timestamp {
    warn 'too many arguments' if @_ > 1;
    my ($format) = @_;
    $format //= '%Y:%m:%d:%H:%M:%S';
    
    my $timestamp = POSIX::strftime($format,localtime);
    return $timestamp;
}


=head2 note ($file,$note[,$stamp[,$mode]])

writes to a specified file and optionally including a timestamp

B<Arguments>

=over 3

=item file

the file to write to

=item note

the string to write

=item stamp

whether to timestamp the note

default: 1

=item mode

the method to use when opening the file (if it hasn't been opened already)

default: '>>'

=back

=cut

sub note {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 4;
    my ($file,$note,$stamp,$mode) = @_;
    $stamp //= 1;
    $mode  //= '>>';
    
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

David Tucker, C<< <dmtucker at ucsc.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-netsync at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Netsync>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

 perldoc Netsync

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Netsync>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Netsync>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Netsync>

=item * Search CPAN

L<http://search.cpan.org/dist/Netsync/>

=back

=head1 LICENSE

Copyright 2013 David Tucker.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut


1;
