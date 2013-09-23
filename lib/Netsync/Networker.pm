#!/usr/bin/perl

package Netsync::Networker;

require Exporter;
@ISA = (Exporter);
@EXPORT = (
            'initialize_node','initialize_device','initialize_interface',
            'node_string'    ,'device_string'    ,'interface_string',
            'node_dump'      ,'device_dump'      ,'interface_dump',
                             ,'recognize_device' ,'recognize_interface',
                             ,'device_interfaces',
          );

use feature 'say';


=head1 NAME

Netsync::Networker - methods for manipulating netsync's internal view of a network

=head1 SYNOPSIS

C<use Netsync::Networker;>

=cut


our $VERSION = '0.2.0';
my $indent = 4; #XXX


=head1 DESCRIPTION

This module is responsible for for manipulating an internal view of a network.

=head1 METHODS

=head2 initialize_node ($node,$serial2if2ifName)

initialize a new network node

=head3 Arguments

=head4 C<$node>

the node to initialize

C<$node>

 {
   'devices'  => {
                   $serial => $device,
                 },
   'hostname' => SCALAR,
   'info'     => SNMP::Info,
   'ip'       => SCALAR,
   'session'  => SNMP::Session,
 }

=head4 C<$serial2if2ifName>

a mapping of interfaces to devices (see device_interfaces)

=head3 Example

 initialize_node ($node,device_interfaces ('cisco',SNMP $node->{'ip'}));

=cut

sub initialize_node {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($node,$serial2if2ifName) = @_;
    
    foreach my $serial (keys %$serial2if2ifName) {
        initialize_device ($node,$serial,$serial2if2ifName->{$serial});
    }
    return $node;
}


=head2 initialize_device ($node,$serial,$if2ifName)

the device to initialize

C<$device>

 {
   'conflicts'  => { # This key exists during the identification stage only.
                     $conflict => ARRAY,
                   },
   'interfaces' => {
                     $ifName => $interface,
                   },
   'node'       => $node,
   'recognized' => SCALAR,
   'serial'     => $serial,
 }

=head3 Arguments

=head4 C<$node>

the node to add a new device to

=head4 C<$serial>

the serial number (unique identifier) of the new device  (see initialize_node)

=head4 C<$if2ifName>

a mapping of SNMP interface IIDs to interface names (see device_interfaces)

=head3 Example

 $serial2if2ifName = device_interfaces ($node->{'info'}->vendor,$node->{'session'});
 initialize_device ($node,$_,$serial2if2ifName->{$_}) foreach keys $serial2if2ifName;

=cut

sub initialize_device {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 3;
    my ($node,$serial,$if2ifName) = @_;
    $if2ifName //= {}; #/#XXX
    
    $serial = uc $serial;
    $node->{'devices'}{$serial}{'serial'} = $serial;
    my $device = $node->{'devices'}{$serial};
    $device->{'node'} = $node;
    foreach my $if (keys %$if2ifName) {
        initialize_interface ($device,$if2ifName->{$if},$if);
    }
    $device->{'recognized'} = 0;
    return $device;
}


=head2 initialize_interface ($device,$ifName,$IID[,$fields])

the interface to initialize

C<$interface>

 {
   'conflicts'  => { # This key exists during the identification stage only.
                     'duplicate' => ARRAY,
                   },
   'device'     => $device,
   'ifName'     => $ifName,
   'IID'        => SCALAR,
   'info'       => {
                     $field => SCALAR,
                   },
   'recognized' => SCALAR,
 }

=head3 Arguments

=head4 C<$device>

the device to add a new interface to

=head4 C<$ifName>

the name of the new interface

=head4 C<$IID>

the IID of the new interface

=head4 [C<$fields>]

interface-specific key-value pairs

=head3 Example

 initialize_interface ($device,$if2ifName->{$_},$_) foreach keys %$if2ifName;

=cut

sub initialize_interface { #XXX
    warn 'too few arguments'  if @_ < 3;
    warn 'too many arguments' if @_ > 4;
    my ($device,$ifName,$IID,$fields) = @_;
    $fields //= {}; #/#XXX
    
    $device->{'interfaces'}{$ifName}{'ifName'} = $ifName;
    my $interface = $device->{'interfaces'}{$ifName};
    $interface->{'device'}     = $device;
    $interface->{'IID'}        = $IID;
    $interface->{'info'}{$_}   = $fields->{$_} foreach keys %$fields;
    $interface->{'recognized'} = (scalar keys %$fields > 0) ? 1 : 0;
    return $interface;
}




################################################################################







=head2 node_string @nodes

converts $node structures to strings

=head3 Arguments

=head4 C<@nodes>

an array of nodes to stringify

=head3 Example

=over 4

=item C<say node_string $node;>

 > 10.0.0.1 (host1)

=back

=cut

