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
    $VERSION = '1.0.2';
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
    say '  -q          Quiet. Print nothing.';
    say '  -v          Verbose. Print everything.';
    say '  -V          Version. Print build information.';
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
    $options{'options'} = 'hqvV'.$options{'options'};
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
                $serial2if2ifName{$if2serial{$if}}{$if} = $if2ifName{$if}; #XXX if defined $if2serial{$if};
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
        print 's' if $node_count > 1;
        print ' ('.$inactive_node_count.' inactive)' if $inactive_node_count > 0;
        print ', '.$deployed_device_count.' device';
        print 's' if $deployed_device_count > 1;
        if ($stack_count > 0) {
            print ' ('.$stack_count.' stack';
            print 's' if $stack_count > 1;
            print ')';
        }
        print "\n";
    }
    
    return $nodes;
}




################################################################################




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




################################################################################




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
                foreach my $field (keys %{$interface->{'info'}}) {
                    $update .= "\n" unless $update eq '';
                    $update .= $field.' : '.$interface->{'info'}{$field};
                }
                
                my $note = '';
                $note .= $ip.' ('.$node->{'hostname'}.')';
                $note .= ' '.$serial;
                $note .= ' '.$ifName.' ('.$interface->{'IID'}.')';
                my $error = SNMP_set (get_config 'netsync.SyncOID',$interface->{'IID'},$update,$node->{'session'});
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
    
    # netsync discovers all active network devices listed in [nodes] or DNS (-D).
    # It uses gathered information to identify each device in a provided database.
    # Identified devices are then updated unless probing is used (see below).
    
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
    
    # Probe Level 1:
    #     netsync executes the discovery stage only.
    #     It probes the network for active nodes (logging them appropriately),
    #     and it creates an RFC1035-compliant list of them (default: var/dns.txt).
    #     This list may then be used as input to netsync to skip inactive nodes later.
    
    identify $nodes;
    exit if $options{'probe_level'} == 2;
    
    # Probe Level 2:
    #     netsync executes the discovery and identification stages only.
    #     It probes the database for discovered nodes (logging them appropriately),
    #     and it creates an RFC4180-compliant list of them (default: var/db.csv).
    #     This list may then be used as input to netsync to skip synchronization later.
    
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
run;
exit;
