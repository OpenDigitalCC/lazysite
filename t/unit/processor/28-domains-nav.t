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
    my $op = render( manager_caps => { manage_domains => 1 } );
    like( $op, qr{/manager/domains}, 'operator (manage_domains): Domains nav present' );

    my $client = render( manager_caps => { manage_domains => 0 } );
    unlike( $client, qr{/manager/domains}, 'bound client (no manage_domains): Domains nav hidden' );
    like( $client, qr{/manager/cache}, 'the rest of the nav is unaffected' );
}

# --- SM186: grant-to-enable discoverability hint ----------------------------
{
    # A user who can grant caps (manage_users) but lacks manage_domains sees a
    # muted, actionable hint pointing at the Groups page - not the real link.
    my $hint = render( manager_caps => { manage_domains => 0, manage_users => 1 } );
    like( $hint, qr/Domains\s*<span class="mg-nav-lock"/,
        'grant-capable user sees the locked Domains hint' );
    like( $hint, qr/grant 'Domains/, 'the hint says how to enable it' );
    unlike( $hint, qr{href="/manager/domains"},
        'the hint is NOT a link to the gated Domains page' );

    # SM775: this used to assert that a client without manage_users saw NO
    # Domains entry, because "the hint is pointless to someone who cannot grant
    # the capability". The field answered that (131E-05): the absence is worse
    # than the pointless hint, because a menu that silently differs per account
    # reads as a manager that has lost a feature rather than as a refusal.
    # Marked for both now; only the sentence differs, and only the one who can
    # act on it gets a link.
    my $client = render( manager_caps => { manage_domains => 0, manage_users => 0 } );
    like( $client, qr/<span class="mg-nav-locked"[^>]*>Domains/,
        'an account that cannot grant it sees Domains MARKED, not missing' );
    unlike( $client, qr{href="/manager/groups" class="mg-nav-locked"},
        'and is not sent to the Groups page, which it cannot act on either' );
}

# --- scope globals for a bound editor ---------------------------------------
{
    my $bound = render(
        manager_caps => { manage_domains => 0 },
        scope_root   => 'content/clientA',
        home_domain  => 'clienta.com',
    );
    like( $bound, qr/LAZYSITE_SCOPE_ROOT\s*=\s*'content\/clientA'/,
        'a bound editor gets their content root as a JS global' );
    like( $bound, qr/LAZYSITE_HOME_DOMAIN\s*=\s*'clienta\.com'/,
        'a bound editor gets their domain as a JS global' );

    my $op = render( manager_caps => { manage_domains => 1 } );
    like( $op, qr/LAZYSITE_SCOPE_ROOT\s*=\s*''/,
        'an operator (unbound) has an empty scope root (browses everything)' );
}

# --- SM157: multi-domain editor gets the scope LIST for the switcher ---------
{
    my $multi = render(
        manager_caps => { manage_domains => 0 },
        scope_root   => '',                                  # empty: no single root
        dav_scopes   => 'content/clientA,content/clientB',
    );
    like( $multi, qr/LAZYSITE_DAV_SCOPES\s*=\s*'content\/clientA,content\/clientB'/,
        'a multi-domain editor gets the full scope list as a JS global (switcher)' );
    like( $multi, qr/LAZYSITE_SCOPE_ROOT\s*=\s*''/,
        'their single scope_root stays empty (the switcher picks the active one)' );

    my $single = render( scope_root => 'content/clientA', dav_scopes => 'content/clientA' );
    like( $single, qr/LAZYSITE_DAV_SCOPES\s*=\s*'content\/clientA'/,
        'a single-domain editor lists one scope (no switcher shown client-side)' );
}

# --- SM191: grant-to-enable hints generalised to content areas + audit --------
{
    # Holder of an area's capability sees the real link.
    my $ed = render( manager_caps =>
            { manage_content => 1, manage_nav => 1, manage_themes => 1, audit => 1 } );
    like( $ed, qr{href="/manager/files"},      'manage_content: Files link present' );
    like( $ed, qr{href="/manager/nav"},        'manage_nav: Navigation link present' );
    like( $ed, qr{href="/manager/appearance"}, 'manage_themes: Appearance link present' );
    like( $ed, qr{href="/manager/audit"},      'audit: Audit log link present' );

    # A grant-capable operator (manage_users) lacking those caps sees muted hints.
    my $adm = render( manager_caps => { manage_users => 1 } );
    like( $adm, qr/Files\s*<span class="mg-nav-lock"/, 'grant-capable, no content: locked Files hint' );
    like( $adm, qr/Navigation\s*<span class="mg-nav-lock"/, 'locked Navigation hint' );
    like( $adm, qr/Appearance\s*<span class="mg-nav-lock"/, 'locked Appearance hint' );
    like( $adm, qr/Audit log\s*<span class="mg-nav-lock"/,  'locked Audit hint' );
    unlike( $adm, qr{href="/manager/files"}, 'the hint is not a link to the gated page' );

    # Appearance unlocks on EITHER themes or layouts.
    my $lay = render( manager_caps => { manage_layouts => 1 } );
    like( $lay, qr{href="/manager/appearance"}, 'manage_layouts alone unlocks Appearance' );

    # SM775: a user who cannot grant and lacks the capability now sees the item
    # MARKED - see the reversal above. What it must never see is a link, to the
    # gated page or to the Groups page it also cannot use.
    my $none = render( manager_caps => {} );
    like( $none, qr/<span class="mg-nav-locked"[^>]*>Files/, 'no manage_content: Files is marked' );
    unlike( $none, qr{href="/manager/files"}, 'no manage_content: no Files link' );
}

done_testing;
