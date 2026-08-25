#!/usr/bin/perl
# SM483: the three registry conditions the field filed and a rig reproduced.
#
#   1. A symlink anywhere in a content root split the cache key: the
#      processor cached under the realpath while the invalidator keyed the
#      configured spelling - regenerate cleared nothing, cleared_count:0,
#      and the deleted page kept serving until the TTL.
#   2. The MCP writer emitted flow-style `register: [x]` while the reader
#      parsed only block style - every MCP-created page invisible to every
#      registry while list_pages echoed its registers back.
#   3. A DAV content write never invalidated the registries at all.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor run_dav setup_test_site setup_dav_site);

my $root = repo_root();

sub fresh_site {
    my $docroot = tempdir( CLEANUP => 1 );
    setup_test_site($docroot);
    make_path("$docroot/lazysite/templates/registries");
    open my $tf, '>', "$docroot/lazysite/templates/registries/sitemap.xml.tt" or die $!;
    print {$tf} "[%- FOREACH p IN pages -%]\nURL: [% p.url %]\n[% END -%]\n";
    close $tf;
    return $docroot;
}

subtest 'FLOW-STYLE register: the deployed field shape is visible now' => sub {
    my $docroot = fresh_site();
    open my $pf, '>', "$docroot/flow.md" or die $!;
    print {$pf} "---\ntitle: F\nregister: [sitemap.xml]\n---\nx\n";
    close $pf;
    my $reg = run_processor( $docroot, '/sitemap.xml' );
    like( $reg, qr{URL: .*flow}, 'a flow-style register line registers the page' )
        or diag( 'Every MCP-created page in the field carries exactly this '
            . 'shape; before SM483 the reader parsed only block style.' );
};

subtest 'THE SYMLINKED ROOT: invalidation reaches what the processor cached' => sub {
    my $docroot = fresh_site();
    make_path("$docroot/sites/real");
    symlink( "$docroot/sites/real", "$docroot/sites/alpha" ) or plan skip_all => 'no symlinks here';
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "alias_hosts: alpha.test\nalias.alpha.test.content_root: sites/alpha\n";
    close $cf;
    open my $pf, '>', "$docroot/sites/real/page.md" or die $!;
    print {$pf} "---\ntitle: P\nregister:\n  - sitemap.xml\n---\nx\n";
    close $pf;
    my $before = run_processor( $docroot, '/sitemap.xml', HTTP_HOST => 'alpha.test' );
    like( $before, qr{URL: .*page}, 'the page registers through the symlinked root' );
    unlink "$docroot/sites/real/page.md";
    require Lazysite::Manager::Files;
    local $Lazysite::Manager::Files::DOCROOT = $docroot;
    my ( undef, $cleared ) = Lazysite::Manager::Files::_invalidate_registries();
    ok( scalar @{$cleared}, 'regenerate CLEARS the symlinked root\'s cache' )
        or diag( 'cleared nothing: the invalidator keyed the configured '
            . 'spelling while the processor cached under the realpath.' );
    my $after = run_processor( $docroot, '/sitemap.xml', HTTP_HOST => 'alpha.test' );
    unlike( $after, qr{URL: .*page}, 'and the deleted page is gone, not TTL-frozen' );

    # SM500 rides the same fixture, AFTER the invalidation assertions (its
    # first placement drained the cache before the cleared-check and failed
    # it): a pre-existing file where the generated registry would go, and
    # its report must never carry an absolute filesystem path.
    open my $shadow, '>', "$docroot/sites/real/sitemap.xml" or die $!;
    print {$shadow} "hand-made\n";
    close $shadow;
    my ($shadowed) = Lazysite::Manager::Files::_invalidate_registries();
    ok( !( grep { m{\A/(?:tmp|home|srv)/} } @{$shadowed} ),
        'SM500: no shadowed-file report carries an absolute server path' )
        or diag explain $shadowed;
    ok( ( grep { m{sitemap\.xml\z} } @{$shadowed} ),
        'while the shadowing file itself is still named' );
    unlink "$docroot/sites/real/sitemap.xml";
};

