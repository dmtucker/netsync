#!/usr/bin/perl

package Netsync;

use autodie;
use strict;

use feature 'say';
use feature 'switch';

use File::Basename;
use POSIX;
use Regexp::Common;
use Text::CSV;

use Configurator::DB;
use Configurator::DNS;
use Configurator::SNMP;
use FileManager;
use Netsync::Networker;
use Netsync::UI;


=head1 NAME

Netsync - network/database utility

=head1 SYNOPSIS

C<use Netsync;>

=cut


our $VERSION = '1.0.0-alpha';
our %config;
{
    my $SCRIPT = fileparse ($0,"\.[^.]*");
    
    $config{'Indent'}            = 4;
    
    $config{'DeviceField'}       = undef;
    $config{'InfoFields'}        = undef;
    $config{'InterfaceField'}    = undef;

    $config{'auto_match'}        = 0;
    $config{'probe_level'}       = 0;
    $config{'quiet'}             = 0;
    $config{'verbose'}           = 0;
    
    $config{'NodeOrder'}         = 4;
    $config{'AlertLog'}          = '/var/log/'.$SCRIPT.'/'.$SCRIPT.'.log';
    $config{'DeviceLog'}         = '/var/log/'.$SCRIPT.'/devices.log';
    $config{'NodeLog'}           = '/var/log/'.$SCRIPT.'/nodes.log';
    $config{'Probe1Cache'}       = '/var/cache/'.$SCRIPT.'/dns.txt';
    $config{'Probe2Cache'}       = '/var/cache/'.$SCRIPT.'/db.csv';
    $config{'UnidentifiedCache'} = '/var/cache/'.$SCRIPT.'/unidentified.csv';
    $config{'UnrecognizedLog'}   = '/var/log/'.$SCRIPT.'/unrecognized.log';
    $config{'UpdateLog'}         = '/var/log/'.$SCRIPT.'/updates.log';
    $config{'SyncOID'}           = 'ifAlias';
}


=head1 DESCRIPTION

This package can discover and synchronize a network and database.

=head1 METHODS

=head2 configure \%environment

=head3 Arguments

=head4 environment

key-value pairs of environment configurations

Available Environment Settings

=over 5

=item AlertLog

where to log errors and alerts

default: F</var/log/E<lt>script nameE<gt>/E<lt>script nameE<gt>.log>

=item auto_match

Enable interface auto-matching.

default: 0

Note: Interface auto-matching is very likely to be helpful if the database manages interfaces numerically.
If enabled, it causes a database port such as 23 to align with ifNames such as ethernet23 or Gi1/0/23.

=item DeviceField

the table field to use as a unique ID for devices

=item DeviceLog

where to log the location of all devices found in the database

default: F</var/log/E<lt>script nameE<gt>/devices.log>

=item Indent

the number of spaces to use when output is indented

default: 4

=item InfoFields

which table fields to synchronize with device interfaces

=item InterfaceField

which table field to use as a unique ID for device interfaces

=item node_list

an RFC1035-compliant network node list to use

default: '-'

Note: '-' causes input to be taken from STDIN if neither node_list nor use_DNS are specified.

=item NodeLog

where to log all probed nodes

default: F</var/log/E<lt>script nameE<gt>/nodes.log>

=item NodeOrder

the width of fields specifying node counts

default: 4

=item probe_level

Probe Levels

=over 6

=item 1 Probe the network for active nodes.

=item 2 Probe the database for those nodes.

=back

Note: If the probe option is used, netsync will not complete execution entirely,
and neither the devices nor the database will be modified.
Instead, resources are created to aid in future runs of netsync.
Probe functionality is broken into levels that correspond to netsync stages.
Each level is accumulative (i.e. level 2 does level 1, too).

default: 0

=item Probe1Cache

where probe level 1 RFC1035 output is stored

default: F</var/cache/E<lt>script nameE<gt>/dns.txt>

=item Probe2Cache

where probe level 2 RFC4180 output is stored

