#!/usr/bin/perl

package Configurator::SNMP;

require Exporter;
@ISA = (Exporter);
@EXPORT = ('SNMP_get1','SNMP_set');

use autodie;
use strict;

use feature 'say';

use Scalar::Util 'blessed';
use SNMP;
use SNMP::Info;


=head1 NAME

Configurator::SNMP - methods for handling SNMP communications

=head1 SYNOPSIS

 use Configurator::SNMP;
 
 Configurator::SNMP::configure({
     'SecName'   => 'your username',
     'SecLevel'  => 'AuthPriv',
     'AuthProto' => 'SHA',
     'AuthPass'  => 'your password',
     'PrivProto' => 'AES',
     'PrivPass'  => 'your private key',
 },[
     'IF-MIB','ENTITY-MIB',  # standard
     'CISCO-STACK-MIB',      # Cisco
     'FOUNDRY-SN-AGENT-MIB', # Brocade
     'SEMI-MIB',             # HP
 ]);
 
 my $ip      = '93.184.216.119';
 my $session = Configurator::SNMP::Session $ip;
 
 my $info1   = Configurator::SNMP::Info $ip;
 my $info2   = Configurator::SNMP::Info $session;
 
 my ($ifNames,$ifIIDs) = SNMP_get1 ([
     ['.1.3.6.1.2.1.31.1.1.1.1' => 'ifName'],
     ['.1.3.6.1.2.1.2.2.1.2'    => 'ifDescr'],
 ],$session);
 
 SNMP_set ('ifAlias',$_,'Vote for Pedro',$session) foreach @$ifIIDs;

=cut


our $VERSION = '1.0.0-alpha';
our %config;
{
    $config{'MIBdir'}          = '/usr/lib/'.(fileparse ($0,"\.[^.]*")).'/mib';
    
    $config{'AuthPass'}        = undef;
    $config{'AuthProto'}       = 'MD5';
    $config{'Community'}       = 'public';
    $config{'Context'}         = undef;
    $config{'ContextEngineId'} = undef;
    $config{'DestHost'}        = undef;
    $config{'PrivPass'}        = undef;
    $config{'PrivProto'}       = 'DES';
    $config{'RemotePort'}      = 161;
    $config{'Retries'}         = 5;
    $config{'RetryNoSuch'}     = 0;
    $config{'SecEngineId'}     = undef;
    $config{'SecLevel'}        = 'noAuthNoPriv';
    $config{'SecName'}         = 'initial';
    $config{'Timeout'}         = 1000000;
    $config{'Version'}         = 3;
}


INIT {
    SNMP::addMibDirs($config{'MIBdir'});
}


=head1 DESCRIPTION

This package is an SNMP framework.

=head1 METHODS

=head2 configure (\%environment,\@MIBs)

=head3 Arguments

=head4 environment

key-value pairs of environment configurations

Available Environment Settings

=over 5

=item MIBdir

the location of necessary MIBs

default: F</usr/lib/E<lt>script nameE<gt>/mib>

=back

Note: See the documentation for SNMP and SNMP::Info on CPAN for more information.
      Most constructor options are supported.

=head4 MIBs

a list of MIBs to load

=head3 Example

 Configurator::SNMP::configure({
     'SecName'   => 'your username',
     'SecLevel'  => 'AuthPriv',
     'AuthProto' => 'SHA',
     'AuthPass'  => 'your password',
     'PrivProto' => 'AES',
     'PrivPass'  => 'your private key',
 },[
     'IF-MIB','ENTITY-MIB',  # standard
     'CISCO-STACK-MIB',      # Cisco
     'FOUNDRY-SN-AGENT-MIB', # Brocade
     'SEMI-MIB',             # HP
 ]);

=cut

sub configure {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($environment,$MIBs) = @_;
    
    $config{$_} = $environment->{$_} foreach keys %$environment;
    
    my $success = 1;
    foreach my $MIB (@$MIBs) {
        if (defined $MIB) {
            $success = 0 unless defined SNMP::loadModules($MIB);
        }
    }
    SNMP::initMib();
    
    $config{'ContextEngineId'} //= $config{'SecEngineId'}; #/#XXX
    unless (($config{'Version'} < 3) or
            ($config{'SecLevel'} eq 'noAuthNoPriv') or
            ($config{'SecLevel'} eq 'authNoPriv' and defined $config{'AuthPass'}) or
            (defined $config{'AuthPass'} and defined $config{'PrivPass'})) {
        warn 'SNMPv3 configuration is inadequate. See SecLevel, AuthPass, or PrivPass.';
        $success = 0;
    }
    return $success;
}