sub node_string {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    my @node_strings;
    foreach my $node (@nodes) {
        my $node_string;
        if (defined $node->{'ip'} and defined $node->{'hostname'}) {
            $node_string = $node->{'ip'}.' ('.$node->{'hostname'}.')';
        }
        push (@node_strings,$node_string);
    }
    return $node_strings[0] if @node_strings == 1;
    return @node_strings;
}


=head2 device_string @devices

converts $device structures to strings

=head3 Arguments

=head4 C<@devices>

an array of devices to stringify

=head3 Example

=over 4

=item C<say device_string $device;>

 > 1A2B3C4D5E6F at 10.0.0.1 (host1)

=back

=cut

sub device_string {
    warn 'too few arguments' if @_ < 1;
    my (@devices) = @_;
    
    my @device_strings;
    foreach my $device (@devices) {
        my $device_string;
        if (defined $device->{'serial'} and defined $device->{'node'}) {
            $device_string = $device->{'serial'}.' at '.node_string $device->{'node'};
        }
        push (@device_strings,$device_string);
    }
    return $device_strings[0] if @device_strings == 1;
    return @device_strings;
}


=head2 interface_string @interfaces

converts $interface structures to strings

=head3 Arguments

=head4 C<@interfaces>

an array of devices to stringify

=head3 Example

=over 4

=item C<say interface_string $interface;>

 > ethernet1/1/1 (1001) on 1A2B3C4D5E6F at 10.0.0.1 (host1)

=back

=cut

sub interface_string {
    warn 'too few arguments' if @_ < 1;
    my (@interfaces) = @_;
    
    my @interface_strings;
    foreach my $interface (@interfaces) {
        my $interface_string;
        if ($interface->{'ifName'} // $interface->{'IID'} // $interface->{'device'} // 0) { #/#XXX
            $interface_string  = $interface->{'ifName'}.' ('.$interface->{'IID'}.')';
            $interface_string .= ' on '.device_string $interface->{'device'};
        }
        push (@interface_strings,$interface_string);
    }
    return $interface_strings[0] if @interface_strings == 1;
    return @interface_strings;
}




################################################################################







=head2 node_dump @nodes

prints a node structure

=head3 Arguments

=head4 C<@nodes>

an array of nodes to print

=head3 Example

=over 4

=item C<node_dump $node>

 > 10.0.0.1 (host1)
 >   1 device
 >   # interface(s)
 >   vendor model
 >   1A2B3C4D5E6F
 > 1 node, 1 device

Z<>

 > 10.0.0.2 (host2)
 >   3 devices
 >   # interface(s)
 > 1 node, 3 devices (1 stack)

=back

=cut

sub node_dump {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    foreach my $node (@nodes) {
        say node_string $node;
        
        my $device_count = 0;
        if (defined $node->{'devices'}) {
            $device_count = scalar keys %{$node->{'devices'}};
            
            my ($recognized_device_count,$interface_count,$recognized_interface_count) = (0,0,0);
            foreach my $serial (keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                ++$recognized_device_count if $device->{'recognized'};
                next unless defined $device->{'interfaces'};
                $interface_count += scalar keys %{$device->{'interfaces'}};
                foreach my $ifName (keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    ++$recognized_interface_count if $interface->{'recognized'};
                }
            }
            print ((' 'x$indent).$device_count.' device');
            print 's' if $device_count > 1;
            print ' ('.$recognized_device_count.' recognized)' if $recognized_device_count > 0;
            print "\n";
            print ((' 'x$indent).$interface_count.' interface');
            print 's' if $interface_count > 1;
            print ' ('.$recognized_interface_count.' recognized)' if $recognized_interface_count > 0;
            print "\n";
        }
        
        if (defined $node->{'info'}) {
            my $info = $node->{'info'};
            if ($device_count == 1) {
                #say ((' 'x$indent).$info->class); #XXX
                say ((' 'x$indent).$info->vendor.' '.$info->model);
                say ((' 'x$indent).$info->serial);
            }
        }
    }
    say scalar (@nodes).' nodes' if @nodes > 1;
}


=head2 device_dump @devices

prints a device structure

=head3 Arguments

=head4 C<@devices>

an array of devices to print

=head3 Example

=over 4

=item C<device_dump $device>

 > 1A2B3C4D5E6F at 10.0.0.1 (host1)
 >   # interface(s) (# recognized)

=back

=cut

sub device_dump {
    warn 'too few arguments' if @_ < 1;
    my (@devices) = @_;
    
    foreach my $device (@devices) {
        say device_string $device;
        
        if (defined $device->{'recognized'}) {
            say ((' 'x$indent).(($device->{'recognized'}) ? 'recognized' : 'unrecognized'));
        }
        
        if (defined $device->{'interfaces'}) {
            my $interface_count = scalar keys %{$device->{'interfaces'}};
            my $recognized_interface_count = 0;
            foreach my $ifName (keys %{$device->{'interfaces'}}) {
                my $interface = $device->{'interfaces'}{$ifName};
                ++$recognized_interface_count if $interface->{'recognized'};
            }
            print ((' 'x$indent).$interface_count.' interface');
            print 's' if $interface_count > 1;
            say ' ('.$recognized_interface_count.' recognized)';
        }
    }
    say scalar (@devices).' devices' if @devices > 1;
}