subtest 'A DAV WRITE INVALIDATES: the published page reaches the sitemap' => sub {
    # Built on setup_dav_site - the proven auth fixture - rather than a
    # hand-rolled account (whose first draft used a users-tool verb that does
    # not exist and produced a CGI that said nothing at all).
    my $site    = TestHelper::setup_dav_site();
    my $docroot = $site->{docroot};
    make_path("$docroot/lazysite/templates/registries");
    open my $tf, '>', "$docroot/lazysite/templates/registries/sitemap.xml.tt" or die $!;
    print {$tf} "[%- FOREACH p IN pages -%]\nURL: [% p.url %]\n[% END -%]\n";
    close $tf;
    my $cold = run_processor( $docroot, '/sitemap.xml' );
    unlike( $cold, qr{URL: .*davpage}, 'baseline: page absent (cache warm)' );
    my $body = "---\ntitle: D\nregister:\n  - sitemap.xml\n---\nx\n";
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( %ENV,
        DOCUMENT_ROOT      => $docroot,
        SCRIPT_NAME        => '/dav',
        REMOTE_ADDR        => '127.0.0.1',
        REQUEST_METHOD     => 'PUT',
        PATH_INFO          => '/content/davpage.md',
        CONTENT_LENGTH     => length $body,
        HTTP_AUTHORIZATION => $site->{auth},
    );
    my $out = qx(sh -c \Q$^X \Q$root/lazysite-dav.pl\E < \Q$bf\E 2>/dev/null\E);
    like( $out, qr/Status: 201/, 'published over DAV' ) or diag "response: [$out]";
    delete @ENV{qw(SCRIPT_NAME PATH_INFO HTTP_AUTHORIZATION CONTENT_LENGTH REQUEST_METHOD)};
    my $warm = run_processor( $docroot, '/sitemap.xml' );
    like( $warm, qr{URL: .*davpage},
        'the DAV-published page reaches the sitemap NOW, not at the TTL' );
};

# SM534: the front-door review found do_copy_move had no registry call at
# all - SM483 reached PUT and DELETE only - so a page renamed over WebDAV
# was advertised at a URL that now 404s and invisible at its new one until
# the TTL. The manager's action_move and action_copy clear the cache; the
# DAV verbs must give the same answer. The registry-cache glob is the
# processor's own cache location, so the assertion is on the artefact a
# visitor's sitemap request reads, not on a log line.
sub dav_registry_site {
    my $site    = TestHelper::setup_dav_site();
    my $docroot = $site->{docroot};
    make_path("$docroot/lazysite/templates/registries");
    open my $tf, '>', "$docroot/lazysite/templates/registries/sitemap.xml.tt" or die $!;
    print {$tf} "[%- FOREACH p IN pages -%]\nURL: [% p.url %]\n[% END -%]\n";
    close $tf;
    my $page = "---\ntitle: P\nregister:\n  - sitemap.xml\n---\nx\n";
    my $put  = run_dav( $docroot, 'PUT', '/content/a.md',
        body => $page, HTTP_AUTHORIZATION => $site->{auth} );
    is( $put->{code}, 201, 'the page is published over DAV' );
    like( run_processor( $docroot, '/sitemap.xml' ), qr{URL: .*content/a\b},
        'and registers in the sitemap' );
    return $site;
}
sub registry_cached {
    my ($docroot) = @_;
    my @f = glob("$docroot/lazysite/cache/registries/*/sitemap.xml");
    return scalar @f;
}

subtest 'SM534: a DAV MOVE reaches the registries' => sub {
    my $site    = dav_registry_site();
    my $docroot = $site->{docroot};
    ok( registry_cached($docroot), 'the registry is cached before the MOVE' ) or return;
    my $r = run_dav( $docroot, 'MOVE', '/content/a.md',
        HTTP_DESTINATION   => 'http://host/dav/content/b.md',
        HTTP_AUTHORIZATION => $site->{auth} );
    is( $r->{code}, 201, 'MOVE answers 201' ) or diag $r->{body};
    ok( !registry_cached($docroot), 'the MOVE clears the registry cache, as action_move does' )
        or diag('the registry cache survived the MOVE');
    my $after = run_processor( $docroot, '/sitemap.xml' );
    unlike( $after, qr{URL: .*content/a\b}, 'the sitemap no longer lists the OLD url' );
    like( $after, qr{URL: .*content/b\b}, 'the sitemap lists the NEW url' );
};

subtest 'SM534: a DAV COPY reaches the registries' => sub {
    my $site    = dav_registry_site();
    my $docroot = $site->{docroot};
    ok( registry_cached($docroot), 'the registry is cached before the COPY' ) or return;
    my $r = run_dav( $docroot, 'COPY', '/content/a.md',
        HTTP_DESTINATION   => 'http://host/dav/content/c.md',
        HTTP_AUTHORIZATION => $site->{auth} );
    is( $r->{code}, 201, 'COPY answers 201' ) or diag $r->{body};
    ok( !registry_cached($docroot), 'the COPY clears the registry cache, as action_copy does' )
        or diag('the registry cache survived the COPY');
    # Deliberately NOT asserted: that the copy is then listed. A copy is born
    # with an owner-only ACL entry (the action_copy rule, on both surfaces)
    # and _acl_governed hides ANY entry from the registries - so the
    # manager's own copy is absent from the sitemap too, on this same
    # fixture. That is a separate finding about what "governed" means, not
    # about invalidation, and this test does not pretend to own it.
    like( run_processor( $docroot, '/sitemap.xml' ), qr{URL: .*content/a\b},
        'the re-rendered sitemap still lists the source' );
};

done_testing();
