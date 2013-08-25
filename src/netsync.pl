#! /usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';
use feature 'switch';

use Data::Dumper; #XXX
use DBI;
use File::Basename;
use Getopt::Std;
use Net::DNS;
use POSIX;
use Regexp::Common;
use Scalar::Util 'blessed';
use SNMP;
use SNMP::Info;
use Text::CSV;

use Toolbox::Configurator;
use Toolbox::FileManager;


our (%options,%settings,$VERSION);


BEGIN {
    $VERSION = '0.0';
    $options{'options'}   = 'c:p:Dd:';
    $options{'arguments'} = '[nodes]';
    
    $Data::Dumper::Sortkeys = 1; #XXX
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
    
    #SNMP::initMib(); #XXX
    SNMP::loadModules('ENTITY-MIB');            # standard
    SNMP::loadModules('FOUNDRY-SN-SWITCH-GROUP-MIB'); # Brocade #XXX : needed?, why?
    #SNMP::loadModules('FOUNDRY-SN-AGENT-MIB');  # Brocade
    SNMP::loadModules('CISCO-STACK-MIB');       # Cisco
    SNMP::loadModules('SEMI-MIB');             # HP #XXX : needed?, why?
    #SNMP::loadModules('HP-httpManageable-MIB'); # HP #XXX
    #SNMP::loadModules('HP-SN-AGENT-MIB');       # HP #XXX : needed?
}


sub VERSION_MESSAGE {
    say ((basename $0).' v'.$VERSION);
    say 'Perl v'.$];
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    say 'DBI v'.$DBI::VERSION;
    say 'File::Basename v'.$File::Basename::VERSION;
    say 'Getopt::Std v'.$Getopt::Std::VERSION;
    say 'Net::DNS v'.$Net::DNS::VERSION;
    say 'POSIX v'.$POSIX::VERSION;
    say 'Regexp::Common v'.$Regexp::Common::VERSION;
    say 'Scalar::Util v'.$Scalar::Util::VERSION;
    say 'SNMP v'.$SNMP::VERSION;
    say 'SNMP::Info v'.$SNMP::Info::VERSION;
    say 'Text::CSV v'.$Text::CSV::VERSION;
}


sub HELP_MESSAGE {
    my $opts = $options{'options'};
    $opts =~ s/[:]+//g;
    say ((basename $0).' [-'.$opts.'] '.$options{'arguments'});
    say '  -h       Help. Print usage and options.';
    say '  -q       Quiet. Print nothing.';
    say '  -v       Verbose. Print everything.';
    say '  -V       Version. Print build information.';
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    say '  -c .ini  Specify a configuration file to use.';
    say '  -p #     Probe. There are 2 probe levels:';
    say '               1: Probe the network for active nodes.';
    say '               2: Probe the database for those nodes.';
    say '  -D       Use DNS to retrieve a node listing.';
    say '  -d .csv  Specify an RFC4180-compliant database file to use.';
    say '  nodes    Specify an RFC1035-compliant network node list to use.';
}


INIT {
    my %opts;
    $options{'options'} .= 'hqvV';
    HELP_MESSAGE    and exit 1 unless getopts ($options{'options'},\%opts);
    HELP_MESSAGE    and exit if $opts{'h'};
    VERSION_MESSAGE and exit if $opts{'V'};
    $options{'quiet'}   = $opts{'q'} // 0; #/#XXX
    $options{'verbose'} = $opts{'v'} // 0; #/#XXX
    $options{'verbose'} = --$options{'quiet'} if $options{'verbose'} and $options{'quiet'};
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    $options{'conf_file'} = $opts{'c'} // 'etc/'.(basename $0).'.ini'; #'#XXX
    $options{'probe_level'} = $opts{'p'} // 0; #/#XXX
    unless ($options{'probe_level'} =~ /^[0-2]$/) {
        say 'There are only 2 probe levels:';
        say '    1: Probe the network for active nodes.';
        say '    2: Probe the database for those nodes.';
        say 'Each level includes all previous levels.';
        exit 1;
    }
    $options{'use_DNS'} = $opts{'D'} // 0; #/#XXX
    $options{'use_CSV'} = (exists $opts{'d'} and $opts{'d'} =~ /[\S]+/) ? $opts{'d'} : undef;
    $options{'node_list'} = $ARGV[0] // '-'; #/#XXX
}




