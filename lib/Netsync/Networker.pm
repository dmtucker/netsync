#!/usr/bin/perl

package Netsync::Networker;

require Exporter;
@ISA = (Exporter);
@EXPORT = (
            'node_initialize','device_initialize','interface_initialize',
            'node_string'    ,'device_string'    ,'interface_string',
            'node_dump'      ,'device_dump'      ,'interface_dump',
            'node_recognize' ,'device_recognize' ,'interface_recognize',
          );

use feature 'say';
use feature 'switch';

=head1 NAME

Netsync::Networker - methods for manipulating netsync's internal view of a network

=head1 SYNOPSIS

C<use Netsync::Networker;>

=cut


our $VERSION = '0.2.0';

our %config;
{
    $config{'Indent'} = 4;
}


=head1 DESCRIPTION

This module is responsible for for manipulating an internal view of a network.

=head1 METHODS

=head2 node_initialize ($node,$serial2if2ifName)

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

 node_initialize ($node,device_interfaces ('cisco',SNMP $node->{'ip'}));

=cut

sub node_initialize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($node,$serial2if2ifName) = @_;
    
    foreach my $serial (keys %$serial2if2ifName) {
        device_initialize ($node,$serial,$serial2if2ifName->{$serial});
    }
    return $node;
}


=head2 device_initialize ($node,$serial,$if2ifName)

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

the serial number (unique identifier) of the new device  (see node_initialize)

=head4 C<$if2ifName>

a mapping of SNMP interface IIDs to interface names (see device_interfaces)

=head3 Example

 $serial2if2ifName = device_interfaces ($node->{'info'}->vendor,$node->{'session'});
 device_initialize ($node,$_,$serial2if2ifName->{$_}) foreach keys $serial2if2ifName;

=cut

sub device_initialize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 3;
    my ($node,$serial,$if2ifName) = @_;
    $if2ifName //= {}; #/#XXX
    
    $serial = uc $serial;
    $node->{'devices'}{$serial}{'serial'} = $serial;
    my $device = $node->{'devices'}{$serial};
    $device->{'node'} = $node;
    foreach my $if (keys %$if2ifName) {
        interface_initialize ($device,$if2ifName->{$if},$if);
    }
    $device->{'recognized'} = 0;
    return $device;
}


=head2 interface_initialize ($device,$ifName,$IID[,$fields])

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

 interface_initialize ($device,$if2ifName->{$_},$_) foreach keys %$if2ifName;

=cut

sub interface_initialize { #XXX
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
            print ((' 'x$config{'Indent'}).$device_count.' device');
            print 's' if $device_count > 1;
            print ' ('.$recognized_device_count.' recognized)' if $recognized_device_count > 0;
            print "\n";
            print ((' 'x$config{'Indent'}).$interface_count.' interface');
            print 's' if $interface_count > 1;
            print ' ('.$recognized_interface_count.' recognized)' if $recognized_interface_count > 0;
            print "\n";
        }
        
        if (defined $node->{'info'}) {
            my $info = $node->{'info'};
            if ($device_count == 1) {
                #say ((' 'x$config{'Indent'}).$info->class); #XXX
                say ((' 'x$config{'Indent'}).$info->vendor.' '.$info->model);
                say ((' 'x$config{'Indent'}).$info->serial);
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
            say ((' 'x$config{'Indent'}).(($device->{'recognized'}) ? 'recognized' : 'unrecognized'));
        }
        
        if (defined $device->{'interfaces'}) {
            my $interface_count = scalar keys %{$device->{'interfaces'}};
            my $recognized_interface_count = 0;
            foreach my $ifName (keys %{$device->{'interfaces'}}) {
                my $interface = $device->{'interfaces'}{$ifName};
                ++$recognized_interface_count if $interface->{'recognized'};
            }
            print ((' 'x$config{'Indent'}).$interface_count.' interface');
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
            say ((' 'x$config{'Indent'}).(($interface->{'recognized'}) ? 'recognized' : 'unrecognized'));
        }
        
        if (defined $interface->{'info'}) {
            foreach my $field (sort keys %{$interface->{'info'}}) {
                print ((' 'x$config{'Indent'}).$field.': ');
                say (($interface->{'info'}{$field} =~ /[\S]+/) ? $interface->{'info'}{$field} : '(empty)');
            }
        }
    }
    say scalar (@interfaces).' interfaces' if @interfaces > 1;
}




################################################################################




=head2 node_recognize ($nodes,$ip)

check for a node in a set of nodes

=head3 Arguments

=head4 nodes

an array of nodes to search

=head4 ip

the IP address of the node

=head3 Example

C<my $node = node_recognize ($nodes,'93.184.216.119');>

=cut

sub node_recognize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$ip) = @_;
    
    return $nodes->{$ip};
}


=head2 device_recognize ($nodes,$serial)

check for a device in a set of nodes

=head3 Arguments

=head4 C<$nodes>

an array of nodes to search

=head4 C<$serial>

a unique device identifier

=head3 Example

=over 4

=item C<my $device = device_recognize ($nodes,'1A2B3C4D5E6F');>

=back

=cut

sub device_recognize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$serial) = @_;
    $serial = uc $serial;
    
    foreach my $ip (keys %$nodes) {
        my $node = $nodes->{$ip};
        if (defined $node->{'devices'}{$serial}) {
            my $device = $node->{'devices'}{$serial};
            $device->{'recognized'} = 1;
            return $device;
        }
    }
    return undef;
}


=head2 interface_recognize ($devices,$ifName)

check for a interface in a set of devices

=head3 Arguments

=head4 C<$devices>

an array of devices to search

=head4 C<$ifName>

a unique interface identifier

=head3 Example

=over 4

=item C<my $interface = interface_recognize ($devices,'ethernet1/1/1');>

=back

=cut

sub interface_recognize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($devices,$ifName) = @_;
    
    foreach my $serial (keys %$devices) {
        my $device = $devices->{$serial};
        if (defined $device->{'interfaces'}{$ifName}) {
            my $interface = $device->{'interfaces'}{$ifName};
            $interface->{'recognized'} = 1;
            return $interface;
        }
    }
    return undef;
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
