#!/usr/bin/perl
# `lazysite acl reapply` repairs the upgrade state that no package delivers.
#
# THE STATE IT REPAIRS. Protecting content moves it out of the document root,
# but only on the ACT of protecting (SM286, 0.10.8). So a section protected on
# any earlier version keeps its rule - honoured for pages - while its FILES stay
# in the served tree, reachable by anyone who knows the path on a front end that
# answers statics itself. Measured on a real upgraded site, 19 of 25 extensions
# were still served byte-identically to an anonymous request.
#
# SM296 produced the identical end state by a different route on 0.10.8: the
# move crashed after the rule was saved.
#
# One sweep repairs both, because both are "the rule is right and the bytes are
# in the wrong place", and re-issuing the rule runs the move.
#
# WHAT THIS FILE PINS, in order of how badly it would hurt to get wrong:
#
#   1. it MOVES content that an upgrade left behind - the whole point;
#   2. it changes NO RULE - a sweep across a fleet that quietly altered
#      permissions would be far worse than the exposure it repairs;
#   3. it is dry-run unless --apply, so it cannot move content on a live site
#      because someone was exploring the CLI.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root);
use Lazysite::Private qw(private_path);

my $root = repo_root();
my $acl  = "$root/tools/lazysite-acl.pl";
ok( -f $acl, 'the acl CLI is present' ) or do { done_testing; exit };

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub run_acl {
    my (@args) = @_;
    my $pid    = open my $ph, '-|';
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 127;
        exec $^X, $acl, @args;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    return { out => ( $out // '' ), rc => $? >> 8 };
}

# A site in the state an upgrade leaves: a rule in the store, and the content
# it governs still sitting in the document root.
#
# Built by WRITING THE STORE DIRECTLY, which is the one case where that is the
# honest fixture rather than the discouraged one - the state under test is
# precisely "a rule written by an older version, whose writer no longer
# exists". Driving today's writer would produce the post-move state and prove
# nothing.
sub build_site {
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/members/secret.md",      "SECRETBYTES\n" );
    spit( "$d/members/handout.pdf",    "PDFBYTES\n" );
    spit( "$d/public.md",              "PUBLIC\n" );
    spit( "$d/lazysite/auth/acls.json",
        '{"members":{"read":["alice"],"write":["alice"],"owner":"alice"}}' );
    spit( "$d/lazysite/auth/users", "alice:x:\n" );
    return ( $base, $d );
}

subtest 'dry run reports and moves nothing' => sub {
    my ( $base, $d ) = build_site();
    my $r = run_acl( 'reapply', '--docroot', $d, '--actor', 'local' );
    is( $r->{rc}, 0, 'exits 0' ) or diag( $r->{out} );
    like( $r->{out}, qr/Would re-apply 1 rule/, 'says what it would do' );
    like( $r->{out}, qr/--apply/,               'and names the flag that would do it' );

    ok( -f "$d/members/secret.md",
        'the content is still in the document root - nothing moved' );
};

subtest 'apply moves the content out of the served tree' => sub {
    my ( $base, $d ) = build_site();
    ok( -f "$d/members/secret.md", 'precondition: content is in the docroot' );

    my $r = run_acl( 'reapply', '--docroot', $d, '--actor', 'local', '--apply' );
    is( $r->{rc}, 0, 'exits 0' ) or diag( $r->{out} );
    like( $r->{out}, qr/re-applied: members/, 'names what it re-applied' );

    ok( !-e "$d/members/secret.md",
        'the protected content has LEFT the document root - which is the '
            . 'whole exposure this sweep exists to close' );
    ok( -e private_path( $d, 'members/secret.md' ),
        'and is in the private store' );
    ok( !-e "$d/members/handout.pdf",
        'every file under the rule moves, not just the markdown - SM283 was '
            . 'exactly the case where some extensions moved and others did not' );
    ok( -f "$d/public.md", 'unprotected content is untouched' );
};

subtest 'it changes no rule' => sub {
    # The property that makes this safe to run unattended across a fleet.
    my ( $base, $d ) = build_site();
    my $before = do {
        open my $fh, '<', "$d/lazysite/auth/acls.json" or die $!;
        local $/;
        <$fh>;
    };

    run_acl( 'reapply', '--docroot', $d, '--actor', 'local', '--apply' );

    my $after = do {
        open my $fh, '<', "$d/lazysite/auth/acls.json" or die $!;
        local $/;
        <$fh>;
    };

    my $norm = sub {
        my ($j) = @_;
        require JSON::PP;
        return JSON::PP->new->canonical(1)->encode( JSON::PP::decode_json($j) );
    };
    is( $norm->($after), $norm->($before),
        'the stored rules are byte-identical after the sweep - it re-issues '
            . 'what is already there and grants nothing' );
};

subtest 'a site with nothing protected is a no-op' => sub {
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/index.md",               "HOME\n" );

    my $r = run_acl( 'reapply', '--docroot', $d, '--actor', 'local', '--apply' );
    is( $r->{rc}, 0, 'exits 0' );
    like( $r->{out}, qr/No protected sections/,
        'and says so rather than reporting a sweep it did not do' );
};

subtest 'it is idempotent' => sub {
    # An operator who is unsure whether the sweep ran must be able to run it
    # again, on a fleet, without wondering what a second pass does.
    my ( $base, $d ) = build_site();
    run_acl( 'reapply', '--docroot', $d, '--actor', 'local', '--apply' );
    my $second = run_acl( 'reapply', '--docroot', $d, '--actor', 'local', '--apply' );
    is( $second->{rc}, 0, 'a second pass succeeds' ) or diag( $second->{out} );
    ok( -e private_path( $d, 'members/secret.md' ),
        'and the content is still in the store' );
    ok( !-e "$d/members/secret.md", 'and still not in the docroot' );
};

done_testing();