sub validate {
    warn 'too many arguments' if @_ > 0;
    
    my $required = [
        'Table',
        'DeviceField',
        'InterfaceField',
        'InfoFields',
    ];
    foreach (@$required) {
        die 'missing information ('.$_.')' unless defined $settings{$_};
    }
}




################################################################################




sub SNMP_get1 {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 3;
    my ($oids,$session) = @_;
    
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        ($session) = SNMP_Info $session;
        return undef unless defined $session;
    }
    
    my (@objects,@IIDs);
    foreach my $oid (@$oids) {
        my $query = SNMP::Varbind->new([$oid->[0]]);
        while (my $object = $session->getnext($query)) {
            last unless $query->tag eq $oid->[1] and not $session->{'ErrorNum'};
            last if $object =~ /^ENDOFMIBVIEW$/;
            $object =~ s/^\s*(.*?)\s*$/$1/;
            push (@IIDs,$query->iid);
            push (@objects,$object);
        }
        last if @objects != 0;
    }
    return undef if @objects == 0;
    return (\@objects,\@IIDs);
}




sub device_interfaces {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($vendor,$session) = @_;
    
    my %serial2ifDescr;
    {
        my %if2ifDescr;
        {
            my ($types) = SNMP_get1 ([['.1.3.6.1.2.1.2.2.1.3'  => 'ifType']],$session); # IF-MIB
            my ($ifDescrs,$ifs) = SNMP_get1 ([
                ['.1.3.6.1.2.1.31.1.1.1.1' => 'ifName'],  # IF-MIB
                ['.1.3.6.1.2.1.2.2.1.2'    => 'ifDescr'], # IF-MIB
            ],$session); # IF-MIB
            foreach my $i (keys @$ifs) {
                $if2ifDescr{$ifs->[$i]} = $ifDescrs->[$i] if $types->[$i] =~ /^(?!1|24|53)$/;
                note (get_config 'general.Log','foreign type encountered ('.$types->[$i].') on interface '.$ifDescrs->[$i]) if $types->[$i] =~ /^(?!1|6|24|53)$/; #XXX
            }
            @if2ifDescr{@$ifs} = @$ifDescrs;
        }
        
        my @serials;
        {
            my ($classes) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.5'  => 'entPhysicalClass']],$session);     # ENTITY-MIB
            my ($serials) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.11' => 'entPhysicalSerialNum']],$session); # ENTITY-MIB
            if (defined $serials) {
                foreach my $i (keys @$classes) {
                    push (@serials,$serials->[$i]) if $classes->[$i] =~ /3/; #XXX and defined $serials->[$i];
                }
            }
        }
        unless (@serials > 0) {
            given ($vendor) {
                when ('cisco') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.3'  => 'moduleSerialNumber'],       # CISCO-STACK-MIB
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.26' => 'moduleSerialNumberString'], # CISCO-STACK-MIB
                    ],$session);
                    @serials = @$serials;
                }
                when ('foundry') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2' => 'snChasUnitSerNum'], # FOUNDRY-SN-AGENT-MIB?
                        ['.1.3.6.1.4.1.1991.1.1.1.1.2'     => 'snChasSerNum'],     # FOUNDRY-SN-AGENT-MIB? - stackless
                    ],$session);
                    @serials = @$serials;
                }
                when ('hp') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.11.2.36.1.1.5.1.1.10' => 'hpHttpMgDeviceSerialNumber'], # ?
                        ['.1.3.6.1.4.1.11.2.36.1.1.2.9'      => 'hpHttpMgSerialNumber'],       # HP-httpManageable-MIB
                        #['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2'     => 'snChasUnitSerNum'],           # HP-SN-AGENT-MIB?
                        #['.1.3.6.1.4.1.11.2.3.7.11.12.1.1.1.2' => 'snChasSerNum'],               # HP-SN-AGENT-MIB - stackless?
                    ],$session);
                    @serials = @$serials;
                }
                default {
                    alert 'Serial retrieval attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            if (@serials == 0) {
                alert 'No serials could be found for a '.$vendor.' device.';
                return undef;
            }
        }
        
        if (@serials == 1) {
            push (@{$serial2ifDescr{$serials[0]}},$_) foreach values %if2ifDescr;
        }
        else {
            my %ifDescr2serial;
            given ($vendor) {
                when ('cisco') {
                    my %if2serial;
                    {
                        my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.11' => 'portIfIndex']],$session);
                        my @port2serial;
                        {
                            my ($port2module) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.1'  => 'portModuleIndex']],$session);
                            my %module2serial;
                            {
                                my ($serials,$modules) = SNMP_get1 ([
                                    ['.1.3.6.1.4.1.9.5.1.3.1.1.3'  => 'moduleSerialNumber'],       # CISCO-STACK-MIB
                                    ['.1.3.6.1.4.1.9.5.1.3.1.1.26' => 'moduleSerialNumberString'], # CISCO-STACK-MIB
                                ],$session);
                                @module2serial{@$modules} = @$serials;
                            }
                            push (@port2serial,$module2serial{$_}) foreach @$port2module;
                        }
                        @if2serial{@$port2if} = @port2serial;
                    }
                    $ifDescr2serial{$if2ifDescr{$_}} = $if2serial{$_} foreach keys %if2ifDescr;
                }
                when ('foundry') {
                    my %if2serial;
                    {
                        my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.38' => 'snSwPortIfIndex']],$session);
                        my @port2serial;
                        {
                            my ($port2umi) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.39' => 'snSwPortDescr']],$session);
                            my %module2serial;
                            {
                                my ($serials,$modules) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2' => 'snChasUnitSerNum']],$session); # FOUNDRY-SN-AGENT-MIB?
                                @module2serial{@$modules} = @$serials;
                            }
                            foreach (@$port2umi) {
                                push (@port2serial,$module2serial{$+{'unit'}}) if m{^(?<unit>[0-9]+)(/[0-9]+)+$};
                            }
                        }
                        @if2serial{@$port2if} = @port2serial;
                    }
                    $ifDescr2serial{$if2ifDescr{$_}} = $if2serial{$_} foreach keys %if2ifDescr;
                }
                default {
                    alert 'Interface mapping attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            foreach my $ifDescr (keys %ifDescr2serial) {
                
                # Remove Vlan, Null0, and loopback interfaces
                unless (defined $ifDescr2serial{$ifDescr}) {
                    delete $ifDescr2serial{$ifDescr};
                    next;
                }
                
                push (@{$serial2ifDescr{$ifDescr2serial{$ifDescr}}},$ifDescr);
            }
        }
    }
    return \%serial2ifDescr;
}




