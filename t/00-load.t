#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 5;

BEGIN {
    use_ok( 'Netsync' ) || print "Bail out!\n";
    use_ok( 'Netsync::Network' ) || print "Bail out!\n";
    use_ok( 'Netsync::SNMP' ) || print "Bail out!\n";
    use_ok( 'Helpers::Configurator' ) || print "Bail out!\n";
    use_ok( 'Helpers::Scribe' ) || print "Bail out!\n";
}

diag( "Testing Netsync $Netsync::VERSION, Perl $], $^X" );
