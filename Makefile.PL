use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'App::Netsync',
    AUTHOR           => 'dmtucker@ucsc.edu',
    VERSION_FROM     => 'lib/App/Netsync.pm',
    ABSTRACT_FROM    => 'lib/App/Netsync.pm',
    LICENSE          => 'Perl_5',
    MIN_PERL_VERSION => '5.006',
    EXE_FILES        => ['script/netsync'],
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
        # App::Netsync
        'DBI'            => 1.622,
        'Net::DNS'       => 0.66,
        'Text::CSV'      => 1.32,
        # App::Netsync::Configurator
        'Config::Simple' => 4.58,
        # App::Netsync::Network
        'SNMP'           => 5.0702,
        'SNMP::Info'     => 3.05,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'App-Netsync-*' },
);