sub dump_node {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    foreach my $node (@nodes) {
        if (defined $node->{'ip'} and defined $node->{'hostname'}) {
            say $node->{'ip'}.' ('.$node->{'hostname'}.')';
        }
        else {
            alert 'A locationless node has been detected.';
        }
        
        my $device_count;
        if (defined $node->{'devices'}) {
            $device_count = scalar keys %{$node->{'devices'}};
            my ($recognized_device_count,$interface_count,$recognized_interface_count) = (0,0,0);
            foreach my $serial (keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                ++$recognized_device_count if $device->{'recognized'};
                if (defined $device->{'interfaces'}) {
                    $interface_count += scalar keys %{$device->{'interfaces'}};
                    foreach my $ifDescr (keys %{$device->{'interfaces'}}) {
                        my $interface = $device->{'interfaces'}{$ifDescr};
                        ++$recognized_interface_count if $interface->{'recognized'};
                    }
                }
                else {
                    alert 'An interfaceless device ('.$serial.') has been detected on '.$node->{'hostname'}.'.';
                }
            }
            print ((' 'x$settings{'Indent'}).$device_count.' device');
            print 's' if $device_count > 1;
            say ' ('.$recognized_device_count.' recognized)';
            print ((' 'x$settings{'Indent'}).$interface_count.' interface');
            print 's' if $interface_count > 1;
            say ' ('.$recognized_interface_count.' recognized)';
        }
        else {
            alert 'A deviceless node ('.$node->{'hostname'}.') has been detected.';
        }
        
        if (defined $node->{'info'}) { # and blessed $node->{'info'} and $node->{'info'}->isa('SNMP::Info') { #XXX
            my $info = $node->{'info'};
            if ($device_count == 1) {
                #say ((' 'x$settings{'Indent'}).$info->class); #XXX
                say ((' 'x$settings{'Indent'}).$info->vendor.' '.$info->model);
                say ((' 'x$settings{'Indent'}).$info->serial);
            }
            
            my $interface_count = scalar keys %{$info->interfaces};
            print ((' 'x$settings{'Indent'}).$interface_count.' interface');
            print 's' if scalar $interface_count > 1;
            print "\n";
        }
        else {
            alert 'An informationless node ('.$node->{'hostname'}.') has been detected.';
        }
    }
    say scalar (@nodes).' nodes' if @nodes > 1;
}




