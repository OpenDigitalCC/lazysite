#!/usr/bin/perl

# SM747: the Odoo extension - a page uses Odoo through named operations.
#
# A FACILITY, NOT AN APPLICATION. What a page does with Odoo - list stock, take
# an order into a basket, record a timesheet - is an operation pack in OOM
# (libodoo-oom-perl), not code here; lazysite names an operation, binds its
# parameters, renders what it is handed and presents a plan for confirmation.
# The engine is Lazysite::Odoo; this file declares the extension and answers
# --describe and the Status button.
#
# THE DEPENDENCY IS DECLARED WITH ITS PACKAGE AND VERSION, because guessing the
# package from the module name would tell an operator to install
# libodoo-ops-perl, which does not exist. 0.02 is the first deb to carry the
# Ops layer (the 0.01 deb carries the mapper alone - filed to OOM 2026-10-12).

use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    # As the data plugin: find the Lazysite tree beside this script, and leave
    # --describe answerable when it is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'odoo',
        name        => 'Odoo',
        description => 'Pages use an Odoo instance through named operations - '
            . 'listing facts, or planning and applying changes - under a '
            . 'connection user whose rights are set in Odoo. The operations '
            . 'come from OOM operation packs; lazysite holds no Odoo knowledge.',
        version     => '0.1',
        config_file => 'lazysite/odoo.conf',

        # SM409: born disabled, executes only while listed.
        contract => 1,

        config_schema => [
            { key => 'odoo_url', label => 'Odoo address', type => 'text',
                note => 'https:// to any host. Plain http:// is accepted only to this '
                    . 'host (127.0.0.1 or localhost) - never to a private network '
                    . 'address: reach an internal Odoo over https:// to its private name.' },
            { key => 'odoo_db', label => 'Odoo database', type => 'text',
                note => 'The database name on that Odoo instance.' },
            { key => 'odoo_login', label => 'Connection user (Odoo login)', type => 'text',
                note => 'A site-level Odoo account. Its rights are set IN ODOO and are what '
                    . 'bound every operation run through it; lazysite grants it nothing. '
                    . 'Its API key is set separately and never shown.' },
            { key => 'odoo_timeout', label => 'Timeout per call (seconds)', type => 'text',
                default => '30' },
            { key => 'odoo_max_kb', label => 'Largest answer accepted (KB)', type => 'text',
                default => '2048',
                note    => 'An answer over this is refused by name rather than read.' },
            { key => 'odoo_allow_writes', label => 'Allow writes', type => 'boolean',
                default => 'false',
                note    => 'Off: write operations can plan but never apply. Odoo\'s own '
                    . 'rights for the connection user still decide what an apply may do.' },
            { key => 'odoo_packs', label => 'Extra operation packs', type => 'text',
                note => 'Perl namespaces of installed operation packs beyond OOM\'s own, '
                    . 'comma separated.' },
        ],

        owns => {
            config_keys =>
                [qw(odoo_url odoo_db odoo_login odoo_timeout odoo_max_kb odoo_allow_writes odoo_packs)],

            # NO `storage`, deliberately. lazysite/odoo/ holds the connection
            # user's key and plans carrying Odoo's own records; a site package
            # carries declared storage to another site, and neither belongs
            # there.
            # The page endpoint (SM411: it verifies its own caller).
            endpoints => ['lazysite-odoo.pl'],

            deps => ['Odoo::Ops (libodoo-oom-perl >= 0.02)'],
        },

        actions => [ { id => 'status', label => 'Status', run => 'action', read => 1 } ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1 if $argv[$i] eq '--describe';
        $opt{status} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'status';
        $opt{status}  = 1                     if $argv[$i] eq '--scan';
        $opt{docroot} = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    if ( $opt{status} ) {
        print encode_json( status( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe | --action status --docroot DIR' } );
    return 1;
}

# What an operator needs before trusting it: is OOM here and new enough, and is
# the connection configured. REPORTS, never repairs, and never shows the key.
sub status {
    my ($docroot) = @_;
    my %out       = ( ok => 1 );
    my $have      = eval { require Lazysite::Odoo; 1 };
    unless ($have) {
        $out{message} = 'Odoo: the lazysite modules could not be loaded';
        return \%out;
    }
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $docroot;
    my ( $oom, $why ) = Lazysite::Odoo::oom_check();
    $out{oom} = $oom ? 'present' : $why;
    my ( $conn, $cwhy ) = Lazysite::Odoo::connection();
    $out{connection} = $conn ? { url => $conn->{url}, db => $conn->{db}, login => $conn->{login},
        allow_writes => $conn->{allow_writes} } : { problem => $cwhy };
    $out{message} = 'Odoo: '
        . ( !$oom ? $why : !$conn ? "not configured - $cwhy" : "connection user $conn->{login} on $conn->{url}" );
    return \%out;
}

1;
