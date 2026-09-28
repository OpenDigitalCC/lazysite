#!/usr/bin/perl
# SM217: A HOST CAN BE AN ALIAS OF ANOTHER, and the list says so.
#
# The engine has always served several hosts from one content root - a host with
# no content_root of its own mirrors the primary, and two hosts may point at the
# same folder. What did not exist was any way to SAY that: an operator added a
# second domain and typed the shared path themselves, and the Domains list then
# showed the two as unrelated peers. The relationship was real and invisible.
#
# AND THE HAND-COPYING DOES NOT FAIL WHEN IT GOES WRONG, which is why this is
# worth an action rather than a note. A typo in the shared path is accepted: the
# alias gets its own empty folder, is provisioned and seeded, and serves a
# different site under a name that says it is the same one. That is the case this
# file measures first.
#
# WHAT IS HELD HERE:
#
#   * the alias READS the canonical domain's content root - the caller does not
#     supply it, because a caller that could supply it could supply the wrong one;
#   * an EMPTY canonical root is a valid answer, not a missing one: a host with
#     no root of its own serves the default site, so its alias has none either
#     and they mirror the primary together;
#   * `alias_of` is DERIVED from the content roots and never stored, so it cannot
#     disagree with what actually decides what is served;
#   * presentation overrides still apply per host - an alias may look different
#     while serving the same content;
#   * and nothing is seeded, because by definition the content is already there.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Manager::Domains qw(domains_list domain_add domain_add_alias);

my $d = site_tempdir();
make_path("$d/lazysite");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\nsite_url: https://agency.example\ntheme: base\n";
close $cf;
$Lazysite::Manager::Domains::DOCROOT = $d;

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; <$fh> }

sub row_for {
    my ($host) = @_;
    my ($r) = grep { ( $_->{host} // '' ) eq $host } @{ domains_list()->{domains} || [] };
    return $r || {};
}

subtest 'the hand-copied path is what this replaces, and it fails silently' => sub {
    ok( domain_add( 'acme.example', content_root => 'sites/acme', seed => 1 )->{ok},
        'the canonical domain' );
    ok( -f "$d/sites/acme/index.md", 'with content in it' );

    # The typo. One character, and it is ACCEPTED.
    ok( domain_add( 'acme.co', content_root => 'sites/acmé', seed => 1 )->{ok},
        'a second host with a mistyped root is accepted' );
    isnt( row_for('acme.co')->{content_root}, row_for('acme.example')->{content_root},
        'and serves a DIFFERENT folder under a name that says it is the same site' );
    is( row_for('acme.co')->{alias_of}, '',
        'the list cannot call it an alias, because it is not one' );
};

subtest 'an alias shares the canonical domain\'s root, read not supplied' => sub {
    my $r = domain_add_alias( 'acme.net', 'acme.example' );
    ok( $r->{ok}, 'the alias is registered' ) or diag explain $r;
    is( $r->{alias_of}, 'acme.example', 'the result names what it is an alias of' );
    is( row_for('acme.net')->{content_root}, 'sites/acme',
        'and carries the canonical root exactly - nobody typed it' );
    like( conf(), qr/^alias\.acme\.net\.content_root: sites\/acme$/m,
        'written as an ordinary content_root line: the serving path learns nothing new' );
    unlike( conf(), qr/alias_of/, 'and NO alias_of is stored - it is derived' );
    is( row_for('acme.net')->{alias_of}, 'acme.example',
        'the list marks the row as an alias of its canonical domain' );
    is( row_for('acme.example')->{alias_of}, '',
        'and the canonical row is not marked as an alias of the alias' );
};

subtest 'a rootless host is an alias of the default site' => sub {
    ok( domain_add('mirror.example')->{ok}, 'a host with no content root of its own' );
    is( row_for('mirror.example')->{content_root}, '', 'inherits the primary\'s' );
    is( row_for('mirror.example')->{alias_of}, '(default)',
        'so it reads as an alias of the default site, not of whichever alias came first' );

    my $r = domain_add_alias( 'mirror.net', 'mirror.example' );
    ok( $r->{ok}, 'and can itself be aliased' )
        or diag( 'An empty canonical root is a valid answer, not a missing one: '
            . 'both hosts serve the default site, which IS the relationship.' );
    is( row_for('mirror.net')->{alias_of}, '(default)',
        'both read as aliases of the default site' );
};

subtest 'an alias may look different while serving the same content' => sub {
    ok( domain_add_alias( 'acme.org', 'acme.example', theme => 'dark', nav_file => 'nav-org.conf' )
            ->{ok},
        'presentation overrides pass through' );
    is( row_for('acme.org')->{content_root}, 'sites/acme', 'content is still shared' );
    is( row_for('acme.org')->{theme},        'dark',       'and the theme is its own' );
    is( row_for('acme.org')->{theme_inherited}, 0, 'marked as an override, not inherited' );
};

subtest 'what it refuses' => sub {
    my $r = domain_add_alias( 'x.example', 'nosuch.example' );
    ok( !$r->{ok}, 'a canonical domain that is not configured' );
    like( $r->{error}, qr/no domain 'nosuch\.example' is configured/, 'named' );
    like( $r->{error}, qr/nothing to be an alias of/, 'and why it matters' );
    is( $r->{kind}, 'not-found', 'as not-found' );

    $r = domain_add_alias( 'acme.example', 'acme.example' );
    ok( !$r->{ok}, 'a host aliasing itself' );
    like( $r->{error}, qr/cannot be an alias of itself/, 'said plainly' );

    # REFUSED, not silently overridden. A sabotage that let %opts win found this
    # gap: the root was being dropped rather than rejected, so a caller who
    # supplied one would have believed it was used.
    $r = domain_add_alias( 'z.example', 'acme.example', content_root => 'sites/somewhere-else' );
    ok( !$r->{ok}, 'a content_root from the caller is refused' );
    like( $r->{error}, qr/content_root is not an argument here/, 'named' );
    like( $r->{error}, qr/which is the point of the action/,     'and why' );
    like( $r->{error}, qr/Use domain-add/, 'pointing at the action that does take one' );

    $r = domain_add_alias( 'y.example', '' );
    ok( !$r->{ok}, 'no canonical domain at all' );
    like( $r->{error}, qr/the domain to alias is required/, 'names the missing argument' );

    # The host rules are domain_add's and are not restated here - one refusal,
    # one place. This proves the delegation, not the rule.
    $r = domain_add_alias( 'not a host', 'acme.example' );
    ok( !$r->{ok}, 'an invalid host is refused by the rules domain_add already has' );

    $r = domain_add_alias( 'acme.net', 'acme.example' );
    ok( !$r->{ok}, 'and a host already configured is still refused' );
    is( $r->{kind}, 'exists', 'as exists' );
};

subtest 'nothing is seeded into the canonical domain\'s content' => sub {
    make_path("$d/sites/quiet");
    ok( domain_add( 'quiet.example', content_root => 'sites/quiet' )->{ok},
        'a canonical domain whose folder has no index yet' );
    ok( !-e "$d/sites/quiet/index.md", 'and no index' );
    ok( domain_add_alias( 'quiet.net', 'quiet.example', seed => 1 )->{ok},
        'an alias registered, asking for a seed' );
    ok( !-e "$d/sites/quiet/index.md",
        'writes NO page into the shared folder - the content is the canonical '
            . 'domain\'s, and an alias does not get to put a page in it' );
};

done_testing();