sub probe {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    my $serial_count = 0;
    foreach my $node (@nodes) {
        my $note = $node->{'ip'}.' ('.$node->{'hostname'}.')';
        
        my ($session,$info) = SNMP_Info $node->{'ip'};
        if (defined $info) {
            note ($settings{'NodeLog'},$note.' ACTIVE');
            $node->{'session'} = $session;
            $node->{'info'}    = $info;
        }
        else {
            note ($settings{'NodeLog'},$note.' inactive');
            say $node->{'ip'}.' ('.$node->{'hostname'}.') -> inactive' if $options{'verbose'};
            next;
        }
        
        my $serial2ifDescr = device_interfaces ($info->vendor,$session);
        my @serials = keys %$serial2ifDescr;
        note ($settings{'NodeLog'},$note.': no devices detected ('.$info->vendor.')') and next if @serials == 0;
        note ($settings{'StackLog'},$note.': '.join (' ',@serials)) if @serials > 1;
        foreach my $serial (@serials) {
            $node->{'devices'}{$serial}{'serial'} = $serial;
            my $device = $node->{'devices'}{$serial};
            $device->{'node'}       = $node;
            $device->{'recognized'} = 0;
            foreach my $ifDescr (@{$serial2ifDescr->{$serial}}) {
                $device->{'interfaces'}{$ifDescr}{'ifDescr'} = $ifDescr;
                my $interface = $device->{'interfaces'}{$ifDescr};
                $interface->{'device'}     = $device;
                $interface->{'recognized'} = 0;
            }
        }
        
        dump_node $node if $options{'verbose'};
        $serial_count += @serials;
    }
    return $serial_count;
}




sub discover {
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    $nodes //= {}; #/#XXX
    
    unless ($options{'quiet'}) {
        print 'discovering';
        print ' (using '.(($options{'use_DNS'}) ? 'DNS' : ($options{'node_list'} eq '-') ? 'STDIN' : $options{'node_list'}).')...';
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve network nodes from file, pipe, or DNS (-D).
    my @zone;
    if ($options{'use_DNS'}) {
        my $resolver = DNS;
        $resolver->print if $options{'verbose'};
        foreach my $record ($resolver->axfr) {
            push (@zone,$record->string) if $record->name =~ /^($settings{'HostPrefix'})([^.]*)?/;
        }
    }
    else {
        if ($options{'node_list'} eq '-') {
            chomp (@zone = <>);
        }
        else {
            open (my $node_list,'<',$options{'node_list'});
            chomp (@zone = <$node_list>);
            close $node_list;
        }
    }
    
    my $inactive_node_count = 0;
    my $active_device_count = 0;
    my $stack_count         = 0;
    foreach (@zone) {
        if (/^(?<host>[^.]+).*\s(?:$settings{'RecordType'})\s+(?<ip>$RE{'net'}{'IPv4'}|$RE{'net'}{'IPv6'})/) {
            $nodes->{$+{'ip'}}{'ip'} = $+{'ip'};
            my $node = $nodes->{$+{'ip'}};
            $node->{'hostname'} = $+{'host'};
            
            my $serial_count = probe $node;
            if ($serial_count < 1) {
                ++$inactive_node_count;
                delete $nodes->{$+{'ip'}};
            }
            else {
                $active_device_count += $serial_count;
                
                ++$stack_count if $serial_count > 1;
                note ($settings{'Probe1Cache'},$_,0,'>') if $options{'probe_level'} > 0;
                
                unless ($options{'quiet'} or $options{'verbose'}) {
                    print  "\b"x$settings{'NodeOrder'};
                    printf ('%'.$settings{'NodeOrder'}.'d',scalar keys %$nodes);
                }
            }
        }
    }
    
    unless ($options{'quiet'}) {
        print scalar keys %$nodes if $options{'verbose'};
        print ' nodes';
        print ' ('.$inactive_node_count.' inactive)' if $inactive_node_count > 0;
        print ', '.$active_device_count.' devices';
        print ' ('.$stack_count.' stacks)' if $stack_count > 0;
        print "\n";
    }
    
    return $nodes;
}




################################################################################




sub recognize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$device) = @_;
    
    my $node;
    foreach my $ip (keys %$nodes) {
        if (exists $nodes->{$ip}{'devices'}{$device}) {
            $nodes->{$ip}{'devices'}{$device}{'recognized'} = 1;
            $node = $nodes->{$ip};
            last;
        }
    }
    return $node;
}




