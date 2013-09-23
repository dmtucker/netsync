#!/usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';

use File::Basename;
use Getopt::Std;

use Netsync;
use Netsync::Configurator;


our (%options,%settings,$VERSION);


BEGIN {
    $VERSION = '1.2.0';
    $options{'options'}   = 'c:p:D:d:a';
    $options{'arguments'} = '[nodes]';
    
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
    
    SNMP::addMibDirs($settings{'MIBdir'});
    SNMP::loadModules('IF-MIB','ENTITY-MIB');                                # standard
    SNMP::loadModules('CISCO-STACK-MIB');                                    # Cisco
    SNMP::loadModules('FOUNDRY-SN-AGENT-MIB','FOUNDRY-SN-SWITCH-GROUP-MIB'); # Brocade
    SNMP::loadModules('SEMI-MIB'); #XXX,'HP-SN-AGENT-MIB');                  # HP
    SNMP::initMib();
}


sub VERSION_MESSAGE {
    say ((basename $0).' v'.$VERSION);
    say 'Perl v'.$];
    say 'DBI v'.$DBI::VERSION;
    say 'File::Basename v'.$File::Basename::VERSION;
    say 'Getopt::Std v'.$Getopt::Std::VERSION;
    say 'POSIX v'.$POSIX::VERSION;
    say 'Regexp::Common v'.$Regexp::Common::VERSION;
    say 'Text::CSV v'.$Text::CSV::VERSION;
}


sub HELP_MESSAGE {
    my $opts = $options{'options'};
    $opts =~ s/[:]+//g;
    say ((basename $0).' [-'.$opts.'] '.$options{'arguments'});
    say '  -h --help   Help. Print usage and options.';
    say '  -V          Version. Print build information.';
    say '  -v          Verbose. Print everything.';
    say '  -q          Quiet. Print nothing.';
    say '  -c .ini     Specify a configuration file to use.';
    say '  -p #        Probe. There are 2 probe levels:';
    say '                  1: Probe the network for active nodes.';
    say '                  2: Probe the database for those nodes.';
    say '  -D pattern  Use DNS to retrieve a list of hosts matching the pattern.';
    say '  -d .csv     Specify an RFC4180-compliant database file to use.';
    say '  -a          Enable interface auto-matching.';
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
    $options{'conf_file'} = $opts{'c'} // 'etc/'.(basename $0).'.ini'; #'#XXX
    $options{'probe_level'} = $opts{'p'} // 0; #/#XXX
    unless ($options{'probe_level'} =~ /^[0-2]$/) {
        say 'There are only 2 probe levels:';
        say '    1: Probe the network for active nodes.';
        say '    2: Probe the database for those nodes.';
        say 'Each level includes all previous levels.';
        exit 1;
    }
    $options{'use_DNS'} = $opts{'D'};
    $options{'use_CSV'} = $opts{'d'};
    $options{'auto_match'} = $opts{'a'} // 0; #/#XXX
    $options{'node_list'}  = $ARGV[0] // '-'; #/#XXX
}


sub run {
    my $nodes = discover;
    exit if $options{'probe_level'} == 1;
    identify $nodes;
    exit if $options{'probe_level'} == 2;
    update $nodes;
}


{ # Read the configuration file.
    say 'configuring (using '.$options{'conf_file'}.')...' unless $options{'quiet'};
    %settings = configure ($options{'conf_file'},{
        'Indent'            => 4,
        'NodeOrder'         => 4, # network < 10000 nodes
        'MIBdir'            => '/usr/lib/'.(basename $0).'/mib'
        'NodeLog'           => '/var/log/'.(basename $0).'/nodes.log',
        'DeviceLog'         => '/var/log/'.(basename $0).'/devices.log',
        'UnrecognizedLog'   => '/var/log/'.(basename $0).'/unrecognized.log',
        'UpdateLog'         => '/var/log/'.(basename $0).'/updates.log',
        'Probe1Cache'       => '/var/cache/'.(basename $0).'/dns.txt',
        'Probe2Cache'       => '/var/cache/'.(basename $0).'/db.csv',
        'UnidentifiedCache' => '/var/cache/'.(basename $0).'/unidentified.csv',
    },1,1,1);
}
run and exit;
