#!/usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';
use feature 'switch';

use DBI;
use File::Basename;
use Getopt::Std;
use POSIX;
use Regexp::Common;
use Text::CSV;

use Toolbox::Configurator;
use Toolbox::FileManager;
use Toolbox::Networker;
use Toolbox::UserInterface;


our (%options,%settings,$VERSION);


BEGIN {
    $VERSION = '1.1.0';
    $options{'options'}   = 'c:p:D:d:a';
    $options{'arguments'} = '[nodes]';
    
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
    
    SNMP::addMibDirs('etc/mib');
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




################################################################################




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




sub device_interfaces {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($vendor,$session) = @_;
    
    my %serial2if2ifName;
    {
        my %if2ifName;
        {
            my ($types) = SNMP_get1 ([['.1.3.6.1.2.1.2.2.1.3' => 'ifType']],$session); # IF-MIB
            my ($ifNames,$ifs) = SNMP_get1 ([
                ['.1.3.6.1.2.1.31.1.1.1.1' => 'ifName'],  # IF-MIB
                ['.1.3.6.1.2.1.2.2.1.2'    => 'ifDescr'], # IF-MIB
            ],$session); # IF-MIB
            foreach my $i (keys @$ifs) {
                alert 'Malformed IF-MIB results have been received.' and next unless defined $types->[$i] and defined $ifNames->[$i];
                $if2ifName{$ifs->[$i]} = $ifNames->[$i] if $types->[$i] =~ /^(?!1|24|53)[0-9]+$/;
                alert 'A foreign ifType ('.$types->[$i].') has been encountered on interface '.$ifNames->[$i] if $types->[$i] =~ /^(?!1|6|24|53)[0-9]+$/;
            }
        }
        
        my @serials;
        {
            my ($serials) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.11' => 'entPhysicalSerialNum']],$session); # ENTITY-MIB
            if (defined $serials) {
                my ($classes) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.5' => 'entPhysicalClass']],$session);  # ENTITY-MIB
                foreach my $i (keys @$classes) {
                    push (@serials,$serials->[$i]) if $classes->[$i] =~ /3/ and $serials->[$i] !~ /[^[:ascii:]]/;
                }
            }
        }
        unless (@serials > 0) {
            my $serials;
            given ($vendor) {
                when ('cisco') {
                    ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.3'  => 'moduleSerialNumber'],       # CISCO-STACK-MIB
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.26' => 'moduleSerialNumberString'], # CISCO-STACK-MIB
                    ],$session);
                }
                when (['brocade','foundry']) {
                    ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2' => 'snChasUnitSerNum'], # FOUNDRY-SN-AGENT-MIB?
                        ['.1.3.6.1.4.1.1991.1.1.1.1.2'     => 'snChasSerNum'],     # FOUNDRY-SN-AGENT-MIB (stackless)
                    ],$session);
                }
                when ('hp') {
                    ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.11.2.36.1.1.2.9'        => 'hpHttpMgSerialNumber'],       # SEMI-MIB
                        #['.1.3.6.1.4.1.11.2.36.1.1.5.1.1.10'   => 'hpHttpMgDeviceSerialNumber'], # SEMI-MIB
                        #['.1.3.6.1.4.1.11.2.3.7.11.12.1.1.1.2' => 'snChasSerNum'],               # HP-SN-AGENT-MIB (stackless?)
                    ],$session);
                }
                default {
                    alert 'Serial retrieval attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            foreach my $serial (@$serials) {
                push (@serials,$serial) if $serial !~ /[^[:ascii:]]/;
            }
        }
        if (@serials == 0) {
            alert 'No serials could be found for a '.$vendor.' device.';
            return undef;
        }
        if (@serials == 1) {
            $serial2if2ifName{$serials[0]} = \%if2ifName;
        }
        else {
            my %if2serial;
            given ($vendor) {
                when ('cisco') {
                    my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.11' => 'portIfIndex']],$session); # CISCO-STACK-MIB
                    my @port2serial;
                    {
                        my ($port2module) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.1'  => 'portModuleIndex']],$session); # CISCO-STACK-MIB
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
                when (['brocade','foundry']) {
                    my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.38' => 'snSwPortIfIndex']],$session); # FOUNDRY-SN-SWITCH-GROUP-MIB
                    my @port2serial;
                    {
                        my ($port2umi) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.39' => 'snSwPortDescr']],$session); # FOUNDRY-SN-SWITCH-GROUP-MIB
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
                default {
                    alert 'Interface mapping attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            foreach my $if (keys %if2serial) {
                $serial2if2ifName{$if2serial{$if}}{$if} = $if2ifName{$if};
            }
        }
    }
    return \%serial2if2ifName;
}




sub probe {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    my $serial_count = 0;
    foreach my $node (@nodes) {
        
        my ($session,$info) = SNMP_Info $node->{'ip'};
        if (defined $info) {
            $node->{'session'} = $session;
            $node->{'info'}    = $info;
        }
        else {
            note ($settings{'NodeLog'},node_string ($node).' inactive');
            say node_string ($node).' inactive' if $options{'verbose'};
            next;
        }
        
        { # Process a newly discovered node.
            my $serial2if2ifName = device_interfaces ($node->{'info'}->vendor,$node->{'session'});
            if (defined $serial2if2ifName) {
                my @serials = keys %$serial2if2ifName;
                note ($settings{'NodeLog'},node_string ($node).' '.join (' ',@serials));
                initialize_node ($node,$serial2if2ifName);
                $serial_count += @serials;
            }
            else {
                note ($settings{'NodeLog'},node_string ($node).' no devices detected');
                next;
            }
        }
        
        node_dump $node if $options{'verbose'};
    }
    return $serial_count;
}




sub discover {
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    $nodes //= {}; #/#XXX
    
    unless ($options{'quiet'}) {
        print 'discovering';
        print ' (using '.((defined $options{'use_DNS'}) ? 'DNS' : ($options{'node_list'} eq '-') ? 'STDIN' : $options{'node_list'}).')...';
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve network nodes from file, pipe, or DNS (-D).
    my @zone;
    if (defined $options{'use_DNS'}) {
        my $resolver = DNS;
        $resolver->print if $options{'verbose'};
        $options{'use_DNS'} = '([^.]+)' if $options{'use_DNS'} eq 'all';
        foreach my $record ($resolver->axfr) {
            push (@zone,$record->string) if $record->name =~ /^($options{'use_DNS'})\./;
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
    
    my ($inactive_node_count,$deployed_device_count,$stack_count) = (0,0,0);
    foreach (@zone) {
        if (/^(?<host>[^.]+).*\s(?:A|AAAA)\s+(?<ip>$RE{'net'}{'IPv4'}|$RE{'net'}{'IPv6'})/) {
            $nodes->{$+{'ip'}}{'ip'} = $+{'ip'};
            my $node = $nodes->{$+{'ip'}};
            $node->{'hostname'} = $+{'host'};
            
            my $serial_count = probe $node;
            if ($serial_count < 1) {
                ++$inactive_node_count;
                delete $nodes->{$+{'ip'}};
            }
            else {
                $deployed_device_count += $serial_count;
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
        my $node_count = scalar keys %$nodes;
        print $node_count if $options{'verbose'};
        print ' node';
        print 's' if $node_count != 1;
        print ' ('.$inactive_node_count.' inactive)' if $inactive_node_count > 0;
        print ', '.$deployed_device_count.' device';
        print 's' if $deployed_device_count != 1;
        if ($stack_count > 0) {
            print ' ('.$stack_count.' stack';
            print 's' if $stack_count != 1;
            print ')';
        }
        print "\n";
    }
    
    return $nodes;
}




sub synchronize {
    warn 'too few arguments' if @_ < 3;
    my ($nodes,$recognized,@rows) = @_;
    
    my $conflict_count = 0;
    foreach my $row (@rows) {
        my $serial = uc $row->{$settings{'DeviceField'}};
        my $ifName = $row->{$settings{'InterfaceField'}};
        
        my $node = $recognized->{$serial};
        unless (defined $node) {
            my $device = recognize_device ($nodes,$serial);
            unless (defined $device) {
                note ($settings{'DeviceLog'},$serial.' unidentified');
                say $serial.' unidentified' if $options{'verbose'};
                next;
            }
            $recognized->{$serial} = $node = $device->{'node'};
            note ($settings{'DeviceLog'},$serial.' @ '.$node->{'ip'}.' ('.$node->{'hostname'}.')');
        }
        
        my $device = $node->{'devices'}{$serial};
        if ($options{'auto_match'} and not defined $device->{'interfaces'}{$ifName}) {
            foreach (sort keys %{$device->{'interfaces'}}) {
                if (/[^0-9]$ifName$/) {
                    $ifName = $row->{$settings{'InterfaceField'}} = $_;
                    last;
                }
            }
        }
        
        { # Detect conflicts.
            my $new_conflict_count = 0;
            if (defined $device->{'interfaces'}{$ifName}) {
                my $interface = $device->{'interfaces'}{$ifName};
                if ($interface->{'recognized'}) {
                    ++$new_conflict_count;
                    push (@{$interface->{'conflicts'}{'duplicate'}},$row);
                }
                else {
                    $interface->{'recognized'} = 1;
                    foreach my $field (@{$settings{'InfoFields'}}) {
                        $interface->{'info'}{$field} = $row->{$field};
                    }
                    
                    interface_dump $interface if $options{'verbose'};
                }
            }
            else {
                my $empty_field_count = 0;
                foreach my $field (@{$settings{'InfoFields'}}) {
                    ++$empty_field_count unless $row->{$field} =~ /[\S]+/;
                }
                if ($empty_field_count < @{$settings{'InfoFields'}}) {
                    if ($options{'probe_level'} > 1) {
                        my $note = $serial.','.$ifName;
                        foreach my $field (sort @{$settings{'InfoFields'}}) {
                            $note .= ','.($row->{$field} // ''); #/#XXX
                        }
                        note ($settings{'UnidentifiedCache'},$note,0);
                    }
                }
                else {
                    if ($options{'verbose'}) {
                        print 'An unidentified interface ('.$ifName.')';
                        print ' for '.$device->{'serial'};
                        print ' at '.$device->{'node'}{'ip'};
                        print ' ('.$device->{'node'}{'hostname'}.')';
                        say ' contains no information to synchronize and will be ignored.';
                    }
                }
            }
            $conflict_count += $new_conflict_count;
        }
    }
    return $conflict_count;
}




sub resolve_conflicts {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$auto) = @_;
    $auto //= 0; #/#XXX
    
    foreach my $ip (sort keys %$nodes) {
        my $node = $nodes->{$ip};
        foreach my $serial (sort keys %{$node->{'devices'}}) {
            my $device = $node->{'devices'}{$serial};
            if ($device->{'recognized'}) {
                foreach my $conflict (sort keys %{$device->{'conflicts'}}) {
                    while (my $row = shift @{$device->{'conflicts'}{$conflict}}) {
                        my $ifName = $row->{$settings{'InterfaceField'}};
                        given ($conflict) {
                            my $suffix = $serial.' at '.$ip.' ('.$node->{'hostname'}.').';
                            default {
                                alert 'Resolution of an unsupported device conflict ('.$conflict.') has been attempted.';
                            }
                        }
                    }
                    delete $device->{'conflicts'}{$conflict};
                }
                delete $device->{'conflicts'};
                
                foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    if ($interface->{'recognized'}) {
                        foreach my $conflict (sort keys %{$interface->{'conflicts'}}) {
                            while (my $row = shift @{$interface->{'conflicts'}{$conflict}}) {
                                given ($conflict) {
                                    my $suffix = $serial.' at '.$ip.' ('.$node->{'hostname'}.').';
                                    when ('duplicate') {
                                        my $interface = $device->{'interfaces'}{$ifName};
                                        
                                        my $new = $auto;
                                        unless ($auto) {
                                            my $message = 'There is more than one entry in the database with information for '.$ifName.' on '.$suffix;
                                            my @choices;
                                            push (@choices,'(old) ');
                                            push (@choices,'(new) ');
                                            foreach my $field (@{$settings{'InfoFields'}}) {
                                                $choices[0] .= ', ' unless $choices[0] eq '(old) ';
                                                $choices[1] .= ', ' unless $choices[1] eq '(new) ';
                                                $choices[0] .= $interface->{'info'}{$field};
                                                $choices[1] .= $row->{$field};
                                            }
                                            $new = (choose ($message,\@choices) eq $choices[1]);
                                        }
                                        else {
                                            say 'Duplicate interface ('.$ifName.') on '.$suffix if $options{'verbose'};
                                            
                                        }
                                        if ($new) {
                                            $interface->{'info'}{$_} = $row->{$_} foreach @{$settings{'InfoFields'}};
                                        }
                                    }
                                    default {
                                        alert 'Resolution of an unsupported interface conflict ('.$conflict.') has been attempted.';
                                    }
                                }
                            }
                            delete $interface->{'conflicts'}{$conflict};
                        }
                        delete $interface->{'conflicts'};
                    }
                    else {
                        my $initialized = 0;
                        unless ($options{'probe_level'} < 2 or $auto) {
                            say 'An unrecognized interface ('.$ifName.') has been detected on '.$serial.' at '.$ip.' ('.$node->{'hostname'}.') that is not present in the database.';
                            if (ask 'Would you like to initialize it now?') {
                                say 'An interface ('.$ifName.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                                foreach my $field (@{$settings{'InfoFields'}}) {
                                    print ((' 'x$settings{'Indent'}).$field.': ');
                                    $interface->{'info'}{$field} = <>;
                                }
                                $interface->{'recognized'} = $initialized = 1;
                            }
                        }
                        note ($settings{'UnrecognizedLog'},$ip.' ('.$node->{'hostname'}.') '.$serial.' '.$ifName) unless $initialized;
                    }
                }
            }
            else {
                my $initialized = 0;
                unless ($options{'probe_level'} < 2 or $auto) {
                    say 'An unrecognized device ('.$serial.') has been detected at '.$ip.' ('.$node->{'hostname'}.') that is not present in the database.';
                    if (ask 'Would you like to initialize it now?') {
                        open (STDIN,'<',POSIX::ctermid); #XXX
                        foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                            my $interface = $device->{'interfaces'}{$ifName};
                            say 'An interface ('.$ifName.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                            foreach my $field (@{$settings{'InfoFields'}}) {
                                print ((' 'x$settings{'Indent'}).$field.': ');
                                chomp ($interface->{'info'}{$field} = <STDIN>);
                            }
                        }
                        $device->{'recognized'} = $initialized = 1;
                    }
                }
                note ($settings{'UnrecognizedLog'},$ip.' ('.$node->{'hostname'}.') '.$serial) unless $initialized;
            }
        }
    }
}




sub identify {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    my $fields = $settings{'DeviceField'}.','.$settings{'InterfaceField'};
    $fields .= ','.join (',',sort @{$settings{'InfoFields'}});
    
    unless ($options{'quiet'}) {
        print 'identifying';
        print ' (using '.($options{'use_CSV'} // get_config 'DB.DBMS').')...'; #/#XXX
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve node interfaces from database.
    my @data;
    if (defined $options{'use_CSV'}) {
        open (my $db,'<',$options{'use_CSV'});
        
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
        
        close $db;
    }
    else {
        my $db = DB;
        my $query = $db->prepare('SELECT * FROM '.$settings{'Table'}); #XXX $db->prepare('SELECT '.$fields.' FROM '.$settings{'Table'});
        $query->execute;
        @data = @{$query->fetchall_arrayref({})};
        $db->disconnect;
    }
    
    
    note ($settings{'UnidentifiedCache'},$fields,0,'>') if $options{'probe_level'} > 1;
    
    my $conflict_count = 0;
    {
        my %recognized; # $recognized{$serial} == $node
        
        foreach my $row (@data) {
            my $valid = [
                $settings{'DeviceField'},
                $settings{'InterfaceField'},
            ];
            my $invalid = 0;
            foreach my $field (@$valid) {
                ++$invalid and last unless defined $row->{$field} and $row->{$field} =~ /[\S]+/;
            }
            next if $invalid;
            
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
    }
    
    { # Resolve conflicts.
        my $auto = ($conflict_count > 0);
        my $question = 'Do you want to resolve conflicts now';
        $question .= ($conflict_count > 0) ? '?' : ' (if any)?' ;
        $auto = (not ask $question) unless $options{'quiet'};
        resolve_conflicts ($nodes,$auto);
    }
    
    if ($options{'probe_level'} > 1) {
        note ($settings{'Probe2Cache'},$fields,0,'>');
        foreach my $ip (sort keys %$nodes) {
            my $node = $nodes->{$ip};
            foreach my $serial (sort keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    
                    my $note = $serial.','.$ifName;
                    foreach my $field (sort @{$settings{'InfoFields'}}) {
                        $note .= ','.($interface->{'info'}{$field} // ''); #/#XXX
                    }
                    note ($settings{'Probe2Cache'},$note,0);
                }
            }
        }
    }
}




sub update {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    unless ($options{'quiet'}) {
        print 'updating...';
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    my ($successful_update_count,$failed_update_count) = (0,0);
    foreach my $ip (keys %$nodes) {
        my $node = $nodes->{$ip};
        foreach my $serial (keys %{$node->{'devices'}}) {
            my $device = $node->{'devices'}{$serial};
            next unless $device->{'recognized'};
            
            foreach my $ifName (keys %{$device->{'interfaces'}}) {
                my $interface = $device->{'interfaces'}{$ifName};
                next unless $interface->{'recognized'};
                
                my $update = '';
                my $empty = 1;
                foreach my $field (keys %{$interface->{'info'}}) {
                    $update .= "," unless $update eq '';
                    $update .= $field.':'.$interface->{'info'}{$field};
                    $empty = 0 if defined $interface->{'info'}{$field} and $interface->{'info'}{$field} =~ /[\S]+/;
                }
                $update = '' if $empty;
                
                my $note = '';
                $note .= $ip.' ('.$node->{'hostname'}.')';
                $note .= ' '.$serial;
                $note .= ' '.$ifName.' ('.$interface->{'IID'}.')';
                my $error = SNMP_set (get_config ('netsync.SyncOID'),$interface->{'IID'},$update,$node->{'session'});
                unless ($error) {
                    $update =~ s/[\n]/,/g;
                    $update =~ s/[\s]+//g;
                    $update =~ s/:,/:(empty),/g;
                    note ($settings{'UpdateLog'},$note.' '.$update);
                    ++$successful_update_count;
                    
                    unless ($options{'quiet'}) {
                        if ($options{'verbose'}) {
                            interface_dump $interface;
                        }
                        else {
                            print  "\b"x$settings{'NodeOrder'};
                            printf ('%'.$settings{'NodeOrder'}.'d',$successful_update_count);
                        }
                    }
                }
                else {
                    note ($settings{'UpdateLog'},$note.' error: '.$error);
                    ++$failed_update_count;
                    
                    if ($options{'verbose'}) {
                        say interface_string ($interface).' failed';
                        say ((' 'x$settings{'Indent'}).$error);
                    }
                }
            }
        }
    }
    
    unless ($options{'quiet'}) {
        print $successful_update_count if $options{'verbose'};
        print ' successful';
        print ' ('.$failed_update_count.' failed)' if $failed_update_count > 0;
        print "\n";
    }
}




################################################################################


sub run {
    my $nodes = {};
    #  $nodes == {
    #              $ip => {
    #                       'devices'  => {
    #                                       $serial => {
    #                                                    'conflicts'  => { # This key exists during the identification stage only.
    #                                                                      $conflict => ARRAY,
    #                                                                    },
    #                                                    'interfaces' => {
    #                                                                      $ifName => {
    #                                                                                   'conflicts'  => { # This key exists during the identification stage only.
    #                                                                                                     'duplicate' => ARRAY,
    #                                                                                                   }, # This key is populated during the identification stage only.
    #                                                                                   'device'     => $device,
    #                                                                                   'ifName'     => $ifName,
    #                                                                                   'IID'        => SCALAR,
    #                                                                                   'info'       => {
    #                                                                                                     $field => SCALAR,
    #                                                                                                   },
    #                                                                                   'recognized' => SCALAR,
    #                                                                                 },
    #                                                                    },
    #                                                    'node'       => $node,
    #                                                    'recognized' => SCALAR,
    #                                                    'serial'     => $serial,
    #                                                  },
    #                                     },
    #                       'hostname' => SCALAR,
    #                       'info'     => SNMP::Info,
    #                       'ip'       => SCALAR,
    #                       'session'  => SNMP::Session,
    #                     },
    #            };
    discover $nodes;
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
        'NodeLog'           => 'var/log/nodes.log',
        'DeviceLog'         => 'var/log/devices.log',
        'UnrecognizedLog'   => 'var/log/unrecognized.log',
        'UpdateLog'         => 'var/log/updates.log',
        'Probe1Cache'       => 'var/dns.txt',
        'Probe2Cache'       => 'var/db.csv',
        'UnidentifiedCache' => 'var/unidentified.csv',
    },1,1,1);
    validate;
}
run and exit;




################################################################################




=head1 NAME

netsync - network/database utility

=head1 SYNOPSIS

C<netsync [-hVvqcpDda] [nodes]>

=head1 DESCRIPTION

netsync is a network synchronization tool that:

 - maps network interfaces to their respective (potentially stacked) devices>
 - gathers interface-specific information from an asset management database>
 - sends the information it gathers to each device>

Note: All communication with network nodes is done using SNMP,
      and the database is assumed to track devices by serial number.

netsync also provides ways of producing useful information about the network.

=head2 Overview

Execution begins with the parsing of the configuration file (-c).
netsync discovers all active network devices listed in [nodes] or DNS.
It uses gathered information to identify each device in a provided database.
Identified devices are then updated unless probing is used.

See F<doc/netsync.svg> for corresponding visual guidance.

=head2 0 Invocation

=head3 Suggested Method

netsync may be invoked using the provided script, F<netsync.sh>.
The script creates an executable in bin and runs it with the correct libraries.

=head3 Perl

The Perl implementation may be invoked manually;
however, this is not suggested because appropriate libraries must be included at runtime (see below),
and using the included script allows more fine-tune control over netsync's environment to developers.

=head4 Libraries

A generic set of useful packages is stored in the Toolbox module in src/lib.
Following is a brief description of each:

 Toolbox::Configurator  - methods for handling configuration files and default settings
 Toolbox::FileManager   - methods for handling I/O automatically and efficiently
 Toolbox::TimeKeeper    - methods for retrieving reliable chronological measurements
 Toolbox::UserInterface - methods for interacting with the user

=head4 Manual Build (optional)

 $ cp src/netsync.pl bin/netsync
 $ chmod +x bin/netsync

=head4 Manual Invocation

 $ perl -Isrc/lib bin/netsync

If Manual Build was skipped, use the following instead:

 $ perl -Isrc/lib src/netsync.pl

=head2 1 Runtime Configuration

=head3 Options

=head4 -h --help

Help. Print usage and options.

Note: Help and Version print information and exit, netsync is not executed in either case.

=head4 -V

Version. Print build information.
Note: Help and Version print information and exit, netsync is not executed in either case.

=head4 -v

Verbose. Print everything.

Note: If both Quiet and Verbose mode are used simultaneously, they cancel each other out.

=head4 -q

Quiet. Print nothing.

Note: If both Quiet and Verbose mode are used simultaneously, they cancel each other out.

=head4 -c .ini

Specify a configuration file to use. (default: F<etc/netsync.ini>)

=head4 -p #

Probe. There are 2 probe levels:

 1: Probe the network for active nodes.
 2: Probe the database for those nodes.

=head4 -D pattern

Use DNS to retrieve a list of hosts matching the pattern.

Hint: Use the pattern 'all' to turn off the hostname filter.

=head4 -d .csv

Specify an RFC4180-compliant database file to use.

=head4 -a

Enable interface auto-matching.

Note: Interface auto-matching is very likely to be helpful if the database manages interfaces numerically.
If enabled, it causes a database port such as 23 to align with ifNames such as ethernet23 or Gi1/0/23.

=head3 Parameters

=head4 [nodes]

Specify an RFC1035-compliant network node list to use.

Note: Either -D pattern or nodes must be specified.
If neither are present, input will be read from standard input (a pipe or the keyboard).

=head2 2 Settings

A configuration file may be specified using the -c option.
Otherwise, a generic configuration file (etc/netsync.ini) is provided,
but it does not have enough information for netsync to be fully functional out-of-the-box.
Namely, the following settings must be provided for a sufficient runtime environment:

=head3 DNS

Note: DNS settings are not necessary if only RFC1035-compliant node lists will be used (see [nodes]).

=head4 domain

a FQDN e.g. example.com

=head3 SNMP

=head4 Version

Note: netsync should work out-of-the-box on a network with default SNMP settings,
      but it is not recommended to operate a network with such an insecure configuration.

=over 5

=item SNMPv3 (recommended)

 SecLevel  - (If this is left default, there isn't much benefit to using SNMPv3 over v2.)
 SecName   - username (default: initial)
 AuthPass  - the authentication (access) key
 PrivPass  - the privacy (encryption) key

=item SNMPv2

 Community - The SNMP community to address (default: public).

=back

=head3 DB

Note: DB settings are not necessary if only RFC4180-compliant database (.csv) files will be used (see -d).

=head4 DBMS

the type of database e.g. Oracle

=head4 Server

the database location

=head4 Port

the database location

=head4 Database

the name of the database

=head4 DSN

DBMS-specific connection details

=head4 Username

the name of a user that has access to the database

=head4 Password

the authentication key of the user

=head3 netsync

                           Table
 ---------------------------------------------------------
 |  DeviceField  |  InterfaceField  |  InfoFields...     |
 ---------------------------------------------------------                              =============
 |   (serial)    |     (ifName)     |(interface-specific)|   --->    netsync    --->    || SyncOID ||
 |                          ...                          |                              =============
 ---------------------------------------------------------                                    (device)

Note: Once netsync has identified an interface in the database with its corresponding interface on the network,
      it will overwrite the device with the InfoFields in the database.

=head4 Table

the name of the table in the database that contains the following fields

=head4 DeviceField

the field that provides a unique ID for each device

=head4 InterfaceField

the field that holds interface names retrieved from the IF-MIB (ifName) via SNMP

=head4 InfoFields

a comma-separated list of fields containing interface-specific information

=head4 SyncOID

Values from InfoFields will be concatenated (respectively) and stored in the device via SNMP.


=head3 Optional

Explanation of each log and cache file will be provided in context below.

=head4 Indent

a formatting option to specify the number of spaces to proceed details of a previous line 

=head4 NodeOrder

a formatting option to adapt discovered node counts to any size network (must be > 0)

Example

=over 5

NodeOrder = 3 (nodes < 1000), 780 nodes

 > discovering (using DNS)... 780 nodes (50 inactive), 800 devices (10 stacks)

NodeOrder = 9 (nodes < 1000000000), 780 nodes

 > discovering (using DNS)...       780 nodes (50 inactive), 800 devices (10 stacks)

NodeOrder = 1 (nodes < 10), 24 nodes !

 > discovering (using DNS)... 1111111111222224 nodes (5 inactive), 26 devices (1 stack)

=back

=head2 3 Data Structures

netsync builds an internal view of the network whenever it is run.
Each node is associated with its IP address and device(s).
Each device is associated with is serial and interface(s).
Each interface is associated with interface-specific information from the database.

The resulting data structure could be described as a list of trees.

 |-> node (IP)
 |-> node (IP)
 |-> node (IP)
 |                              -interface (ifName)
 |                             /
 |             -device (serial)--interface (ifName)
 |            /                \
 |-V node (IP)                  -interface (ifName)
 |            \
 |             -device (serial)--interface (ifName)
 |                             \
 |                              -interface (ifName)
 |-> node (IP)
 |-> node (IP)
 |                              -interface (ifName)
 |                             /
 |-V node (IP)--device (serial)--interface (ifName)
 |                             \
 |                              -interface (ifName)
 |-> node (IP)
 |-> node (IP)
 |-> node (IP)
 |-> node (IP)
 ...

=head3 States

=head4 Nodes

       active : reachable and responsive
     inactive : unreachable or unresponsive

=head4 Devices & Interfaces

   recognized : found on the network and in the database
 unrecognized : found on the network but not in the database
   identified : found in the database and on the network
 unidentified : found in the database but not on the network

Invariants

=over 5

          recognized <-> identified
 unrecognized device --> unrecognized interfaces
 unidentified device --> unidentified interfaces

=back

=head2 4 Discovery

The first task netsync has is to find all relevant nodes on the network.
Relevant nodes are specified one of three ways:

=head3 using -D pattern

The pattern is used to select appropriate hosts.

Example

=over 4

 $ netsync.sh -D "sw[^.]+|hub[0-9]+"
 www.example.com            <-- no match (www)
 hub123.example.com         <-- match (hub123)
 sw1234.example.com         <-- match (sw1234)

=back

=head3 using [nodes]

[nodes] is a path to a file containing an RFC1035-compliant list of relevant nodes.

=head4 About RFC1035

RFC1035 specifies a satisfactory format for resource records found in a nameserver (see 3.2.1).
This format is used to produce the output of the popular command-line utility dig.
Thus, for simple pipes as described in part 3 above, netsync accepts RFC1035-compliant input.

Note: Only A or AAAA records with valid IPv4 or IPv6 addresses are used.

=head3 using (pipe or keyboard)

When no input directives are detected, netsync attempts to pull a node list from standard input.
This allows pipelining with dig, grep, and other command-line utilities for extended functionality.

Examples

=over 4

 $ dig axfr example.com | grep hub123 | netsync.sh

Z<>

 $ cat superset.txt | grep hub[0-9]+ | netsync.sh

=back

=head2 5 Node Processing

Once all relevant nodes have been specified, netsync must attempt to contact each to see if it is active.
Any node that netsync attempts to contact is logged in NodeLog with the results of the attempt.
If the node is active, netsync will try to extract the serial numbers of all devices present at that node.
If more than one serial is discovered, netsync will try to map interfaces to each device (serial).

Note: Only ASCII serials are supported.

=head3 Supported Node Vendors

=over 4

=item Brocade

=item Cisco

=item HP

=back

=head3 Supported Stack Vendors

=over 4

=item Brocade

=item Cisco

=back

=head3 Mapping Process

=over 4

=item 1 Extract interfaces.

=over 5

=item standard

 [1]  1.3.6.1.2.1.2.2.1.3  (ifType)  : appropriate interface IID
     excluded: other(1), softwareLoopback(24), propVirtual(53)
 [2a] 1.3.6.1.2.1.31.1.1.1 (ifName)  : interface IID to ifName
 [2b] 1.3.6.1.2.1.2.2.1.2  (ifDescr) : interface IID to ifDescr

=item proprietary

 [unsupported]

=back

=item 2 Extract serials.

=over 5

=item standard

 [1] 1.3.6.1.2.1.47.1.1.1.1.5  (entPhysicalClass)     : appropriate device IID
     included: chassis(3)
 [2] 1.3.6.1.2.1.47.1.1.1.1.11 (entPhysicalSerialNum) : device IID to serial

=item proprietary

=over 6

=item Cisco

 [a] 1.3.6.1.4.1.9.5.1.3.1.1.3  (moduleSerialNumber)
 [b] 1.3.6.1.4.1.9.5.1.3.1.1.26 (moduleSerialNumberString)

=item Brocade

 [a] 1.3.6.1.4.1.1991.1.1.1.4.1.1.2 (snChasUnitSerNum)
 [b] 1.3.6.1.4.1.1991.1.1.1.1.2     (snChasSerNum)
     Note: This OID does NOT support stacks.

=item HP

 [a] 1.3.6.1.4.1.11.2.36.1.1.2.9 (hpHttpMgSerialNumber)

=back

=back

=item 3 Map interfaces to serials.

=over 5

=item standard

 [unsupported]

=item proprietary

=over 6

=item Cisco

 [1]  1.3.6.1.4.1.9.5.1.4.1.1.11 (portIfIndex)              : port IID to interface IID
 [2]  1.3.6.1.4.1.9.5.1.4.1.1.1  (portModuleIndex)          : port IID to module IID
 [3a] 1.3.6.1.4.1.9.5.1.3.1.1.3  (moduleSerialNumber)       : module IID to serial
 [3b] 1.3.6.1.4.1.9.5.1.3.1.1.26 (moduleSerialNumberString) : module IID to serial

=item Brocade

 [1] 1.3.6.1.4.1.1991.1.1.3.3.1.1.38 (snSwPortIfIndex)  : port IID to interface IID
 [2] 1.3.6.1.4.1.1991.1.1.3.3.1.1.39 (snSwPortDescr)    : port IID to U/M/I
     Note: netsync assumes unit/module/interface (U/M/I) definitively maps unit to module IID.
 [3] 1.3.6.1.4.1.1991.1.1.1.4.1.1.2  (snChasUnitSerNum) : module IID to serial

=back

=back

=back

=head2 6 Probe Level 1

If the probe option is used, netsync will not complete execution entirely,
and neither the devices nor the database will be modified.
Instead, resources are created to aid in future runs of netsync.
Probe functionality is broken into levels that correspond to netsync stages.
Each level is accumulative (i.e. level 2 does level 1, too).

Probe level 1 is specified using -p1 and updates Probe1Cache.

During probe Level 1, netsync executes the discovery stage only.
After probing the network for active nodes (logging them appropriately),
it creates an RFC1035-compliant list of them (default: F<var/dns.txt>).
This list may then be used as input to netsync to skip inactive nodes later.

Example

=over 3

 $ netsync.sh -p1 -D "sw[^.]+|hub[0-9]+"
 > configuring (using etc/netsync.ini)...
 > discovering (using DBMS)...  780 nodes (50 inactive), 800 devices (10 stacks)
 $ netsync.sh var/dns.txt
 > configuring (using etc/netsync.ini)...
 > discovering (using var/dns.txt)...  780 nodes, 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)

=back

=head2 7 Identification

Once netsync has a view of the network's hardware,
it requires a database to find information specific to each interface.
This database may be provided one of two ways:

=head3 using DBMS (recommended)

This must be preconfigured in the configuration file and on the DBMS.

=head3 using -d .csv

A RFC4180-compliant database file may be specified using -d.

=head4 About RFC4180

RFC4180 specifies a simple format (CSV) for database files.
This format is almost universally supported making it useful for importing and exporting data.
Thus, for part 2 above, netsync accepts and produces RFC4180-compliant files.

Note: Since netsync treats the database as read-only,
      it assumes the specified table and fields are already present and populated in the database.

=head2 8 Synchronization and Conflicts

netsync locates the entries of the database on the network.
If either DeviceField or InterfaceField are empty in a given row, the invalid row is skipped.
Valid rows are synchronized with the network.
Any entry that netsync synchronizes is logged in DeviceLog with previously unseen network locations.

Devices are located by searching for DeviceField values in its internal representation of the network.
Rows with unidentified (not found) devices are skipped.
Entries are then checked for conflicts.

Unless netsync is running in Quiet mode, it will ask whether you want to resolve conflicts or not.
Answering no is the same as running in Quiet mode, both cause conflicts to be resolved automatically.


There are 3 types of conflicts.

=head3 Unidentified Interfaces

This occurs when netsync fails to find an InterfaceField value on an identified device.
If interface auto-matching is not enabled, the unidentified interface is skipped,
or if probing (-p) is used and the interface-specific information isn't empty,
the row is dumped (default: F<unidentified.csv>).
Interface auto-matching is very likely to be helpful if the database manages interfaces numerically.
If enabled, it causes a database port such as 23 to align with ifNames such as ethernet23 or Gi1/0/23.

=head3 Duplicate Entries

This occurs when more than one entry for the same interface exists in the database.
During automatic resolution, the last entry seen is kept,
otherwise netsync will ask which entry to keep.
The motivation for this is the idea that entries farther into the file were likely added later.

=head3 Unrecognized Devices & Interfaces

This occurs when hardware is found on the network but not in the database.
If conflicts aren't being automatically resolved and probing (-p) is used,
you will be asked to initialize unrecognized hardware.
If the unrecognized hardware is not manually initialized, it will be logged in UnrecognizedLog.

=head2 9 Probe Level 2

Probe level 2 is specified using -p2 and updates Probe1Cache, UnidentifiedCache, and Probe2Cache.

During probe level 2, netsync executes the discovery and identification stages only.
After probing the database for discovered nodes (logging them appropriately),
it creates an RFC4180-compliant list of them (default: F<var/db.csv>).
This list may then be used as input to netsync to skip synchronization later.

Example

=over 3

 $ netsync.sh -p2 -D "sw[^.]+|hub[0-9]+" -a
 > configuring (using etc/netsync.ini)...
 > discovering (using DNS)...  780 nodes (50 inactive), 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)
 > Do you want to resolve conflicts now? [y/n] n
 $ netsync.sh -d var/db.csv var/dns.txt
 > configuring (using etc/netsync.ini)...
 > discovering (using var/dns.txt)...  780 nodes, 800 devices (10 stacks)
 > identifying (using var/db.csv)...  800 recognized

=back

Note: All unrecognized hardware will be present in Probe2Cache; however, no unidentified entries will.
      Instead, unidentified entries are stored in UnidentifiedCache.
      This is so the output of probe level 2 can serve as a sort of snapshot of the network in time.

=head2 10 Updating

All modifications made to any device are logged in UpdateLog.

If probing is not used, netsync attempts to actualize its internally synchronized network using SNMP.
This is done by pushing gathered interface-specific information to the devices on the network.
This information is stored in the device at the specified SyncOID, and is overwritten anytime netsync updates it.

=head1 EXAMPLES

 $ netsync.sh -D "sw[^.]+|hub[0-9]+" -a
 > configuring (using etc/netsync.ini)...
 > discovering (using DNS)...  780 nodes (50 inactive), 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)

Z<>

 $ dig axfr domain.tld | egrep ^(sw[^.]+|hub[0-9]+) | netsync.sh
 > configuring (using etc/netsync.ini)...
 > discovering (using STDIN)...  780 nodes (50 inactive), 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)

Z<>

 $ netsync.sh -p1 -D "sw[^.]+|hub[0-9]+"
 > configuring (using etc/netsync.ini)...
 > discovering (using DBMS)...  780 nodes (50 inactive), 800 devices (10 stacks)
 $ netsync.sh var/dns.txt
 > configuring (using etc/netsync.ini)...
 > discovering (using var/dns.txt)...  780 nodes, 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)

Z<>

 $ netsync.sh -p2 -D "sw[^.]+|hub[0-9]+" -a
 > configuring (using etc/netsync.ini)...
 > discovering (using DNS)...  780 nodes (50 inactive), 800 devices (10 stacks)
 > identifying (using DBMS)...  670 recognized (4 conflicts)
 $ netsync.sh -d var/db.csv var/dns.txt
 > configuring (using etc/netsync.ini)...
 > discovering (using var/dns.txt)...  780 nodes, 800 devices (10 stacks)
 > identifying (using var/db.csv)...  800 recognized

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
