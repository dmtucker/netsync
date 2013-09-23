#!/usr/bin/perl

package Netsync::Configurator;

require Exporter;
@ISA = (Exporter);
@EXPORT = ( 'discover', 'identify', 'update' );

use autodie;
use strict;

use feature 'say';

use DBI;
use POSIX;
use Regexp::Common;
use Text::CSV;

use Netsync::Configurator;
use Netsync::FileManager;
use Netsync::Networker;
use Netsync::UI;


=head1 NAME

Netsync - network/database utility

=head1 SYNOPSIS

C<use Netsync;>

=cut


our $VERSION = '1.0.0';


=head1 DESCRIPTION

This module is responsible for discovering and synchronizing a network and a database

=head1 METHODS

=cut


sub probe {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    # $settings{'NodeLog'}
    # $options{'verbose'}
    
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
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    $nodes //= {}; #/#XXX
    
    # $settings{'NodeOrder'}
    # $settings{'Probe1Cache'}
    # $options{'use_DNS'}
    # $options{'quiet'}
    # $options{'verbose'}
    # $options{'node_list'}
    # $options{'probe_level'}
    
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




################################################################################




sub synchronize {
    warn 'too few arguments' if @_ < 3;
    my ($nodes,$recognized,@rows) = @_;
    
    # $settings{'DeviceField'}
    # $settings{'InterfaceField'}
    # $settings{'DeviceLog'}
    # $settings{'InfoFields'}
    # $settings{'UnidentifiedCache'}
    # $options{'verbose'}
    # $options{'auto_match'}
    # $options{'probe_level'}
    
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
    
    # $settings{'InterfaceField'}
    # $settings{'InfoFields'}
    # $settings{'Indent'}
    # $settings{'UnrecognizedLog'}
    # $options{'verbose'}
    # $options{'probe_level'}
    
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
                                note (get_config ('general.Log'),'Resolution of an unsupported device conflict ('.$conflict.') has been attempted.');
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
                                        note (get_config ('general.Log'),'Resolution of an unsupported interface conflict ('.$conflict.') has been attempted.');
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
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    # $settings{'DeviceField'}
    # $settings{'InterfaceField'}
    # $settings{'InfoFields'}
    # $settings{'NodeOrder'}
    # $settings{'Table'}
    # $settings{'UnidentifiedCache'}
    # $settings{'Probe2Cache'}
    # $options{'quiet'}
    # $options{'use_CSV'}
    # $options{'verbose'}
    # $options{'probe_level'}
    
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




=head2 update $nodes

push information to interfaces

=head3 Arguments

=head4 C<$nodes>

an $ip => $node hash

=head3 Example

=over 4

=item C<update $nodes;>

=back

=cut

sub update {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    # $settings{'NodeOrder'}
    # $settings{'UpdateLog'}
    # $settings{'Indent'}
    # $options{'quiet'}
    # $options{'verbose'}
    
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
