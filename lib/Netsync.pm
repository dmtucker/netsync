#!/usr/bin/perl

package Netsync;

use autodie;
use strict;

use feature 'say';
use feature 'switch';

use DBI;
use File::Basename;
use Net::DNS;
use POSIX;
use Regexp::Common;
use Text::CSV;

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
    $config{'Quiet'}             = 0;
    $config{'Verbose'}           = 0;
    
    $config{'DeviceField'}       = undef;
    $config{'InfoFields'}        = undef;
    $config{'InterfaceField'}    = undef;
    
    $config{'DeviceOrder'}         = 4;
    $config{'AlertLog'}          = '/var/log/'.$SCRIPT.'/'.$SCRIPT.'.log';
    $config{'DeviceLog'}         = '/var/log/'.$SCRIPT.'/devices.log';
    $config{'NodeLog'}           = '/var/log/'.$SCRIPT.'/nodes.log';
    $config{'UnidentifiedCache'} = '/var/cache/'.$SCRIPT.'/unidentified.csv';
    $config{'UnrecognizedLog'}   = '/var/log/'.$SCRIPT.'/unrecognized.log';
    $config{'UpdateLog'}         = '/var/log/'.$SCRIPT.'/updates.log';
    $config{'SyncOID'}           = 'ifAlias';
    
    $config{'SNMP'} = undef;
    $config{'DNS'}  = undef;
    $config{'DB'}   = undef;
}


=head1 DESCRIPTION

This package can discover a network and synchronize it with a database.

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

=item NodeLog

where to log all probed nodes

default: F</var/log/E<lt>script nameE<gt>/nodes.log>

=item DeviceOrder

the width of fields specifying node and device counts

default: 4

=item Quiet

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

=item Verbose

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
    unless (Configurator::SNMP::configure($SNMP,[
        'IF-MIB','ENTITY-MIB',                                # standard
        'CISCO-STACK-MIB',                                    # Cisco
        'FOUNDRY-SN-AGENT-MIB','FOUNDRY-SN-SWITCH-GROUP-MIB', # Brocade
        'SEMI-MIB', #XXX 'HP-SN-AGENT-MIB'                         # HP
    ])) {
        warn 'Netsync::Configurator::SNMP misconfiguration';
        $success = 0;
    }
    if (defined $DB) {
        $config{'DB'} = $DB;
        unless (defined $DB->{'Server'}   and defined $DB->{'Port'}     and
                defined $DB->{'DBMS'}     and defined $DB->{'Database'} and
                defined $DB->{'Username'} and defined $DB->{'Password'}) {
            warn 'Database configuration is inadequate. See Server, Port, DBMS, Database, Username, or Password.';
            $success = 0;
        }
    }
    if (defined $DNS) {
        $config{'DNS'} = $DNS;
        unless (defined $DNS->{'domain'}) {
             warn 'DNS configuration is inadequate.';
             $success = 0;
         }
    }
    return $success;
}


=head2 discover [($node_source[,$host_pattern])]

search the network for active nodes

=head3 Arguments

=head4 [node_source]

=head4 [host_pattern]

=head3 Example

=cut


