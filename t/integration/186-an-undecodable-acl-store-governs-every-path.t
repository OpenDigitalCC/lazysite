#!/usr/bin/perl
# SM1024 (ruled 2026-10-12, "fail closed everywhere"): on the render path an
# acls.json that does not decode is answered exactly as one that will not open,
# whichever of the processor's four readers asks first.
#
# SM268 H12 made _acl_allows_read fail closed on both, and caches a failed load
# as a failure (SM268 H13) so the rest of the request refuses too. Its siblings
# _acl_governed and _acl_governing_key did that for a store that would not OPEN,
# but decoded with `|| {}`: an undecodable store read as an empty map, which they
# answered as "nothing is governed" AND cached as the request's map. The next
# _acl_allows_read in the same request then found a cached map with no rules and
# allowed every path. _acl_governed runs ahead of the read check on a page whose
# own gate returned early (the way in, an engine asset) and on registry builds,
# so a broken store took private pages into public listings.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir load_processor);

my $docroot = site_tempdir();
setup_test_site($docroot);
mkdir "$docroot/lazysite/auth";
mkdir "$docroot/private";
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$docroot/private/plan.md", "---\ntitle: Plan\n---\nSECRET\n" );
my $ACLS = "$docroot/lazysite/auth/acls.json";

load_processor($docroot);
no warnings 'once';

sub fresh { undef $main::ACL_MAP_CACHE; return }
my $page = "$docroot/private/plan.md";

subtest 'THE CONTROL: a readable rule governs and refuses' => sub {
    put( $ACLS, '{"private/":{"read":["alice"]}}' );
    fresh();
    is( main::_acl_governed($page),                      1, 'governed' );
    is( main::_acl_allows_read( 'private/plan.md', '' ), 0, 'and refused to anonymous' );
    is( main::_acl_governing_key($page), 'private/',        'governed by its rule' );
};

for my $case (
    [ 'a truncated object', '{"private/":{"read":["alice"]}' ],
    [ 'a JSON array',       '["private/"]' ],
    )
{
    my ( $what, $bytes ) = @$case;
    subtest "UNDECODABLE ($what), _acl_governed asked first" => sub {
        put( $ACLS, $bytes );
        fresh();
        is( main::_acl_governed($page), 1, 'every path is governed, as for an unreadable store' );
        is( main::_acl_allows_read( 'private/plan.md', '' ), 0,
            'and the read check that follows in the same request still refuses' );
    };
    subtest "UNDECODABLE ($what), _acl_governing_key asked first" => sub {
        put( $ACLS, $bytes );
        fresh();
        is( main::_acl_governing_key($page), '*', 'the failed-load sentinel, as for an unreadable store' );
        is( main::_acl_allows_read( 'private/plan.md', '' ), 0, 'and the read check still refuses' );
    };
    subtest "UNDECODABLE ($what), the registry leaves the page out" => sub {
        put( $ACLS, $bytes );
        fresh();
        is( main::_registry_hidden($page), 1, 'kept out of the public registries' );
    };
}

SKIP: {
    skip 'running as root: chmod 000 does not refuse root', 1 if $> == 0;
    subtest 'UNREADABLE, the reference answer' => sub {
        put( $ACLS, '{"private/":{"read":["alice"]}}' );
        chmod 0, $ACLS;
        fresh();
        my $gov = main::_acl_governed($page);
        my $ok  = main::_acl_allows_read( 'private/plan.md', '' );
        chmod 0644, $ACLS;
        is( $gov, 1, 'governed' );
        is( $ok,  0, 'refused' );
    };
}

subtest 'an ABSENT store governs nothing' => sub {
    unlink $ACLS;
    fresh();
    is( main::_acl_governed($page),                      0, 'not governed' );
    is( main::_acl_allows_read( 'private/plan.md', '' ), 1, 'and allowed' );
};

done_testing();
