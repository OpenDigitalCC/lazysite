#!/usr/bin/perl
# SM976 F1, F2 (ruled 2026-10-09): the rules Manager::Common adds for what Q15c
# found, as truth tables - so a change to who reaches a served theme, a form or a
# brief is a change to a table here.
#
#   served_artifact_refusal   F1 "Yes, any served artifact"
#   caller_may_reach_path     F2: the content-path rule, asked by the two below
#   caller_may_reach_form     F2 "Confine both": through the pages that bind it
#   caller_may_reach_brief    F2: a page's by its path, a row's by its table
#
# The instance: alpha.test at sites/alpha (theme a1), beta.test at sites/beta
# (theme b1), mirror.test with no content root (theme m1), and the primary
# (layout base, theme p1). Forms: fa on a page in sites/alpha, fb in sites/beta,
# fp on a primary page, fab on a page in each of alpha and beta, fx on none.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(served_artifact_refusal caller_may_reach_path caller_may_reach_form
    caller_may_reach_brief form_bindings);
use Lazysite::Manager::Domains ();

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/sites/alpha", "$d/sites/beta" );
{
    open my $cf, q(>), "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nlayout: base\ntheme: p1\nalias_hosts: alpha.test, beta.test, mirror.test\n"
        . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n"
        . "alias.alpha.test.theme: a1\nalias.beta.test.theme: b1\nalias.mirror.test.theme: m1\n";
    close $cf;
}
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;

sub spit { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
my %PAGE = ( fa => ['sites/alpha/c.md'], fb => ['sites/beta/c.md'], fp => ['c.md'],
    fab => [ 'sites/alpha/d.md', 'sites/beta/d.md' ] );
for my $f ( sort keys %PAGE ) {
    spit( "$d/$_", "---\ntitle: C\nform: $f\n---\n\n:::form\nn | N\n:::\n" ) for @{ $PAGE{$f} };
}
spit( "$d/sites/alpha/plain.md", "---\ntitle: no form\n---\nform: fx\n" ); # the body, not the front matter

my %WHO = (
    'a grant scoped to alpha'          => [ scopes => ['sites/alpha'] ],
    'a grant naming no scope'          => [ scopes => [] ],
    'a grant scoped to alpha and beta' => [ scopes => [ 'sites/alpha', 'sites/beta' ] ],
);
my $T = 'lazysite/layouts/base/themes';

subtest 'F1: served_artifact_refusal' => sub {
   #                                         a1 b1 m1 p1 unused  layout base  layout spare
    my %want = (
        'a grant scoped to alpha'          => 'YNNNYNY',
        'a grant naming no scope'          => 'NNYYYNY',
        'a grant scoped to alpha and beta' => 'YYNNYNY',
    );
    my @paths = ( "$T/a1/x.css", "$T/b1/x.css", "$T/m1/x.css", "$T/p1/x.css", "$T/unused/x.css",
        'lazysite/layouts/base/layout.tt', 'lazysite/layouts/spare/layout.tt' );
    for my $who ( sort keys %want ) {
        my @w = split //, $want{$who};
        for my $i ( 0 .. $#paths ) {
            my $no = served_artifact_refusal( $paths[$i], @{ $WHO{$who} } );
            is( $no ? 'N' : 'Y', $w[$i], "$who: $paths[$i]" );
        }
    }
    ok( !served_artifact_refusal( 'sites/alpha/x.md', scopes => ['sites/beta'] ), 'a content path is not this rule\'s' );
    my ( $err, $detail ) = served_artifact_refusal( "$T/b1/x.css", scopes => ['sites/alpha'] );
    like( $err, qr/the theme 'b1' \(layout 'base'\) is served by a site you do not reach/, 'the refusal names the theme' );
    unlike( $err, qr/beta\.test/, '...and not the site that serves it, which the caller does not reach' );
    like( $detail, qr/\Aserved-artifact-refused: /, '...with the audit detail every content rule leaves' );
};

subtest 'F2: caller_may_reach_path' => sub {
    my $alpha = $WHO{'a grant scoped to alpha'};
    ok( caller_may_reach_path( 'sites/alpha/x.md', @$alpha ), 'inside its scope' );
    ok( !caller_may_reach_path( 'sites/beta/x.md', @$alpha ), 'outside it' );
    ok( !caller_may_reach_path( 'sites/alpha/../beta/x.md', @$alpha ), 'a .. out of it' );
    ok( !caller_may_reach_path( 'lazysite/nav.conf', @$alpha ), 'the engine tree is inside no scope' );
    ok( !caller_may_reach_path( '',                  @$alpha ), 'nor is the site root' );
    ok( caller_may_reach_path( 'sites/beta/x.md', scopes => [] ), 'a grant naming no scope reaches the content namespace (R3)' );
};

subtest 'F2: caller_may_reach_form' => sub {
    is_deeply( form_bindings()->{fab}, [ 'sites/alpha/d.md', 'sites/beta/d.md' ], 'a form\'s binding pages are found' );
    ok( !exists form_bindings()->{fx}, 'a form named in a page body, not its front matter, is bound by none' );
    #                                         fa fb fp fab fx
    my %want = (
        'a grant scoped to alpha'          => 'YNNNN',
        'a grant naming no scope'          => 'YYYYY',
        'a grant scoped to alpha and beta' => 'YYNYN',
    );
    for my $who ( sort keys %want ) {
        my @w = split //, $want{$who};
        my @f = qw(fa fb fp fab fx);
        is( caller_may_reach_form( $f[$_], @{ $WHO{$who} } ) ? 'Y' : 'N', $w[$_], "$who: form $f[$_]" ) for 0 .. $#f;
    }
};

subtest 'F2: caller_may_reach_brief' => sub {
    spit( "$d/lazysite/db/tables/t_beta.yaml", "title: t\ndomain: beta.test\nkey: k\nfields:\n  k:\n    type: text\n" );
    my $alpha = $WHO{'a grant scoped to alpha'};
    ok( caller_may_reach_brief( 'sites/alpha/c.md',  @$alpha ), 'its own page\'s' );
    ok( !caller_may_reach_brief( '/sites/beta/c.md', @$alpha ), 'not another site\'s' );
    ok( !caller_may_reach_brief( undef, type => 'row', table => 't_beta', @$alpha ), 'not a row of another site\'s table' );
    ok( !caller_may_reach_brief( '/.typed/row/t_beta/k', @$alpha ), '...nor its store entry' );
    ok( caller_may_reach_brief( undef, type => 'row', table => 't_gone', @$alpha ), 'a row of a table naming no domain' );
};

done_testing();