default: F</var/cache/E<lt>script nameE<gt>/db.csv>

=item quiet

Print nothing.

Note: If both Quiet and Verbose mode are used simultaneously, they cancel each other out.

default: 0

=item Table

which database table to use

=item UnidentifiedCache

where to dump interfaces found while probing in the database that do not correspond to an interface on the actual device

default: F</var/cache/E<lt>script nameE<gt>/unidentified.csv>

=item UnrecognizedLog

where to log devices found on the network, but not in the database

default: F</var/log/E<lt>script nameE<gt>/unrecognized.log>

=item UpdateLog

where to log all modifications made to the network

default: F</var/log/E<lt>script nameE<gt>/updates.log>

=item use_CSV

an RFC4180-compliant database file to use

default: undef

=item use_DNS

a pattern to use while matching hosts in DNS

Note: Use the pattern 'all' to turn off the hostname filter.

default: undef

=item verbose

Print everything.

Note: If both Quiet and Verbose mode are used simultaneously, they cancel each other out.

default: 0

=back

Note: The variables missing defaults above are required for Netsync to operate.

=head3 Example

=over 4

 Netsync::configure(
     'Table'          => 'assets',
     'DeviceField'    => 'SERIAL_NUMBER',
     'InterfaceField' => 'PORT',
     'InfoFields'     => ['BLDG','ROOM','JACK'],
 );

=back

=cut

sub configure {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 4;
    my ($Netsync,$SNMP,$DB,$DNS) = @_;
    
    $config{$_} = $Netsync->{$_} foreach keys %$Netsync;
    
    my $success = 1;
    unless (Netsync::Configurator::SNMP::configure($SNMP,[
        'IF-MIB','ENTITY-MIB',                                # standard
        'CISCO-STACK-MIB',                                    # Cisco
        'FOUNDRY-SN-AGENT-MIB','FOUNDRY-SN-SWITCH-GROUP-MIB', # Brocade
        'SEMI-MIB', #XXX 'HP-SN-AGENT-MIB'                         # HP
    ])) {
        warn 'Netsync::Configurator::SNMP misconfiguration';
        $success = 0;
    }
    if (defined $DB) {
        unless (Netsync::Configurator::DB::configure($DB)) {
            warn 'Netsync::Configurator:DB misconfiguration';
            $success = 0;
        }
    }
    if (defined $DNS) {
        unless (defined Netsync::Configurator::DNS::configure($DNS)) {
            warn 'Netsync::Configurator::DNS misconfiguration';
            $success = 0;
        }
    }
    return $success;
}


sub probe {
    my (@nodes) = @_;
    
    my $serial_count = 0;
    foreach my $node (@nodes) {
        
        my ($session,$info) = SNMP_Info $node->{'ip'};
        if (defined $info) {
            $node->{'session'} = $session;
            $node->{'info'}    = $info;
        }
        else {
            note ($config{'NodeLog'},node_string ($node).' inactive');
            say node_string ($node).' inactive' if $config{'verbose'};
            next;
        }
        
        { # Process a newly discovered node.
            my $serial2if2ifName = device_interfaces ($node->{'info'}->vendor,$node->{'session'});
            if (defined $serial2if2ifName) {
                my @serials = keys %$serial2if2ifName;
                note ($config{'NodeLog'},node_string ($node).' '.join (' ',@serials));
                initialize_node ($node,$serial2if2ifName);
                $serial_count += @serials;
            }
            else {
                note ($config{'NodeLog'},node_string ($node).' no devices detected');
                next;
            }
        }
        
        node_dump $node if $config{'verbose'};
    }
    return $serial_count;
}


=head2 discover [$nodes]

search the network for active nodes

=head3 Arguments

=head4 [C<$nodes>]

an $ip => $node hash

=head3 Example

=over 4

=item C<my $nodes = discover;>

=back

=cut

