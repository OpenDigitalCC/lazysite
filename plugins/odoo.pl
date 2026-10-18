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
                default => '30',
                note    => 'How long one call to Odoo may take before it is given up and '
                    . 'the page told so.' },
            { key => 'odoo_max_kb', label => 'Largest answer accepted (KB)', type => 'text',
                default => '2048',
                note    => 'An answer over this is refused by name rather than read.' },
            { key => 'odoo_allow_writes', label => 'Allow writes', type => 'boolean',
                default => 'false',
                note    => 'Off: write operations can plan but never apply. Odoo\'s own '
                    . 'rights for the connection user still decide what an apply may do.' },
            { key => 'odoo_ca_file', label => 'CA bundle for the Odoo connection (file path)', type => 'text',
                note => 'Leave blank unless your Odoo is behind a certificate from a private '
                    . 'authority - the usual case for an internal Odoo reached over https:// to its '
                    . 'private name. A full path to a PEM file holding that authority\'s certificate; '
                    . 'it must be readable by the web server\'s user. It is used for the connection to '
                    . 'Odoo only: the rest of the server, and every other site on it, keeps the system '
                    . 'certificate store. Verification stays on.' },
            { key => 'odoo_remember_device', label => 'Offer "remember this device" at the two-factor step', type => 'boolean',
                default => 'false',
                note => 'Off: a person with two-factor authentication in Odoo is asked for the '
                    . 'code at every sign-in. On: the code step offers Odoo\'s own "don\'t ask '
                    . 'again on this device", and the browser keeps Odoo\'s device cookie (HttpOnly, '
                    . 'Secure, this site only) for as long as Odoo trusts it. Leave it off where a '
                    . 'browser is shared: whoever is signed in is responsible for that device. '
                    . 'Needs OOM 0.27 or later and an https:// site.' },
            { key => 'odoo_identity_ttl', label => 'Identity cookie lifetime (seconds)', type => 'text',
                default => '900',
                note => 'How long a page may show who a signed-in person is in Odoo before it is '
                    . 'asked of Odoo again (60 to 86400). Presentation only: never what a person '
                    . 'may do.' },
            { key => 'odoo_site_signin', label => 'The Odoo sign-in is the site sign-in', type => 'boolean',
                default => 'false',
                note => 'Off (the default): nothing changes. On: a person who signs in to Odoo through '
                    . 'this site (password, and the authenticator code where Odoo asks) is signed in to the '
                    . 'site as odoo:<their login>. No lazysite account is made or needed, and a person '
                    . 'disabled in Odoo cannot sign in. Pages show "Signed in as" with a sign-out that ends '
                    . 'the Odoo session too. Needs a secured site (a group that grants manager access) and '
                    . 'OOM 0.33 or later for groups.' },
            { key => 'odoo_group_map', label => 'Odoo groups that become site groups', type => 'text',
                validate => 'Lazysite::Odoo::SiteSignin::validate_group_map',
                note => 'Only with the Odoo sign-in as the site sign-in. Comma separated '
                    . '<Odoo group xml id> = <site group>, for example '
                    . 'sales_team.group_sale_salesman = sales, base.group_user = staff. Odoo is asked, as '
                    . 'the person, whether they hold each (at most 50); the held ones become site groups '
                    . 'that page access and file ACLs read. A site group that carries any capability '
                    . '(the manager, the API, anything on the Groups page) is refused by name: a person '
                    . 'signed in through Odoo is never given manager rights.' },
            { key => 'odoo_packs', label => 'Extra operation packs', type => 'text',
                note => 'Leave blank unless you have installed an extra OOM operation pack. '
                    . 'An operation pack is a set of named Odoo operations (list, plan, apply); '
                    . 'OOM ships its own. Name each extra pack by its Perl namespace, comma '
                    . 'separated (for example Example::Odoo::Ops), and its operations become '
                    . 'callable by name from pages and agents beside OOM\'s.' },
            { key => 'odoo_daemon', label => 'Resident OOM (oomd)', type => 'text',
                default => 'off',
                note => 'off, on or required. On: the Odoo daemon extension\'s companion, oomd, a resident OOM that keeps OOM, '
                    . 'the operations, the sign-in and the TLS connection loaded, so a call takes tens of milliseconds '
                    . 'instead of most of a second. It runs under lazysited, so the daemon extension must be enabled '
                    . 'too, and needs the odoo-oom-tools package (oomd). If it is not running a call runs in-process '
                    . 'as before, slower and recorded as such. Required: the same, but a call is refused when the '
                    . 'daemon is not running, instead of falling back.' },
            { key => 'odoo_daemon_workers', label => 'Resident OOM workers', type => 'text',
                default => '4',
                note => 'How many requests oomd serves at once (1 to 64). Set it to match the number of workers '
                    . 'your Odoo runs, which lazysite cannot read from Odoo.' },
            { key => 'odoo_pack_dirs', label => 'Operation pack directories', type => 'text',
                note => 'Leave blank unless this site carries its own OOM operation packs. A colon '
                    . 'separated list of full paths, each a directory that holds pack directories '
                    . '(each with a pack.yaml), for example /var/www/example/lazysite/odoo-packs. '
                    . 'A pack is code that runs as this site, so a directory must exist and lie '
                    . 'under this site\'s own tree, or be /usr/share/odoo-oom/packs; any other is '
                    . 'refused by name. A pack\'s operations are named pack.operation and bind '
                    . 'like any other.' },
        ],

        owns => {
            config_keys =>
                [qw(odoo_url odoo_db odoo_login odoo_timeout odoo_max_kb odoo_allow_writes odoo_ca_file odoo_remember_device odoo_identity_ttl odoo_site_signin odoo_group_map odoo_packs odoo_pack_dirs odoo_daemon odoo_daemon_workers)],

            # NO `storage`, deliberately. lazysite/odoo/ holds the connection
            # user's key and plans carrying Odoo's own records; a site package
            # carries declared storage to another site, and neither belongs
            # there.
            # The page endpoint (SM411: it verifies its own caller).
            endpoints => ['lazysite-odoo.pl'],

            deps => ['Odoo::Ops (libodoo-oom-perl >= 0.03)'],
        },

        # SM1164 D1: a config save rewrites the daemon's config and tells the daemon.
        on_save => 'daemon-refresh',
        actions => [
            { id => 'status', label => 'Status', run => 'action', read => 1 },
            { id => 'daemon-refresh', label => 'Refresh the resident OOM', run => 'action', hidden => JSON::PP::true() },
        ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1 if $argv[$i] eq '--describe';
        $opt{status} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'status';
        $opt{refresh} = 1 if $argv[$i] eq '--action' && ( $argv[ $i + 1 ] // '' ) eq 'daemon-refresh';
        $opt{status}  = 1                     if $argv[$i] eq '--scan';
        $opt{docroot} = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    if ( $opt{refresh} ) {
        print encode_json( refresh( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }
    if ( $opt{status} ) {
        print encode_json( status( $opt{docroot} // $ENV{DOCUMENT_ROOT} // '' ) );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe | --action status --docroot DIR' } );
    return 1;
}

# SM1164 D1: the on_save hook. The daemon's config is written from the saved
# config (or removed when odoo_daemon is off) and a running daemon is sent
# SIGHUP. Reports; never fails the save.
sub refresh {
    my ($docroot) = @_;
    my $have = eval { require Lazysite::Odoo::Daemon; 1 };
    return { ok => 0, error => 'the lazysite modules could not be loaded' } unless $have;
    my $r = Lazysite::Odoo::Daemon::refresh($docroot);
    return { ok => $r->{ok} ? 1 : 0, ( $r->{ok} ? () : ( error => $r->{error} ) ), changed => $r->{changed} ? 1 : 0 };
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