=head2 interface_dump @interfaces

prints an interface structure

=head3 Arguments

=head4 C<@interfaces>

an array of interfaces to print

=head3 Example

=over 4

=item C<interface_dump $interface>

 > ethernet1/1/1 (1001) on 1A2B3C4D5E6F at 10.0.0.1 (host1)
 >   unrecognized
 >   key: value
 >   ...

=back

=cut

sub interface_dump {
    warn 'too few arguments' if @_ < 1;
    my (@interfaces) = @_;
    
    foreach my $interface (@interfaces) {
        say interface_string $interface;
        
        if (defined $interface->{'recognized'}) {
            say ((' 'x$indent).(($interface->{'recognized'}) ? 'recognized' : 'unrecognized'));
        }
        
        if (defined $interface->{'info'}) {
            foreach my $field (sort keys %{$interface->{'info'}}) {
                print ((' 'x$indent).$field.': ');
                say (($interface->{'info'}{$field} =~ /[\S]+/) ? $interface->{'info'}{$field} : '(empty)');
            }
        }
    }
    say scalar (@interfaces).' interfaces' if @interfaces > 1;
}




################################################################################







=head2 recognize_device ($nodes,$serial)

check for a device in a set of nodes

=head3 Arguments

=head4 C<$nodes>

an array of nodes to search

=head4 C<$serial>

a unique device identifier

=head3 Example

=over 4

=item C<my $device = recognize_device ($nodes,'1A2B3C4D5E6F');>

=back

=cut

sub recognize_device {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$serial) = @_;
    $serial = uc $serial;
    
    my $recognition;
    foreach my $ip (keys %$nodes) {
        my $node = $nodes->{$ip};
        if (defined $node->{'devices'}{$serial}) {
            my $device = $node->{'devices'}{$serial};
            $device->{'recognized'} = 1;
            $recognition = $device;
            last;
        }
    }
    return $recognition;
}


=head2 recognize_interface ($devices,$ifName)

check for a interface in a set of devices

=head3 Arguments

=head4 C<$devices>

an array of devices to search

=head4 C<$ifName>

a unique interface identifier

=head3 Example

=over 4

=item C<my $interface = recognize_interface ($devices,'ethernet1/1/1');>

=back

=cut

sub recognize_interface {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($devices,$ifName) = @_;
    
    my $recognition;
    foreach my $serial (keys %$devices) {
        my $device = $devices->{$serial};
        if (defined $device->{'interfaces'}{$ifName}) {
            my $interface = $device->{'interfaces'}{$ifName};
            $interface->{'recognized'} = 1;
            $recognition = $interface;
            last;
        }
    }
    return $recognition;
}


=head2 device_interfaces ($vendor,$session)



=head3 Arguments

=head4 C<$vendor>

a return value of SNMP::Info::vendor

Supported Vendors

=over 5

=item brocade

=item cisco

=item hp

=back

=head4 C<$session>

an SNMP::Session object

=head3 Example

=over 3

=item C<my $serial2if2ifName = device_interfaces ($node-E<gt>{'info'}-E<gt>vendor,$node-E<gt>{'session'});>

C<$serial2if2ifName>

 {
   '1A2B3C4D5E6F' => {
                       '1001' => 'ethernet1/1/1',
                       '1002' => 'ethernet1/1/2',
                       ...
                     },
   '2B3C4D5E6F7G' => {
                       '2001' => 'ethernet2/1/1',
                       '2002' => 'ethernet2/1/2',
                       ...
                     },
   ...
 }

=back

=cut

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
                unless (defined $types->[$i] and defined $ifNames->[$i]) {
                    note (get_config ('general.Log'),'Malformed IF-MIB results have been received.');
                    next;
                }
                $if2ifName{$ifs->[$i]} = $ifNames->[$i] if $types->[$i] =~ /^(?!1|24|53)[0-9]+$/;
                if ($types->[$i] =~ /^(?!1|6|24|53)[0-9]+$/) {
                    note (get_config ('general.Log'),'A foreign ifType ('.$types->[$i].') has been encountered on interface '.$ifNames->[$i]);
                }
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
                    note (get_config ('general.Log'),'Serial retrieval attempted on an unsupported device vendor ('.$vendor.')');
                }
            }
            foreach my $serial (@$serials) {
                push (@serials,$serial) if $serial !~ /[^[:ascii:]]/;
            }
        }
        if (@serials == 0) {
            note (get_config ('general.Log'),'No serials could be found for a '.$vendor.' device.');
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
                    note (get_config ('general.Log'),'Interface mapping attempted on an unsupported device vendor ('.$vendor.')');
                }
            }
            foreach my $if (keys %if2serial) {
                $serial2if2ifName{$if2serial{$if}}{$if} = $if2ifName{$if};
            }
        }
    }
    return \%serial2if2ifName;
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
