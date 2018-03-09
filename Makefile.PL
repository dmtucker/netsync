use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Netsync',
    AUTHOR           => q{David Tucker <dmtucker@ucsc.edu>},
    VERSION_FROM     => 'lib/Netsync.pm',
    ABSTRACT_FROM    => 'lib/Netsync.pm',
    LICENSE          => 'Perl_5',
    MIN_PERL_VERSION => 5.006,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::CheckManifest' => 0.9,
        'Test::More' => 0,
        'Test::Pod' => 1.22,
    },
    PREREQ_PM => {
        # Core
        'File::Basename' => 2.84,
        'Getopt::Std'    => 1.07,
        'Pod::Usage'     => 1.61,
        'POSIX'          => 1.32,
        'Scalar::Util'   => 1.32,
        # Helpers::Configurator
        'Config::Simple' => 4.58,
        # Netsync
        'DBI'            => 1.622,
        'Net::DNS'       => 0.66,
        'Text::CSV'      => 1.32,
        # Netsync::Network
        'SNMP'           => 5.0702,
        'SNMP::Info'     => 3.05,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Netsync-*' },
);