sub synchronize {
    warn 'too few arguments' if @_ < 3;
    my ($nodes,$recognized,@rows) = @_;
    
    my $conflict_count = 0;
    foreach my $row (@rows) {
        my $serial  = $row->{$settings{'DeviceField'}};
        my $ifDescr = $row->{$settings{'InterfaceField'}};
        
        my $node;
        $recognized->{$serial} //= recognize ($nodes,$serial); #/#XXX
        $node = $recognized->{$serial};
        next unless defined $node;
        #say $node->{'ip'}.' ('.$node->{'hostname'}.'): '.$serial if $options{'verbose'}; #XXX
        
        # Detect conflicts.
        my $device = $node->{'devices'}{$serial};
        if (defined $device->{'interfaces'}{$ifDescr}) {
            my $interface = $device->{'interfaces'}{$ifDescr};
            if ($interface->{'recognized'}) {
                ++$conflict_count;
                push (@{$interface->{'conflicts'}{'duplicate'}},$row);
            }
            else {
                ++$interface->{'recognized'};
                foreach my $field (@{$settings{'InfoFields'}}) {
                    $interface->{'info'}{$field} = $row->{$field};
                }
            }
        }
        else {
            ++$conflict_count;
            push (@{$device->{'conflicts'}{'unrecognized'}},$row);
        }
    }
    return $conflict_count;
}




sub choose {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 3;
    my ($a,$b,$msg) = @_;
    $msg //= 'A conflict has been discovered.'; #/#XXX
    
    open (STDIN,'<',POSIX::ctermid) if $options{'node_list'} eq '-'; #XXX
    while (1) {
        print "\n" unless $options{'verbose'};
        say $msg;
        say 'Choose one of the following:';
        say ((' 'x$settings{'Indent'}).'[A]: '.$a);
        say ((' 'x$settings{'Indent'}).' B : '.$b);
        print "Choice: ";
        chomp (my $input = <STDIN>);
        return $a if $input =~ /^([aA1]+)?$/;
        return $b if $input =~ /^[bB2]+$/;
        say 'A decision could not be determined from your response. Try again.';
    }
}




sub ask {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($question) = @_;
    
    open (STDIN,'<',POSIX::ctermid) if $options{'node_list'} eq '-';
    while (1) {
        print $question.' [y/n] ';
        chomp (my $response = <STDIN>);
        return 1 if $response =~ /^([yY]+([eE]+[sS]+)?)$/;
        return 0 if $response =~ /^([nN]+([oO]+)?)$/;
        say 'A decision could not be determined from your response. Try again.';
    }
}