sub discover {
    warn 'too many arguments' if @_ > 3;
    my ($node_list,$host_pattern,$nodes) = @_;
    $node_list    //= '-'; #/#XXX
    $host_pattern //= ''; #/#XXX : probably not right!
    $nodes        //= {}; #/#XXX
    
    unless ($config{'quiet'}) {
        print 'discovering';
        print ' (using '.((defined $config{'use_DNS'})  ? 'DNS'   :
                          ($config{'node_list'} eq '-') ? 'STDIN' : $config{'node_list'}).')...';
    }
    print (($config{'verbose'}) ? "\n" : (' 'x$config{'NodeOrder'}).'0') unless $config{'quiet'};
    
    my @zone;
    { # Retrieve network nodes from file, pipe, or DNS (-D).
        if (defined $config{'use_DNS'}) {
            my $resolver = DNS;
            $resolver->print if $config{'verbose'};
            $config{'use_DNS'} = '([^.]+)' if $config{'use_DNS'} eq 'all';
            foreach my $record ($resolver->axfr) {
                push (@zone,$record->string) if $record->name =~ /^($config{'use_DNS'})\./;
            }
        }
        else {
            if ($config{'node_list'} eq '-') {
                chomp (@zone = <>);
            }
            else {
                open (my $node_list,'<',$config{'node_list'});
                chomp (@zone = <$node_list>);
                close $node_list;
            }
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
                
                note ($config{'Probe1Cache'},$_,0,'>') if $config{'probe_level'} > 0;
                
                unless ($config{'quiet'} or $config{'verbose'}) {
                    print  "\b"x$config{'NodeOrder'};
                    printf ('%'.$config{'NodeOrder'}.'d',scalar keys %$nodes);
                }
            }
        }
    }
    
    unless ($config{'quiet'}) {
        my $node_count = scalar keys %$nodes;
        print $node_count if $config{'verbose'};
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




################################################################################




sub synchronize {
    warn 'too few arguments' if @_ < 3;
    my ($nodes,$recognized,@rows) = @_;
    
    my $conflict_count = 0;
    foreach my $row (@rows) {
        my $serial = uc $row->{$config{'DeviceField'}};
        my $ifName = $row->{$config{'InterfaceField'}};
        
        my $node = $recognized->{$serial};
        unless (defined $node) {
            my $device = recognize_device ($nodes,$serial);
            unless (defined $device) {
                note ($config{'DeviceLog'},$serial.' unidentified');
                say $serial.' unidentified' if $config{'verbose'};
                next;
            }
            $recognized->{$serial} = $node = $device->{'node'};
            note ($config{'DeviceLog'},$serial.' @ '.$node->{'ip'}.' ('.$node->{'hostname'}.')');
        }
        
        my $device = $node->{'devices'}{$serial};
        if ($config{'auto_match'} and not defined $device->{'interfaces'}{$ifName}) {
            foreach (sort keys %{$device->{'interfaces'}}) {
                if (/[^0-9]$ifName$/) {
                    $ifName = $row->{$config{'InterfaceField'}} = $_;
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
                    foreach my $field (@{$config{'InfoFields'}}) {
                        $interface->{'info'}{$field} = $row->{$field};
                    }
                    
                    interface_dump $interface if $config{'verbose'};
                }
            }
            else {
                my $empty_field_count = 0;
                foreach my $field (@{$config{'InfoFields'}}) {
                    ++$empty_field_count unless $row->{$field} =~ /[\S]+/;
                }
                if ($empty_field_count < @{$config{'InfoFields'}}) {
                    if ($config{'probe_level'} > 1) {
                        my $note = $serial.','.$ifName;
                        foreach my $field (sort @{$config{'InfoFields'}}) {
                            $note .= ','.($row->{$field} // ''); #/#XXX
                        }
                        note ($config{'UnidentifiedCache'},$note,0);
                    }
                }
                else {
                    if ($config{'verbose'}) {
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
                        my $ifName = $row->{$config{'InterfaceField'}};
                        given ($conflict) {
                            my $suffix = $serial.' at '.$ip.' ('.$node->{'hostname'}.').';
                            default {
                                note ($config{'AlertLog'},'Resolution of an unsupported device conflict ('.$conflict.') has been attempted.');
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
                                            foreach my $field (@{$config{'InfoFields'}}) {
                                                $choices[0] .= ', ' unless $choices[0] eq '(old) ';
                                                $choices[1] .= ', ' unless $choices[1] eq '(new) ';
                                                $choices[0] .= $interface->{'info'}{$field};
                                                $choices[1] .= $row->{$field};
                                            }
                                            $new = (choose ($message,\@choices) eq $choices[1]);
                                        }
                                        else {
                                            say 'Duplicate interface ('.$ifName.') on '.$suffix if $config{'verbose'};
                                            
                                        }
                                        if ($new) {
                                            $interface->{'info'}{$_} = $row->{$_} foreach @{$config{'InfoFields'}};
                                        }
                                    }
                                    default {
                                        note ($config{'AlertLog'},'Resolution of an unsupported interface conflict ('.$conflict.') has been attempted.');
                                    }
                                }
                            }
                            delete $interface->{'conflicts'}{$conflict};
                        }
                        delete $interface->{'conflicts'};
                    }
                    else {
                        my $initialized = 0;
                        unless ($config{'probe_level'} < 2 or $auto) {
                            say 'An unrecognized interface ('.$ifName.') has been detected on '.$serial.' at '.$ip.' ('.$node->{'hostname'}.') that is not present in the database.';
                            if (ask 'Would you like to initialize it now?') {
                                say 'An interface ('.$ifName.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                                foreach my $field (@{$config{'InfoFields'}}) {
                                    print ((' 'x$config{'Indent'}).$field.': ');
                                    $interface->{'info'}{$field} = <>;
                                }
                                $interface->{'recognized'} = $initialized = 1;
                            }
                        }
                        note ($config{'UnrecognizedLog'},$ip.' ('.$node->{'hostname'}.') '.$serial.' '.$ifName) unless $initialized;
                    }
                }
            }
            else {
                my $initialized = 0;
                unless ($config{'probe_level'} < 2 or $auto) {
                    say 'An unrecognized device ('.$serial.') has been detected at '.$ip.' ('.$node->{'hostname'}.') that is not present in the database.';
                    if (ask 'Would you like to initialize it now?') {
                        open (STDIN,'<',POSIX::ctermid); #XXX
                        foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                            my $interface = $device->{'interfaces'}{$ifName};
                            say 'An interface ('.$ifName.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                            foreach my $field (@{$config{'InfoFields'}}) {
                                print ((' 'x$config{'Indent'}).$field.': ');
                                chomp ($interface->{'info'}{$field} = <STDIN>);
                            }
                        }
                        $device->{'recognized'} = $initialized = 1;
                    }
                }
                note ($config{'UnrecognizedLog'},$ip.' ('.$node->{'hostname'}.') '.$serial) unless $initialized;
            }
        }
    }
}


