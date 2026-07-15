#!/usr/bin/perl
# SM154 (P3): the manager layout shows the Domains nav entry only to a user who
# may manage domains (manager_caps.manage_config), and exposes a domain-bound
# editor's own content root + domain as JS globals so the file browser can root
# there. Rendered directly through the layout, as the enabled_plugins nav test.
use strict;
use warnings;
use Test::More;
use Template;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";
ok( -f $layout, 'manager layout present' );

sub render {
    my (%extra) = @_;
    my $tt      = Template->new( ABSOLUTE => 1, EVAL_PERL => 0 );
    my $out     = '';
    $tt->process(
        $layout,
        { page_title => 'Files',
            site_name        => 'Demo',
            request_uri      => '/manager/files',
            enabled_plugins  => {},
            auth_user        => 'me',
            content          => 'BODY',
            year             => 2026,
            lazysite_version => '0.0.0',
            manager_caps     => {},
            scope_root       => '',
            home_domain      => '',
            %extra,
        },
        \$out
    ) or die "TT error: " . $tt->error();
    return $out;
}

# --- nav gating -------------------------------------------------------------
{
    my $op = render( manager_caps => { manage_config => 1 } );
    like( $op, qr{/manager/domains}, 'operator (manage_config): Domains nav present' );

    my $client = render( manager_caps => { manage_config => 0 } );
    unlike( $client, qr{/manager/domains}, 'bound client (no manage_config): Domains nav hidden' );
    like( $client, qr{/manager/files}, 'the rest of the nav is unaffected' );
}

# --- scope globals for a bound editor ---------------------------------------
{
    my $bound = render(
        manager_caps => { manage_config => 0 },
        scope_root   => 'content/clientA',
        home_domain  => 'clienta.com',
    );
    like( $bound, qr/LAZYSITE_SCOPE_ROOT\s*=\s*'content\/clientA'/,
        'a bound editor gets their content root as a JS global' );
    like( $bound, qr/LAZYSITE_HOME_DOMAIN\s*=\s*'clienta\.com'/,
        'a bound editor gets their domain as a JS global' );

    my $op = render( manager_caps => { manage_config => 1 } );
    like( $op, qr/LAZYSITE_SCOPE_ROOT\s*=\s*''/,
        'an operator (unbound) has an empty scope root (browses everything)' );
}

done_testing;