=head2 Session $ip

returns an SNMP::Session object.

Note: configure needs to be run first!

=head3 Arguments

=head4 ip

an IP address to connect to

=head3 Example

 my $ip      = '93.184.216.119';
 my $session = Configurator::SNMP::Session $ip;

=cut

sub Session {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($ip) = @_;
    
    return SNMP::Session->new(
        'AuthPass'        => $config{'SNMP.AuthPass'},
        'AuthProto'       => $config{'SNMP.AuthProto'},
        'Community'       => $config{'SNMP.Community'},
        'Context'         => $config{'SNMP.Context'},
        'ContextEngineId' => $config{'SNMP.ContextEngineId'},
        'DestHost'        => $ip,
        'PrivPass'        => $config{'SNMP.PrivPass'},
        'PrivProto'       => $config{'SNMP.PrivProto'},
        'RemotePort'      => $config{'SNMP.RemotePort'},
        'Retries'         => $config{'SNMP.Retries'},
        'RetryNoSuch'     => $config{'SNMP.RetryNoSuch'},
        'SecEngineId'     => $config{'SNMP.SecEngineId'},
        'SecLevel'        => $config{'SNMP.SecLevel'},
        'SecName'         => $config{'SNMP.SecName'},
        'Timeout'         => $config{'SNMP.Timeout'},
        'Version'         => $config{'SNMP.Version'},
    );
}


=head2 Info $ip

returns an SNMP::Info object

Note: configure needs to be run first!

=head3 Arguments

=head4 ip

an IP address to connect to OR an SNMP::Session

=head3 Example

 my $ip      = '93.184.216.119';
 my $info1   = Configurator::SNMP::Info $ip;
 
 my $session = Configurator::SNMP::Session $ip;
 my $info2   = Configurator::SNMP::Info $session;

Note: The following snippets are equivalent:

=over 4

=item C<Info $ip;>

=item C<Info Session $ip;>

=back

=cut

sub Info {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($ip) = @_;
    
    my $session = Session $ip;
    my $info = SNMP::Info->new(
        'AutoSpecify' => 1,
        'Session'     => $session,
    );
    return ($session,$info);
}


=head2 SNMP_get1 (\@OIDs,$ip)

attempt to retrieve an OID from a provided list, stopping on success

=head3 Arguments

=head4 OIDs

a list of OIDs to try and retreive

=head4 ip

an IP address to connect to or an SNMP::Session

=head3 Example

 my ($ifNames,$ifIIDs) = SNMP_get1 ([
     ['.1.3.6.1.2.1.31.1.1.1.1' => 'ifName'],
     ['.1.3.6.1.2.1.2.2.1.2'    => 'ifDescr'],
 ],'93.184.216.119');

Note: If ifName is unavailable, ifDescr will be tried.

=cut

sub SNMP_get1 {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($OIDs,$ip) = @_;
    
    my $session = $ip;
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        $session = SNMP $session;
        return undef unless defined $session;
    }
    
    my (@objects,@IIDs);
    foreach my $OID (@$OIDs) {
        my $query = SNMP::Varbind->new([$OID->[0]]);
        while (my $object = $session->getnext($query)) {
            last unless $query->tag eq $OID->[1] and not $session->{'ErrorNum'};
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


=head2 SNMP_set ($OID,$IID,$value,$ip)

attempt to set a new value on a device using SNMP

=head3 Arguments

=head4 OID

the OID to write the value argument to

=head4 IID

the IID to write the value argument to

=head4 value

the value to write to OID.IID

=head4 ip

an IP address to connect to OR an SNMP::Session

=head3 Example

 my ($ifIIDs) = SNMP_get1 ([['.1.3.6.1.2.1.2.2.1.1' => 'ifIndex']],'93.184.216.119');
 
 SNMP_set ('ifAlias',$_,'Vote for Pedro','93.184.216.119') foreach @$ifIIDs;

=cut

sub SNMP_set {
    warn 'too few arguments'  if @_ < 4;
    warn 'too many arguments' if @_ > 4;
    my ($OID,$IID,$value,$ip) = @_;
    
    my $session = $ip;
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        $session = SNMP $session;
        return undef unless defined $session;
    }
    
    my $query = SNMP::Varbind->new([$OID,$IID,$value]);
    $session->set($query);
    return ($session->{'ErrorNum'}) ? $session->{'ErrorStr'} : 0;
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