=head2 identify $nodes

a list of nodes to synchronize

=head3 Arguments

=head4 C<$nodes>

an $ip => $node hash

=head3 Example

=over 4

=item C<identify $nodes;>

=back

=cut

sub identify {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$data) = @_;
    
    my $fields = $config{'DeviceField'}.','.$config{'InterfaceField'};
    $fields .= ','.join (',',sort @{$config{'InfoFields'}});
    
    print (($config{'verbose'}) ? "\n" : (' 'x$config{'NodeOrder'}).'0') unless $config{'quiet'};
    
    
    
    { # Retrieve node interfaces from database.
        
        my $data;
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
                push (@$data,$entry);
            }
            
            close $db;
        }
        else {
            my $db = DB;
            my $query = $db->prepare('SELECT '.$fields.' FROM '.$config{'Table'});
            $query->execute;
            $data = $query->fetchall_arrayref({});
            $db->disconnect;
        }
        
        unless ($options{'quiet'}) {
            print 'identifying';
            print ' (using '.($options{'use_CSV'} // $config{'DBMS'}).')...'; #/#XXX
        }
        
        
    }
    
    
    
    note ($config{'UnidentifiedCache'},$fields,0,'>') if $config{'probe_level'} > 1;
    
    my $conflict_count = 0;
    {
        my %recognized; # $recognized{$serial} == $node
        
        foreach my $row (@$data) {
            my $valid = [
                $config{'DeviceField'},
                $config{'InterfaceField'},
            ];
            my $invalid = 0;
            foreach my $field (@$valid) {
                ++$invalid and last unless defined $row->{$field} and $row->{$field} =~ /[\S]+/;
            }
            next if $invalid;
            
            $conflict_count += synchronize ($nodes,\%recognized,$row);
            
            unless ($config{'quiet'} or $config{'verbose'}) {
                print  "\b"x$config{'NodeOrder'};
                printf ('%'.$config{'NodeOrder'}.'d',scalar keys %recognized);
            }
        }
        
        unless ($config{'quiet'}) {
            print scalar keys %recognized if $config{'verbose'};
            print ' recognized';
            print ' ('.$conflict_count.' conflicts)' if $conflict_count > 0;
            print "\n";
        }
    }
    
    { # Resolve conflicts.
        my $auto = ($conflict_count > 0);
        my $question = 'Do you want to resolve conflicts now';
        $question .= ($conflict_count > 0) ? '?' : ' (if any)?' ;
        $auto = (not ask $question) unless $config{'quiet'};
        resolve_conflicts ($nodes,$auto);
    }
    
    if ($config{'probe_level'} > 1) {
        note ($config{'Probe2Cache'},$fields,0,'>');
        foreach my $ip (sort keys %$nodes) {
            my $node = $nodes->{$ip};
            foreach my $serial (sort keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    
                    my $note = $serial.','.$ifName;
                    foreach my $field (sort @{$config{'InfoFields'}}) {
                        $note .= ','.($interface->{'info'}{$field} // ''); #/#XXX
                    }
                    note ($config{'Probe2Cache'},$note,0);
                }
            }
        }
    }
}




