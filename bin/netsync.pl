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

our (%options,%settings,$SCRIPT,$VERSION);


BEGIN {
    ($SCRIPT) = fileparse ($0,"\.[^.]*");
    $VERSION = '2.0.0-alpha';
    $options{'options'}   = 'c:p:Dm:d:au';
    $options{'arguments'} = '[nodes]';
    
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
}


sub VERSION_MESSAGE {
    say $SCRIPT.' v'.$VERSION;
    say 'Perl v'.$];
    say 'File::Basename v'.$File::Basename::VERSION;
    say 'Getopt::Std v'.$Getopt::Std::VERSION;
    
    say 'Configurator v'.$Configurator::VERSION;
    say 'Netsync v'.$Netsync::VERSION;
}


sub HELP_MESSAGE {
    my $opts = $options{'options'};
    $opts =~ s/[:]+//g;
    say $SCRIPT.' [-'.$opts.'] '.$options{'arguments'};
    say '  -h --help   Help. Print usage and options.';
    say '  -V          Version. Print build information.';
    say '  -v          Verbose. Print everything.';
    say '  -q          Quiet. Print nothing.';
    say '  -c .ini     Specify a configuration file to use.';
    say '  -p #        Probe. There are 2 probe levels:';
    say '                  1: Probe the network for active nodes.';
    say '                  2: Probe the database for those nodes.';
    say '  -D          Use DNS to retrieve a node list.';
    say '  -m pattern  Only discover hosts matching the given pattern.';
    say '  -d .csv     Specify an RFC4180-compliant database file to use.';
    say '  -a          Enable interface auto-matching.';
    say '  -u          Update network nodes with interface-specific information.';
    say '  [nodes]     Specify an RFC1035-compliant network node list to use.';
}


INIT {
    my %opts;
    $options{'options'} = 'hVvq'.$options{'options'};
    HELP_MESSAGE    and exit 1 unless getopts ($options{'options'},\%opts);
    HELP_MESSAGE    and exit if $opts{'h'};
    VERSION_MESSAGE and exit if $opts{'V'};
    $options{'quiet'}   = $opts{'q'} // 0; #/#XXX
    $options{'verbose'} = $opts{'v'} // 0; #/#XXX
    $options{'verbose'} = --$options{'quiet'} if $options{'verbose'} and $options{'quiet'};
    
    $options{'probe_level'} = $opts{'p'} // 0; #/#XXX
    unless ($options{'probe_level'} =~ /^[0-2]$/) {
        say 'There are only 2 probe levels:';
        say '    1: Probe the network for active nodes.';
        say '    2: Probe the database for those nodes.';
        say 'Each level includes all previous levels.';
        exit 1;
    }
    $options{'node_file'}    = (defined $opts{'D'}) ? 'DNS' : $ARGV[0] // 'STDIN'; #/#XXX
    $options{'host_pattern'} = $opts{'m'};
    $options{'data_file'}    = $opts{'d'} // 'DB'; #/#XXX
    $options{'auto_match'}   = $opts{'a'} // 0; #/#XXX
    $options{'update'}       = $opts{'u'} // 0; #/#XXX
    
    $options{'conf_file'} = $opts{'c'} // '/etc/'.$SCRIPT.'/'.$SCRIPT.'.ini'; #'#XXX
    { # Read and apply the configuration file.
        say 'configuring (using '.$options{'conf_file'}.')...' unless $options{'quiet'};
        %settings = configurate ($options{'conf_file'},{
            $SCRIPT.'.Probe1Cache' => '/var/cache/'.$SCRIPT.'/dns.txt',
            $SCRIPT.'.Probe2Cache' => '/var/cache/'.$SCRIPT.'/db.csv',
        });
        Netsync::configure({
                %{Configurator::config('Netsync')},
                'AutoMatch'  => $options{'auto_match'}, #XXX
                'Quiet'      => $options{'quiet'},
                'Verbose'    => $options{'verbose'},
            },
            Configurator::config('SNMP'),
            Configurator::config('DB'),
            Configurator::config('DNS'),
        );
    }
}


{
    my $nodes = Netsync::discover($options{'node_file'},$options{'host_pattern'});
    if ($options{'probe_level'} == 1) {
        note ($settings{'Probe1Cache'},$nodes->{$_}{'RFC1035'},0,'>') foreach sort keys %$nodes;
        exit;
    }
    Netsync::identify($nodes,$options{'data_file'});
    if ($options{'probe_level'} == 2) {
        my $Netsync = Configurator::config('Netsync');
        my $fields = $Netsync->{'DeviceField'}.','.$Netsync->{'InterfaceField'};
        $fields .= ','.join (',',sort @{$Netsync->{'InfoFields'}});
        note ($settings{'Probe2Cache'},$fields,0,'>');
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
                    note ($settings{'Probe2Cache'},$note,0);
                }
            }
        }
        exit;
    }
    Netsync::update $nodes if $options{'update'};
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
