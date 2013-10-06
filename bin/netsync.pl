#!/usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';

use File::Basename;
use Getopt::Std;

use Configurator;
use FileManager;
use Netsync;

our ($SCRIPT,$VERSION);
#our ($SCRIPT)  = fileparse ($0,"\.[^.]*");
#our ($VERSION) = '2.0.0-alpha';
our %config;
{
    $config{'Indent'}  = 4;
    $config{'Quiet'}   = 0;
    $config{'Verbose'} = 0;
    
    $config{'Options'}   = 'c:p:Dm:d:au';
    $config{'Arguments'} = '[nodes]';
    
    $config{'ConfigFile'} = '/etc/'.$SCRIPT.'/'.$SCRIPT.'.ini';
    $config{'NodeFile'}   = 'STDIN';
    $config{'DataFile'}   = 'DB';
    
    $config{'HostPattern'} = '[^.]+';
    $config{'ProbeLevel'}  = 0;
    $config{'AutoMatch'}   = 0;
    $config{'Update'}      = 0;
}

BEGIN {
    ($SCRIPT) = fileparse ($0,"\.[^.]*");
    $VERSION = '2.0.0-alpha';
    $config{'Options'}   = 'c:p:Dm:d:au';
    $config{'Arguments'} = '[nodes]';
    
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
}


sub VERSION_MESSAGE {
    say $SCRIPT.' v'.$VERSION;
    say 'Perl v'.$];
    say 'File::Basename v'.$File::Basename::VERSION;
    say 'Getopt::Std v'.$Getopt::Std::VERSION;
    say 'Configurator v'.$Configurator::VERSION;
    say 'FileManager v'.$FileManager::VERSION;
    say 'Netsync v'.$Netsync::VERSION;
}


sub HELP_MESSAGE {
    my $opts = $config{'Options'};
    $opts =~ s/://g;
    say $SCRIPT.' [-'.$opts.'] '.$config{'Arguments'};
    say '  -h --help   Help. Print usage and options.';
    say '  -V          Version. Print build information.';
    say '  -v          Verbose. Print everything.';
    say '  -q          Quiet. Print nothing.';
    say '  -c .ini     Config. Specify a configuration file.';
    say '  -p #        Probe. There are 2 Probe levels:';
    say '                1: Probe the network for active nodes.';
    say '                2: Probe the database for those nodes.';
    say "  -D          DNS. Use your network's domain name system to retrieve a list of nodes.";
    say '  -m pattern  Match. Only discover nodes with hostnames matching the given pattern.';
    say '  -d .csv     Database. Specify an RFC4180-compliant database file.';
    say '  -a          Automatch. Enable interface auto-matching.';
    say '  -u          Update. Send interface-specific information to network nodes.';
    say '  [nodes]     Nodes. Nodes. Specify an RFC1035-compliant list of network nodes.';
}


INIT {
    my %opts;
    $config{'Options'} = 'hVvq'.$config{'Options'};
    HELP_MESSAGE    and exit 1 unless getopts ($config{'Options'},\%opts);
    HELP_MESSAGE    and exit if $opts{'h'};
    VERSION_MESSAGE and exit if $opts{'V'};
    $config{'Quiet'}   = $opts{'q'} // $config{'Quiet'}; #/#XXX
    $config{'Verbose'} = $opts{'v'} // $config{'Verbose'}; #/#XXX
    $config{'Verbose'} = $config{'Quiet'} = 0 if $config{'Verbose'} and $config{'Quiet'};
    
    $config{'ConfigFile'} = $opts{'c'} // $config{'ConfigFile'}; #/#XXX
    {
        say 'configuring (using '.$config{'ConfigFile'}.')...' unless $config{'Quiet'};
        %config = configurate ($config{'ConfigFile'},{
            $SCRIPT.'.Probe1Cache' => '/var/cache/'.$SCRIPT.'/dns.txt',
            $SCRIPT.'.Probe2Cache' => '/var/cache/'.$SCRIPT.'/db.csv',
        });
        Netsync::configure({
                %{Configurator::config('Netsync')},
                'Quiet'      => $config{'Quiet'},
                'Verbose'    => $config{'Verbose'},
            },
            Configurator::config('SNMP'),
            Configurator::config('DB'),
            Configurator::config('DNS'),
        );
    }
    
    $config{'NodeFile'}    = (defined $opts{'D'}) ? 'DNS' : $ARGV[0] // $config{'NodeFile'}; #/#XXX
    $config{'HostPattern'} = $opts{'m'} // $config{'HostPattern'}; #/#XXX
    $config{'DataFile'}    = $opts{'d'} // $config{'DataFile'}; #/#XXX
    $config{'AutoMatch'}   = $opts{'a'} // $config{'AutoMatch'}; #/#XXX
    $config{'Update'}       = $opts{'u'} // $config{'Update'}; #/#XXX
    
    $config{'ProbeLevel'} = $opts{'p'} // 0; #/#XXX
    unless ($config{'ProbeLevel'} =~ /^[0-2]$/) {
        say 'There are only 2 probe levels:';
        say '    1 : Probe the network for active nodes.';
        say '    2 : Probe the database for those nodes.';
        say 'Each level is accumulative (i.e. includes all previous levels).';
        exit 1;
    }
}


{
    my $nodes = Netsync::discover($config{'NodeFile'},$config{'HostPattern'});
    if ($config{'ProbeLevel'} == 1) {
        note ($config{'Probe1Cache'},$nodes->{$_}{'RFC1035'},0,'>') foreach sort keys %$nodes;
        exit;
    }
    Netsync::identify($nodes,$options{'DataFile'},$config{'AutoMatch'});
    if ($config{'ProbeLevel'} == 2) {
        my $Netsync = Configurator::config('Netsync');
        my $fields = $Netsync->{'DeviceField'}.','.$Netsync->{'InterfaceField'};
        $fields .= ','.join (',',sort @{$Netsync->{'InfoFields'}});
        note ($config{'Probe2Cache'},$fields,0,'>');
        foreach my $ip (sort keys %$nodes) {
            my $node = $nodes->{$ip};
            foreach my $serial (sort keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    
                    my $note = $serial.','.$ifName;
                    foreach my $field (sort @{$Netsync->{'InfoFields'}}) {
                        $note .= ','.($interface->{'info'}{$field} // ''); #/#XXX
                    }
                    note ($config{'Probe2Cache'},$note,0);
                }
            }
        }
        exit;
    }
    Netsync::update $nodes if $config{'Update'};
    exit;
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
