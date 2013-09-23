use Module::Build;

# mv doc share
# cp src/netsync.pl bin/netsync
# chmod +x bin/netsync

my $Netsync = Module::Build->new(
    'module_name'    => 'Netsync.pm',
    'dist_author'    => 'David Tucker <dmtucker@ucsc.edu>',
    'license'        => 'gpl',
    'requires'       => {
        'perl'           => '5.12.4',
        'Config::Simple' => '4.59',
        'DBI'            => '1.623',
        'Regexp::Common' => '2013031301',
        'SNMP::Info'     => '1.32',
    'auto_features'  => {
        'domain_support' => {
            'description' => 'Interface with the Domain Name System',
            'requires'    => {
                'Net::DNS' => '0.72',
            },
        },
        'oracle_support' => {
            'description' => 'Interface with Oracle databases',
            'requires' => {
                'DBD::Oracle' => '1.9_3',
            },
        },
    },
);
$Netsync->create_build_script;
