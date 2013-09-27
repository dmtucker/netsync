#!/usr/bin/perl

package Configurator;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('configurate');

use autodie;
use strict;

use feature 'say';

use Config::Simple;
use File::Basename;


=head1 NAME

Configurator - methods for handling configuration files and default settings

=head1 SYNOPSIS

=over 2

=item F<foobar.ini>

 [testGroup]
 fooSetting = barValue
 barSetting = bazValue
 bazSetting = foo,bar,baz

=item F<foobar.pl>

 #!/usr/bin/perl
 
 use feature 'say';
 
 use Configurator;
 
 configurate 'foobar.ini';
 say Configurator::config('testGroup','fooSetting');
 say (Configurator::config('testGroup','bazSetting'))[2];
 say {Configurator::config('testGroup')}->{'barSetting'};

=back

 $ perl foobar.pl
 > barValue
 > baz
 > bazValue

=cut


our $VERSION = '1.0.0-alpha';
our %config;


=head1 DESCRIPTION

This package makes parsing a configuration file and managing defaults easy.

=head1 METHODS

=head2 configurate [($file[,\%defaults])]

reads a configuration file and (optionally) additional defaults into the Configurator namespace

=head3 Arguments

=head4 [file]

a configuration file (.ini) to use
(default: F</etc/E<lt>script nameE<gt>/E<lt>script nameE<gt>.ini>)

=head4 [defaults]

key-value pairs or environmental variable default values

=head3 Example

=over 4

=item C<configurate;>

This causes Configurator to attempt reading the configuration file at F</etc/E<lt>script nameE<gt>/E<lt>script nameE<gt>.ini>.
It will return any configurations in the file found under the E<lt>script nameE<gt> group.

=item C<my $settings = configurate ('foobar.ini',{ 'foobar.fruit' =E<gt> 'banana' , 'testGroup.fooSetting' =E<gt> 'NOTbarValue' });>

=over 5

=item C<say $settings{'fruit'};>

 > /var/log/example/example.log

=item C<say $settings{'fooSetting'} // 'undefined';>

 > undefined

=back

=back

=cut

sub configurate {
    warn 'too many arguments' if @_ > 2;
    my $SCRIPT_NAME = fileparse ($0,"\.[^.]*");
    my ($file,$defaults) = @_;
    $file     //= '/etc/'.$SCRIPT_NAME.'/'.$SCRIPT_NAME.'.ini'; #'#XXX
    $defaults //= {}; #/#XXX
    
    $config{$_} = $defaults->{$_} foreach keys %$defaults;
    
    open (my $ini,'<',$file);
    my $parser = Config::Simple->new($file);
    my $syntax = $parser->guess_syntax($ini);
    unless (defined $syntax and $syntax eq 'ini') {
        say 'The configuration file "'.$file.'" is malformed.';
        return undef;
    }
    close $ini;
    
    {
        my %imports;
        Config::Simple->import_from($file,\%imports);
        foreach (keys %imports) {
            $config{$_} = $imports{$_} unless ref $imports{$_} and not defined $imports{$_}[0];
        }
    }
    
    my %settings;
    foreach (keys %config) {
        $settings{$+{'setting'}} = $config{$_} if /^$SCRIPT_NAME\.(?<setting>.*)$/;
    }
    return %settings;
}


=head2 config ($group[,$query])

returns an individual or group of configurations read

Note: configurate needs to be run first!

=head3 Arguments

=head4 C<group>

the group of the configuration(s) to retrieve

=head4 C<[query]>

the name of the configuration to retrieve

=head3 Example

=over 4

=item C<say Configurator::config('testGroup','fooSetting');>

 > barValue

=item C<say {Configurator::config('testGroup')}-E<gt>{'barSetting'};>

 > bazValue

=back

=cut

sub config {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 2;
    my ($group,$query) = @_;
    
    return $config{$group.'.'.$query} if defined $query;
    
    my $responses;
    foreach (keys %config) {
        if (/^(?<grp>[^.]*)\.(?<qry>.*)$/) {
            $responses->{$+{'qry'}} = $config{$_} if $+{'grp'} eq $group;
        }
    }
    return $responses;
}


=head2 dump

prints the current configuration (use sparingly)

Note: configurate needs to be run first!

=head3 Example

C<Configurator::dump;>

 > testGroup.fooSetting = barValue;
 > testGroup.barSetting = bazValue;
 > testGroup.masSetting = foo bar baz;

=cut

sub dump {
    warn 'too many arguments' if @_ > 0;
    
    say $_.' = '.($config{$_} // 'undef') foreach sort keys %config; #/#XXX
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