sub resolve_conflicts {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    foreach my $ip (sort keys %$nodes) {
        my $node = $nodes->{$ip};
        #say $node->{'hostname'}; #XXX
        foreach my $serial (sort keys %{$node->{'devices'}}) {
            my $device = $node->{'devices'}{$serial};
            #say '  '.$device->{'serial'}; #XXX
            if ($device->{'recognized'}) {
                foreach my $conflict (sort keys %{$device->{'conflicts'}}) {
                    #say '    '.$conflict; #XXX
                    while (my $row = shift @{$device->{'conflicts'}{$conflict}}) {
                        my $ifDescr = $row->{$settings{'InterfaceField'}};
                        #say '      '.$ifDescr; #XXX
                        given ($conflict) {
                            my $suffix = $serial.' at '.$ip.' ('.$node->{'hostname'}.').';
                            when ('unrecognized') {
                                my $msg = 'There is an unrecognized interface in the database ('.$ifDescr.') for '.$suffix;
                                my $a = ($options{'probe_level'} > 1) ? 'Omit'    : 'Delete';
                                my $b = ($options{'probe_level'} > 1) ? 'Include' : 'Ignore';
                                my $choice = $b; #XXX : choose ($a,$b,$msg);
                                if ($choice eq $b) {
                                    $device->{'interfaces'}{$ifDescr}{'ifDescr'} = $ifDescr;
                                    my $interface = $device->{'interfaces'}{$ifDescr};
                                    $interface->{'device'}     = $device;
                                    $interface->{'info'}{$_}   = $row->{$_} foreach @{$settings{'InfoFields'}};
                                    $interface->{'recognized'} = 1;
                                }
                            }
                            when ('duplicate') {
                                my $interface = $device->{'interfaces'}{$ifDescr};
                                my $msg = 'There is more than one entry in the database with information for '.$ifDescr.' on '.$suffix;
                                my $a = '(old) ';
                                my $b = '(new) ';
                                foreach my $field (@{$settings{'InfoFields'}}) {
                                    $a .= ', ' unless $a eq '(old) ';
                                    $b .= ', ' unless $b eq '(new) ';
                                    $a .= $interface->{'info'}{$field};
                                    $b .= $row->{$field};
                                }
                                my $choice = choose ($a,$b,$msg);
                                if ($choice eq $b) {
                                    $interface->{'info'}{$_} = $row->{$_} foreach @{$settings{'InfoFields'}};
                                }
                            }
                            default {
                                alert 'Resolution of an unsupported conflict ('.$conflict.') has been attempted.';
                            }
                        }
                    }
                    delete $device->{'conflicts'}{$conflict};
                }
                delete $device->{'conflicts'};
            }
            else {
                note ($settings{'BogeyLog'},$ip.' ('.$node->{'hostname'}.') '.$device->{'serial'});
                if ($options{'probe_level'} > 1) {
                    say 'A new device ('.$device->{'serial'}.') has been detected on '.$node->{'hostname'}.' that is not present in the database.';
                    if (0) { #XXX : ask 'Would you like to initialize it now?') {
                        foreach my $ifDescr (sort keys %{$device->{'interfaces'}}) {
                            my $interface = $device->{'interfaces'}{$ifDescr};
                            say 'An interface ('.$ifDescr.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                            foreach my $field (@{$settings{'InfoFields'}}) {
                                print ((' 'x$settings{'Indent'}).$field.': ');
                                $interface->{'info'}{$field} = <>;
                            }
                        }
                    }
                }
            }
        }
    }
}




