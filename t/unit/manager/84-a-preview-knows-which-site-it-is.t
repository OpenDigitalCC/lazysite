#!/usr/bin/perl
# SM441: a page preview must render under the Host of the domain that owns it.
#
# Both page-scope previews shelled the processor without setting HTTP_HOST, so
# SM151's per-Host routing never fired and a domain's page rendered with the
# BASE layout, theme and nav. The content was right - the docroot-relative path
# resolves under the primary - and the presentation was another site's. It
# reads as a page given the wrong theme, not as a preview that has not been
# told which site it is previewing.
#
# domain_preview (SM238) always did set HTTP_HOST; the comment on it names
# action_preview as the thing it shells "exactly like ... but with HTTP_HOST
# set". So the difference was understood and applied at DOMAIN scope only.
#
# This tests the OWNERSHIP derivation rather than the render, because the
# derivation is the part that was missing and it can be asserted without a
# processor. The two callers pass its result straight into %ENV.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

sub fixture {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} $conf;
    close $c;
    $Lazysite::Manager::Domains::DOCROOT = $d;
    return $d;
}

my $CONF = <<'CONF';
site_name: Primary
alias_hosts: one.example, two.example, deep.example
alias.one.example.content_root: sites/one
alias.two.example.content_root: sites/two
alias.deep.example.content_root: sites/one/inner
CONF

subtest 'a page under a content root resolves to that domain' => sub {
    fixture($CONF);
    my ($h) = Lazysite::Manager::Domains::host_for_path('sites/one/about.md');
    is( $h, 'one.example', 'the owning host, not the primary' )
        or diag( 'Without this the preview renders the base layout, theme '
            . 'and nav - another site\'s presentation on this site\'s page.' );
};

subtest 'the LONGEST content root wins' => sub {
    fixture($CONF);
    my ($h) = Lazysite::Manager::Domains::host_for_path('sites/one/inner/x.md');
    is( $h, 'deep.example', 'a nested root resolves to the inner domain' )
        or diag( 'Matching the first or the shortest would preview a nested '
            . 'site as its parent.' );
};

subtest 'a path no content root contains belongs to the primary' => sub {
    fixture($CONF);
    my ($h) = Lazysite::Manager::Domains::host_for_path('about.md');
    is( $h, '', 'empty, so the caller leaves the Host alone' );
    my ($h2) = Lazysite::Manager::Domains::host_for_path('sites/elsewhere/x.md');
    is( $h2, '', 'and an unclaimed subtree likewise' );
};

subtest 'a sibling whose name PREFIXES a content root is not swallowed' => sub {
    # sites/one must not claim sites/one-archive/... - the containment bug
    # that has bitten this codebase before (CF-2): a bare index($rel,$cr)==0
    # eats every sibling whose name starts with the key.
    #
    # THE SIBLING MUST HAVE NO DOMAIN OF ITS OWN. An earlier version of this
    # test registered sites/one-archive as its own content root, and then the
    # longest-match rule picked it whether containment was boundary-safe or
    # not - so the bare-prefix sabotage PASSED and the assertion proved
    # nothing. With the sibling unclaimed, only correct containment returns ''.
    fixture($CONF);
    my ($h) = Lazysite::Manager::Domains::host_for_path('sites/one-archive/x.md');
    is( $h, '', 'an unclaimed prefix sibling belongs to nobody' )
        or diag( 'Bare prefix containment: sites/one swallowed '
            . 'sites/one-archive, so the archive previews as the other site.' );
    my ($h2) = Lazysite::Manager::Domains::host_for_path('sites/onething.md');
    is( $h2, '', 'and neither does a file whose name merely starts with it' );
};

subtest 'two domains on one content root are AMBIGUOUS, and say so' => sub {
    # There is no fact that decides between them. This does not pretend to
    # resolve it - it makes the answer deterministic and reports the count, so
    # a caller can offer a host selector rather than silently guessing.
    fixture( "alias_hosts: b.example, a.example\n"
            . "alias.a.example.content_root: sites/shared\n"
            . "alias.b.example.content_root: sites/shared\n" );
    my ( $h, $n ) = Lazysite::Manager::Domains::host_for_path('sites/shared/x.md');
    is( $n, 2, 'the tie is reported, not hidden' );
    is( $h, 'a.example', 'and resolved deterministically by sorted host' );
    my ($again) = Lazysite::Manager::Domains::host_for_path('sites/shared/x.md');
    is( $again, $h, 'so the same path always previews the same way' );
};

subtest 'traversal in a configured content root is ignored' => sub {
    fixture( "alias_hosts: bad.example\n"
            . "alias.bad.example.content_root: ../../etc\n" );
    my ($h) = Lazysite::Manager::Domains::host_for_path('../../etc/passwd');
    is( $h, '', 'a traversal root claims nothing' );
};

done_testing();
