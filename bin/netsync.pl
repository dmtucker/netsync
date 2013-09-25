#!/usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';

use File::Basename;
use Getopt::Std;

use Configurator;
use Netsync;

our (%options,%settings,$SCRIPT,$VERSION);


BEGIN {
    ($SCRIPT) = fileparse ($0,"\.[^.]*");
    $VERSION = '2.0.0-alpha';
    $options{'options'}   = 'c:p:m:d:au';
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
    $options{'node pattern'} = $opts{'m'};
    $options{'use_CSV'}      = $opts{'d'};
    $options{'auto_match'}   = $opts{'a'} // 0; #/#XXX
    $options{'update'}       = $opts{'u'} // 0; #/#XXX
    $options{'node_list'}    = $ARGV[0] // '-'; #/#XXX
    
    $options{'conf_file'} = $opts{'c'} // '/etc/'.$SCRIPT.'/'.$SCRIPT.'.ini'; #'#XXX
    { # Read and apply the configuration file.
        say 'configuring (using '.$options{'conf_file'}.')...' unless $options{'quiet'};
        %settings = configurate $options{'conf_file'};
        Netsync::configure({
                %{Configurator::config('Netsync')},
                'auto_match'  => $options{'auto_match'},
                'probe_level' => $options{'probe_level'},
                'quiet'       => $options{'quiet'},
                'verbose'     => $options{'verbose'},
            },
            Configurator::config('SNMP'),
            Configurator::config('DB'),
            Configurator::config('DNS'),
        );
    }
}


sub run {
    my $nodes;
    $nodes = Netsync::discover($options{'node_list'},$options{'host_pattern'});
    exit if $options{'probe_level'} == 1;
    Netsync::identify ($nodes,$data);
    exit if $options{'probe_level'} == 2;
    Netsync::update $nodes if $options{'update'};
}


run and exit;