sub identify {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    unless ($options{'quiet'}) {
        print 'identifying';
        print ' (using '.($options{'use_CSV'} // get_config 'DB.DBMS').')...'; #/#XXX
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve node interfaces from database.
    my $db;
    my @data;
    my $fields = $settings{'DeviceField'}.','.$settings{'InterfaceField'};
    $fields .= ','.$_ foreach sort @{$settings{'InfoFields'}};
    if (defined $options{'use_CSV'}) {
        open ($db,'<',$options{'use_CSV'});
        
        my $parser = Text::CSV->new;
        chomp (my @fields = split (',',<$db>));
        $parser->column_names(@fields);
        
        my $removed_field_count = 0;
        foreach my $i (keys @fields) {
            $i -= $removed_field_count;
            unless ($fields =~ /(^|,)$fields[$i](,|$)/) {
                ++$removed_field_count;
                splice (@fields,$i,1);
            }
        }
        die 'incompatible database' unless @fields == scalar split (',',$fields);
        
        foreach my $row (@{$parser->getline_hr_all($db)}) {
            my $entry = {};
            $entry->{$_} = $row->{$_} foreach @fields;
            push (@data,$entry);
        }
    }
    else {
        $db = DB;
        #my $query = $db->prepare('SELECT '.$fields.' FROM '.$settings{'Table'});
        my $query = $db->prepare('SELECT * FROM '.$settings{'Table'}); #XXX
        $query->execute;
        @data = @{$query->fetchall_arrayref({})};
    }
    
    my @unusable_rows; #XXX
    my %recognized; # $serial => $node map
    my $conflict_count = 0;
    foreach my $row (@data) {
        my $valid = [
            $settings{'DeviceField'},
            $settings{'InterfaceField'},
        ];
        my $invalid = 0;
        foreach my $field (@$valid) {
            ++$invalid and last unless defined $row->{$field} and $row->{$field} =~ /[\S]+/;
        }
        push (@unusable_rows,$row) and next if $invalid;
        
        $conflict_count += synchronize ($nodes,\%recognized,$row);
        
        unless ($options{'quiet'} or $options{'verbose'}) {
            print  "\b"x$settings{'NodeOrder'};
            printf ('%'.$settings{'NodeOrder'}.'d',scalar keys %recognized);
        }
    }
    
    unless ($options{'quiet'}) {
        print scalar keys %recognized if $options{'verbose'};
        print ' recognized';
        print ' ('.$conflict_count.' conflicts)' if $conflict_count > 0;
        print "\n";
    }
    
    # Resolve conflicts.
    unless ($options{'quiet'} or $conflict_count < 1) {
        resolve_conflicts $nodes if ask 'Do you want to resolve conflicts now?';
    }
    
    if ($options{'probe_level'} > 1) {
        note ($settings{'Probe2Cache'},$fields,0,'>');
        foreach my $ip (keys %$nodes) {
            my $node = $nodes->{$ip};
            foreach my $serial (keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                foreach my $ifDescr (keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifDescr};
                    
                    my $note = $serial.','.$ifDescr;
                    foreach my $field (@{$settings{'InfoFields'}}) {
                        $note .= ','.($interface->{'info'}{$field} // ''); #/#XXX
                    }
                    note ($settings{'Probe2Cache'},$note,0);
                }
            }
        }
    }
    
    return $db;
}




################################################################################




sub update {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$db) = @_;
    
    #XXX
}




################################################################################




sub run {
    
    # netsync inventories all active network devices listed in [file] or DNS (-D).
    # It uses gathered information to identify each device in a provided database.
    # Identified devices are then synchronized unless probing is used (see below).
    
    my $nodes = discover;
    
    #  $nodes == {
    #              $ip => {
    #                       'devices'  => {
    #                                       $serial => {
    #                                                    'interfaces' => {
    #                                                                      $ifDescr => {
    #                                                                                    'device'     => $device,
    #                                                                                    'ifDescr'    => 0, #XXX
    #                                                                                    'recognized' => 0,
    #                                                                                  },
    #                                                                    },
    #                                                    'node'       => $node;
    #                                                    'recognized' => 0;
    #                                                    'serial'     => $serial; #XXX
    #                                                  },
    #                                     },
    #                       'hostname' => SCALAR,
    #                       'info'     => SNMP::Info,
    #                       'ip'       => SCALAR,
    #                       'session'  => SNMP::Session,
    #                     },
    #            };
    
    exit if $options{'probe_level'} == 1;
    
    # Probe Level 1:
    #     netsync executes the discovery stage only.
    #     It probes the network for active nodes (logging them appropriately),
    #     and it creates an RFC1035-compliant list of them (default: var/dns.txt).
    #     This list may then be used as input to netsync to skip inactive nodes later.
    
    my $db = identify $nodes;
    
    #  $nodes == {
    #              $ip => {
    #                       'devices'  => {
    #                                       $serial => {
    #                                                    'conflicts'  => {
    #                                                                      'unrecognized' => ARRAY,
    #                                                                    },
    #                                                    'interfaces' => {
    #                                                                      $name => {
    #                                                                                 'conflicts'  => {
    #                                                                                                   'duplicate',
    #                                                                                                 },
    #                                                                                 'device'     => $device,
    #                                                                                 'info'       => {
    #                                                                                                   $InfoField => SCALAR,
    #                                                                                                 },
    #                                                                                 'recognized' => SCALAR,
    #                                                                               },
    #                                                                    },
    #                                                    'node'       => $node;
    #                                                    'recognized' => SCALAR;
    #                                                  },
    #                                     },
    #                       'hostname' => SCALAR,
    #                       'info'     => SNMP::Info,
    #                       'ip'       => SCALAR,
    #                       'session'  => SNMP::Session,
    #                     },
    #            };
    
    update ($nodes,$db) unless $options{'probe_level'} == 2;
    
    # Probe Level 2:
    #     netsync executes the discovery and identification stages only.
    #     It probes the database for discovered nodes (logging them appropriately),
    #     and it creates an RFC4180-compliant list of them (default: var/db.csv).
    #     This list may then be used as input to netsync to skip synchronization later.
    
    (defined $options{'use_CSV'}) ? close $db : $db->disconnect;
}




say 'configuring (using '.$options{'conf_file'}.')...' unless $options{'quiet'};
%settings = configure ($options{'conf_file'},{
    'Indent'      => 4,
    'NodeOrder'   => 4,
    'BogeyLog'    => 'var/log/bogies.log',
    'NodeLog'     => 'var/log/nodes.log',
    'StackLog'    => 'var/log/stacks.log',
    'Probe1Cache' => 'var/dns.txt',
    'Probe2Cache' => 'var/db.csv',
    'HostPrefix'  => '',
    'RecordType'  => 'A|AAAA',
},1,1,1);
validate;
run;
exit;