sub probe {
    my (@nodes) = @_;
    
    my $serial_count = 0;
    foreach my $node (@nodes) {
        
        my ($session,$info) = Configurator::SNMP::Info $node->{'ip'};
        if (defined $info) {
            $node->{'session'} = $session;
            $node->{'info'}    = $info;
        }
        else {
            note ($config{'NodeLog'},node_string ($node).' inactive');
            say node_string ($node).' inactive' if $config{'Verbose'};
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
        
        node_dump $node if $config{'Verbose'};
    }
    return $serial_count;
}

sub discover {
    warn 'too many arguments' if @_ > 2;
    my ($node_source,$host_pattern) = @_;
    $node_source  //= 'DNS'; #/#XXX
    $host_pattern //= '[^.]+'; #/#XXX
    
    my $nodes = {};
    
    unless ($config{'Quiet'}) {
        print 'discovering (using '.$node_source.')...';
        print (($config{'Verbose'}) ? "\n" : (' 'x$config{'DeviceOrder'}).'0');
    }
    
    my @zone;
    given ($node_source) {
        when ('DNS') {
            unless (defined $config{'DNS'}) {
                warn 'DNS has not been configured.';
                return undef;
            }
            if (defined $config{'DNS'}{'nameservers'}) {
                $config{'DNS'}{'nameservers'} = (ref $config{'DNS'}{'nameservers'}) ?
                                                     $config{'DNS'}{'nameservers'} :
                                                    [$config{'DNS'}{'nameservers'}];
            }
            if (defined $config{'DNS'}{'searchlist'}) {
                $config{'DNS'}{'searchlist'}  = (ref $config{'DNS'}{'searchlist'}) ?
                                                     $config{'DNS'}{'searchlist'} :
                                                    [$config{'DNS'}{'searchlist'}];
            }
            
            my $resolver = Net::DNS::Resolver->new(%{$config{'DNS'}});
            $resolver->print if $config{'Verbose'};
            push (@zone,$_->string) foreach $resolver->axfr;
        }
        when ('STDIN') {
            chomp (@zone = <>);
        }
        default {
            open (my $node_file,'<',$node_source);
            chomp (@zone = <$node_file>);
            close $node_file;
        }
    }
    
    my ($inactive_node_count,$deployed_device_count,$stack_count) = (0,0,0);
    foreach (@zone) {
        if (/^(?<host>$host_pattern)\.(\S+\.)+\s+(\d+)\s+(\S+)\s+(?:A|AAAA)\s+(?<ip>$RE{'net'}{'IPv4'}|$RE{'net'}{'IPv6'})/) {
            $nodes->{$+{'ip'}}{'ip'} = $+{'ip'};
            my $node = $nodes->{$+{'ip'}};
            $node->{'hostname'} = $+{'host'};
            $node->{'RFC1035'}  = $_;
            
            my $serial_count = probe $node;
            if ($serial_count < 1) {
                ++$inactive_node_count;
                delete $nodes->{$+{'ip'}};
            }
            else {
                $deployed_device_count += $serial_count;
                ++$stack_count if $serial_count > 1;
                
                unless ($config{'Quiet'} or $config{'Verbose'}) {
                    print  "\b"x$config{'DeviceOrder'};
                    printf ('%'.$config{'DeviceOrder'}.'d',scalar keys %$nodes);
                }
            }
        }
    }
    
    unless ($config{'Quiet'}) {
        my $node_count = scalar keys %$nodes;
        print $node_count if $config{'Verbose'};
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




=head2 identify $nodes

=head3 Arguments

=head4 nodes

=head3 Example

=cut

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
                say $serial.' unidentified' if $config{'Verbose'};
                next;
            }
            $recognized->{$serial} = $node = $device->{'node'};
            note ($config{'DeviceLog'},$serial.' @ '.$node->{'ip'}.' ('.$node->{'hostname'}.')');
        }
        
        my $device = $node->{'devices'}{$serial};
        if ($config{'AutoMatch'} and not defined $device->{'interfaces'}{$ifName}) {
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
                    
                    interface_dump $interface if $config{'Verbose'};
                }
            }
            else {
                my $empty_field_count = 0;
                foreach my $field (@{$config{'InfoFields'}}) {
                    ++$empty_field_count unless $row->{$field} =~ /\S+/;
                }
                if ($empty_field_count < @{$config{'InfoFields'}}) {
                    my $note = $serial.','.$ifName;
                    foreach my $field (sort @{$config{'InfoFields'}}) {
                        $note .= ','.($row->{$field} // ''); #/#XXX
                    }
                    note ($config{'UnidentifiedCache'},$note,0);
                }
                else {
                    if ($config{'Verbose'}) {
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
                                            say 'Duplicate interface ('.$ifName.') on '.$suffix if $config{'Verbose'};
                                            
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
                        unless ($auto) {
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
                unless ($auto) {
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

sub identify {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$data_source) = @_;
    $data_source //= 'DB'; #/#XXX
    
    my $fields = $config{'DeviceField'}.','.$config{'InterfaceField'};
    $fields .= ','.join (',',sort @{$config{'InfoFields'}});
    note ($config{'UnidentifiedCache'},$fields,0,'>'); #XXX : how does this work?
    
    unless ($config{'Quiet'}) {
        print 'identifying (using '.$data_source.')...';
        print (($config{'Verbose'}) ? "\n" : (' 'x$config{'DeviceOrder'}).'0');
    }
    
    my @data;
    given ($data_source) {
        when ('DB') {
            unless (defined $config{'DB'}) {
                warn 'A database has not been configured.';
                return undef;
            }
            
            my $DSN = 'dbi:'.$config{'DBMS'};
            $DSN .= ':host='.$config{'Server'};
            $DSN .= ';port='.$config{'Port'};
            $DSN .= ';database='.$config{'Database'};
            if (defined $config{'DB'}{'DSN'}) {
                $config{'DB'}{'DSN'} = (ref $config{'DB'}{'DSN'}) ?
                                            $config{'DB'}{'DSN'} :
                                           [$config{'DB'}{'DSN'}];
                $DSN .= ';'.$_ foreach @{$config{'DB'}{'DSN'}};
            }
            my $db = DBI->connect($DSN,$config{'Username'},$config{'Password'},{
                'AutoCommit'         => $config{'AutoCommit'},
                'PrintError'         => $config{'PrintError'},
                'PrintWarn'          => $config{'PrintWarn'},
                'RaiseError'         => $config{'RaiseError'},
                'ShowErrorStatement' => $config{'ShowErrorStatement'},
                'TraceLevel'         => $config{'TraceLevel'},
            });
            my $query = $db->prepare('SELECT '.$fields.' FROM '.$config{'Table'});
            $query->execute;
            @data = @{$query->fetchall_arrayref({})};
            $db->disconnect;
        }
        default {
            open (my $db,'<',$data_source);
            
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
    }
    
    my $conflict_count = 0;
    {
        my %recognized; # $recognized{$serial} == $node
        
        foreach my $row (@data) {
            my $valid = [
                $config{'DeviceField'},
                $config{'InterfaceField'},
            ];
            my $invalid = 0;
            foreach my $field (@$valid) {
                ++$invalid and last unless defined $row->{$field} and $row->{$field} =~ /\S+/;
            }
            next if $invalid;
            
            $conflict_count += synchronize ($nodes,\%recognized,$row);
            
            unless ($config{'Quiet'} or $config{'Verbose'}) {
                print  "\b"x$config{'DeviceOrder'};
                printf ('%'.$config{'DeviceOrder'}.'d',scalar keys %recognized);
            }
        }
        
        unless ($config{'Quiet'}) {
            print scalar keys %recognized if $config{'Verbose'};
            print ' recognized';
            print ' ('.$conflict_count.' conflicts)' if $conflict_count > 0;
            print "\n";
        }
    }
    
    { # Resolve conflicts.
        my $auto = ($conflict_count > 0);
        my $question = 'Do you want to resolve conflicts now';
        $question .= ($conflict_count > 0) ? '?' : ' (if any)?' ;
        $auto = (not ask $question) unless $config{'Quiet'};
        resolve_conflicts ($nodes,$auto);
    }
}




################################################################################




=head2 update $nodes

push information to interfaces

=head3 Arguments

=head4 nodes

=head3 Example

C<update $nodes;>

                           Table
 ---------------------------------------------------------
 |  DeviceField  |  InterfaceField  |  InfoFields...     |
 ---------------------------------------------------------           =============
 |   (serial)    |     (ifName)     |(interface-specific)|   --->    || SyncOID ||
 |                          ...                          |           =============
 ---------------------------------------------------------                (device)

=cut

sub update {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    unless ($config{'Quiet'}) {
        print 'updating...';
        print (($config{'Verbose'}) ? "\n" : (' 'x$config{'DeviceOrder'}).'0');
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
                    $update =~ s/\n/,/g;
                    $update =~ s/\s+//g;
                    $update =~ s/:,/:(empty),/g;
                    note ($config{'UpdateLog'},$note.' '.$update);
                    ++$successful_update_count;
                    
                    unless ($config{'Quiet'}) {
                        if ($config{'Verbose'}) {
                            interface_dump $interface;
                        }
                        else {
                            print  "\b"x$config{'DeviceOrder'};
                            printf ('%'.$config{'DeviceOrder'}.'d',$successful_update_count);
                        }
                    }
                }
                else {
                    note ($config{'UpdateLog'},$note.' error: '.$error);
                    ++$failed_update_count;
                    
                    if ($config{'Verbose'}) {
                        say interface_string ($interface).' failed';
                        say ((' 'x$config{'Indent'}).$error);
                    }
                }
            }
        }
    }
    
    unless ($config{'Quiet'}) {
        print $successful_update_count if $config{'Verbose'};
        print ' successful';
        print ' ('.$failed_update_count.' failed)' if $failed_update_count > 0;
        print "\n";
    }
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
