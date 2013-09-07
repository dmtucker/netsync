#!/usr/bin/perl

package Toolbox::Networker;

require Exporter;
@ISA = (Exporter);
@EXPORT = (
            'initialize_node','initialize_device','initialize_interface',
            'node_string'    ,'device_string'    ,'interface_string',
            'node_dump'      ,'device_dump'      ,'interface_dump',
                             ,'recognize_device' ,'recognize_interface',
          );

use feature 'say';


use Toolbox::FileManager


our $VERSION = '1.0.0';
my $indent = 4; #XXX




sub initialize_node {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($node,$serial2if2ifName) = @_;
    
    foreach my $serial (keys %$serial2if2ifName) {
        initialize_device ($node,$serial,$serial2if2ifName->{$serial});
    }
    return $node;
}




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


1;
