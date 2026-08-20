#!/usr/bin/perl
# SM387: an engine-served static must revalidate, and that is a choice.
#
# Measured in the field on the SM283 proxy template: statics that carried
# `max-age=315360000` from the front end now come back from the engine with
# `no-cache, must-revalidate`. Reported as a possible regression, which is what
# it looks like - every asset revalidating on every request, on contended shared
# hosting.
#
# IT STAYS, AND THIS IS WHY. A static served by the engine is public RIGHT NOW
# and can be protected at any moment - that is the point of SM223, protection as
# a content action with no vhost regeneration and no reload. A visitor holding a
# ten-year copy would go on reading it long after the operator protected the
# folder, in their own browser cache, where nothing the engine or the front end
# does can reach them.
#
# SM331 was precisely this in the front end's DESCRIPTOR cache and took three
# filings to understand. A long cache here would be the same defect one layer
# further out, and further out of reach.
#
# The ten-year cache is therefore a property of the front-end FAST PATH - a site
# with no ACL store, where nothing can become protected without an operator
# noticing - and not of lazysite.
#
# SM416 adds the operator's dial: asset_max_age (seconds) trades a BOUNDED
# staleness window for browser caching, because the field measured pure
# revalidation at ~6 engine round trips per page view. The DEFAULT is
# unchanged - the trade is chosen per site, never inherited - and an
# ACL-governed asset is no-store whatever the dial says.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# SM223: the engine serves statics only when the site has an ACL store.
# Without this the front end answers and none of this is reached.
make_path("$docroot/lazysite/auth");
open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$acl} "{}\n";
close $acl;

make_path("$docroot/lazysite-assets/probe");
open my $css, '>', "$docroot/lazysite-assets/probe/site.css" or die $!;
print {$css} "body{color:red}\n";
close $css;

my $out = run_processor( $docroot, '/lazysite-assets/probe/site.css' );

subtest 'the fixture really served the stylesheet' => sub {
    # A 404 is an HTML response and would carry different caching entirely, so
    # asserting on the header without this would pass on the wrong response.
    like( $out, qr{^Content-type: text/css}mi, 'the engine served it' )
        or diag($out);
};

subtest 'a public static revalidates rather than caching for a decade' => sub {
    like( $out, qr/^Cache-Control:.*must-revalidate/mi,
        'must-revalidate is emitted' )
        or diag( "got:\n$out\n"
            . 'A long cache here means protecting a folder later has no effect '
            . 'on anyone who already fetched the file - in their own browser, '
            . 'which is further out of reach than the descriptor cache SM331 '
            . 'took three filings to understand.' );

    unlike( $out, qr/^Cache-Control:.*max-age=\d{6,}/mi,
        'and no multi-year max-age' )
        or diag( 'The ten-year cache belongs to the front-end fast path, where '
            . 'nothing can become protected without an operator noticing.' );
};

subtest 'and the reasoning is recorded where the decision is made' => sub {
    # This was reported as a regression precisely because nothing said it was
    # deliberate. A choice with no stated reason gets re-litigated, or worse,
    # "fixed".
    my $proc = TestHelper::repo_root() . '/lazysite-processor.pl';
    my $src  = do {
        open my $fh, '<', $proc or die "$proc: $!";
        local $/;
        <$fh>;
    };
    like( $src, qr/SM387/, 'the decision carries its reasoning' )
        or diag( 'Without it the next reader sees a missing optimisation and '
            . 'adds the long cache back.' );
};

# --- SM416: the operator's dial ------------------------------------------------
sub set_conf_line {
    my ($line) = @_;
    open my $fh, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$fh} "$line\n";
    close $fh;
    # resolve_site_vars memoises on the conf mtime; a same-second append can be
    # invisible. Nudge the mtime firmly forward.
    my $t = time() + 2;
    utime $t, $t, "$docroot/lazysite/lazysite.conf" or die $!;
    return;
}

subtest 'asset_max_age turns on bounded browser caching' => sub {
    set_conf_line('asset_max_age: 300');
    my $o = run_processor( $docroot, '/lazysite-assets/probe/site.css' );
    like( $o, qr/^Cache-Control: public, max-age=300, must-revalidate/mi,
        'the operator-set lifetime is emitted' )
        or diag($o);
};

subtest 'an invalid value falls back to the revalidation default' => sub {
    set_conf_line('asset_max_age: ten-years-please');
    my $o = run_processor( $docroot, '/lazysite-assets/probe/site.css' );
    like( $o, qr/^Cache-Control: no-cache, must-revalidate/mi,
        'nonsense is not a number and buys no caching' );
};

subtest 'zero means the default, explicitly' => sub {
    set_conf_line('asset_max_age: 0');
    my $o = run_processor( $docroot, '/lazysite-assets/probe/site.css' );
    like( $o, qr/^Cache-Control: no-cache, must-revalidate/mi,
        '0 restores pure revalidation' );
};

subtest 'an ACL-governed asset is no-store WHATEVER the dial says' => sub {
    # The dial must never widen exposure: a protected asset in any cache is the
    # SM331 defect with an operator-shaped excuse attached.
    set_conf_line('asset_max_age: 300');
    open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$acl}
        '{"lazysite-assets/probe":{"owner":"op","read":["admins"]}}' . "\n";
    close $acl;
    # AUTHENTICATED, so the asset is actually SERVED (200) through the static
    # path whose Cache-Control is under test. The first version of this subtest
    # requested anonymously, got the refusal path's no-store, and PASSED with
    # the helper's guard deleted - it was measuring the wrong emission site.
    my $o = run_processor(
        $docroot, '/lazysite-assets/probe/site.css',
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => 'op',
        HTTP_X_REMOTE_GROUPS  => 'admins',
    );
    like( $o, qr{^Content-type: text/css}mi,
        'the governed asset is served to an authorised reader' )
        or diag($o);
    like( $o, qr/^Cache-Control: no-store/mi,
        'and it is no-store, with max-age set and the path governed' );
    unlike( $o, qr/max-age=300/i, 'the dial is nowhere in the response' );
};

done_testing();