################################################################################




=head2 update $nodes

push information to interfaces

=head3 Arguments

=head4 C<$nodes>

an $ip => $node hash

=head3 Example

=over 4

=item C<update $nodes;>

                           Table
 ---------------------------------------------------------
 |  DeviceField  |  InterfaceField  |  InfoFields...     |
 ---------------------------------------------------------           =============
 |   (serial)    |     (ifName)     |(interface-specific)|   --->    || SyncOID ||
 |                          ...                          |           =============
 ---------------------------------------------------------                (device)

=back

=cut

sub update {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    unless ($config{'quiet'}) {
        print 'updating...';
        print (($config{'verbose'}) ? "\n" : (' 'x$config{'NodeOrder'}).'0');
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
                my $error = SNMP_set ($config{'SyncOID'},$interface->{'IID'},$update,$node->{'session'});
                unless ($error) {
                    $update =~ s/[\n]/,/g;
                    $update =~ s/[\s]+//g;
                    $update =~ s/:,/:(empty),/g;
                    note ($config{'UpdateLog'},$note.' '.$update);
                    ++$successful_update_count;
                    
                    unless ($config{'quiet'}) {
                        if ($config{'verbose'}) {
                            interface_dump $interface;
                        }
                        else {
                            print  "\b"x$config{'NodeOrder'};
                            printf ('%'.$config{'NodeOrder'}.'d',$successful_update_count);
                        }
                    }
                }
                else {
                    note ($config{'UpdateLog'},$note.' error: '.$error);
                    ++$failed_update_count;
                    
                    if ($config{'verbose'}) {
                        say interface_string ($interface).' failed';
                        say ((' 'x$config{'Indent'}).$error);
                    }
                }
            }
        }
    }
    
    unless ($config{'quiet'}) {
        print $successful_update_count if $config{'verbose'};
        print ' successful';
        print ' ('.$failed_update_count.' failed)' if $failed_update_count > 0;
        print "\n";
    }
}
