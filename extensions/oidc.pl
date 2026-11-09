#!/usr/bin/perl

# SM1351: SIGN IN THROUGH AN OUTSIDE OPENID CONNECT PROVIDER, WITH ITS GROUPS.
#
# A person signs in at a provider the site trusts - Authentik, Kanidm, Pocket ID,
# Authelia, any OpenID Connect issuer - and the groups the provider holds for them
# become site groups, by a map per provider. No lazysite account is made. The
# engine is Lazysite::Ext::OIDC, in this extension's payload lib; the sign-in endpoint
# is /cgi-bin/lazysite-oidc.pl. Core holds the sessions (SM1369 X4, H-1): this
# extension says which providers are on, which groups a record still holds, and
# what /login offers.
#
#   --describe                              the declaration
#   --action refresh --docroot DIR          fetch each provider's discovery
#   --action status --docroot DIR           what `lazysite check` says
#   --secret NAME --docroot DIR             set a provider's client secret,
#                                           read from standard input

use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    # As the Odoo extension: find the Lazysite tree beside this script, and leave
    # --describe answerable when it is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
    # SM1369 X1: its own module is in its payload lib, beside this file.
    eval { require Lazysite::Extensions; Lazysite::Extensions::add_payload_lib( Cwd::abs_path(__FILE__) ); 1 };
}

exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'oidc',
        name        => 'OpenID Connect sign-in',
        description => 'People sign in through an outside OpenID Connect provider, and the '
            . 'groups the provider holds for them become site groups. Several providers may '
            . 'be trusted at once, each with its own group map. No account is made here.',
        version     => '0.1',
        config_file => 'lazysite/oidc.conf',

        # SM409: born disabled, executes only while listed.
        contract => 1,

        config_schema => [
            { key => 'providers', label => 'Providers', type => 'text', list => ',',
                note => 'The names of the providers this site trusts, comma separated (a lower-case '
                    . 'letter, then letters and digits). Each one\'s issuer, client id, scopes, group '
                    . 'claim, group map and button label are set in lazysite/oidc.conf as '
                    . '<name>.issuer and so on, and its client secret from the command line '
                    . '(extensions/oidc.pl --secret <name>); see /docs/auth. A provider\'s groups may '
                    . 'map to any site group, operators included, and every sign-in is audited with '
                    . 'the groups it granted.' },
        ],

        owns => {
            # The sign-in endpoint: GET only, it verifies nothing of a caller's.
            endpoints => ['lazysite-oidc.pl'],
            hooks     => {
                # SM1369 X4 (H-1): several providers (`instances`), oidc-<name>,
                # whose groups may grant (ruling 186).
                identity_provider => {
                    on           => 'Lazysite::Ext::OIDC::provider_on',
                    still_valid  => 'Lazysite::Ext::OIDC::provider_still_valid',
                    groups       => 'Lazysite::Ext::OIDC::provider_groups',
                    login_option => 'Lazysite::Ext::OIDC::provider_login_option',
                    grants       => 1,
                    instances    => 1,
                },
                # H-4: held to the request kit (t/lint/351), though it takes no body.
                endpoints => [ { script => 'lazysite-oidc.pl' } ],
                # H-6: each provider ready, or refused with its remedy (ruling 206).
                checks => ['Lazysite::Ext::OIDC::check'],
            },
        },

        # Discovery is fetched when the config is saved, and by Refresh.
        on_save => 'refresh',
        actions => [
            { id => 'refresh', label => 'Refresh', run => 'action' },
            { id => 'status',  label => 'Status',  run => 'action', read => 1 },
        ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1                     if $argv[$i] eq '--describe';
        $opt{action}   = $argv[ $i + 1 ] // '' if $argv[$i] eq '--action';
        $opt{action}   = 'status'              if $argv[$i] eq '--scan';
        $opt{secret}   = $argv[ $i + 1 ] // '' if $argv[$i] eq '--secret';
        $opt{docroot}  = $argv[ $i + 1 ] // '' if $argv[$i] eq '--docroot';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $have    = eval { require Lazysite::Ext::OIDC; require Lazysite::Paths; 1 };
    unless ($have) {
        print encode_json( { ok => 0, error => 'the lazysite modules could not be loaded' } );
        return 1;
    }
    if ( defined $opt{secret} ) {
        my $value = <STDIN>;
        my ( $ok, $why ) = Lazysite::Ext::OIDC::set_secret( $docroot, $opt{secret}, $value );
        print encode_json( $ok ? { ok => 1, message => "the client secret of '$opt{secret}' is set" } : { ok => 0, error => $why } );
        print "\n";
        return $ok ? 0 : 1;
    }
    if ( ( $opt{action} // '' ) eq 'refresh' ) {
        print encode_json( Lazysite::Ext::OIDC::refresh($docroot) );
        return 0;
    }
    if ( ( $opt{action} // '' ) eq 'status' ) {
        my $lz = Lazysite::Paths::lazysite_dir($docroot);
        my $f  = Lazysite::Ext::OIDC::check( $docroot, $lz );
        print encode_json( { ok => 1, message => join( '; ', map { "$_->{level}: $_->{text}" } @$f ), findings => $f } );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe | --action refresh|status --docroot DIR | --secret NAME --docroot DIR' } );
    return 1;
}

1;
