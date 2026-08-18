#!/usr/bin/perl
# SM377: the probe must PROTECT its fixture the way the engine does, and must
# assert that it worked before reading anything.
#
# WHAT WENT WRONG. _acl_write stored acls.json and nothing else. The engine
# protects content by MOVING it into the private store, so the probe's files
# stayed in the document root, a front end serving statics by extension served
# them CORRECTLY - nothing had protected them - and the probe reported the
# site's protected content as reachable. In one deploy on edge it returned FAIL
# in the same run where another check in the same tool reported "protected
# content is held outside the document root". Two checks, one run, contradicting
# each other; a partner agent settled it from outside with a file written
# through the engine after gating, which was refused.
#
# THE ASSERTION IS THE FIX. content_moved is structural (SM313) rather than a
# match on warning text, so it cannot be improved away: if it is absent or zero,
# the probe has not established the condition it is about to measure and must
# say so instead of measuring.
#
# This drives the SHIPPED tool. The defect was that a probe reported on a state
# it never created, so a test that only inspected source would be repeating the
# original mistake one level up.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-check.pl";
plan skip_all => "no $tool" unless -f $tool;

my $src = do { open my $fh, '<', $tool or die $!; local $/; <$fh> };

subtest 'the probe no longer gates by writing the ACL file' => sub {
    my ($probe) = $src =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'run_acl_probe is present' ) or return;

    unlike( $probe, qr/_acl_write\s*\(/,
        'run_acl_probe does not store the rule by hand' )
        or diag( 'Writing acls.json leaves the files in the document root, so '
            . 'the probe measures content nothing ever protected.' );
    like( $probe, qr/_probe_protect\s*\(/,
        'it protects through the engine instead' );
};

subtest 'and it refuses to measure when the move did not happen' => sub {
    my ($fn) = $src =~ /\nsub _probe_protect \{(.*?)\n\}\n/s;
    ok( $fn, '_probe_protect is present' ) or return;

    like( $fn, qr/content_moved/,
        'it asserts on content_moved' )
        or diag( 'Without this the probe cannot tell "protected" from "rule '
            . 'recorded and nothing moved", which are the two states whose '
            . 'confusion is this entire filing.' );

    # The assertion has to REFUSE, not warn-and-continue: a probe that measures
    # anyway has the same output as before for the case that was wrong.
    like( $fn, qr/unless\s+\$r->\{content_moved\}/,
        'and returns failure when it is false' );
};

subtest 'the never-fetched file is written where protected content lives' => sub {
    my ($probe) = $src =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'run_acl_probe is present' ) or return;

    like( $probe, qr/Lazysite::Private::private_path/,
        'the late file goes into the private store' )
        or diag( 'The folder has left the document root by then, so writing '
            . 'this file to the old path would put an UNPROTECTED file back '
            . 'into the docroot - the same defect, one step further along.' );
    unlike( $probe, qr/open my \$lf, '>', "\$PROBE_DIR\/late/,
        'and not back into the document root' );
};

subtest 'protecting as root is declined rather than done badly' => sub {
    my ($fn) = $src =~ /\nsub _probe_may_protect \{(.*?)\n\}\n/s;
    ok( $fn, '_probe_may_protect is present' ) or return;
    like( $fn, qr/SM139/,
        'it cites the rule it is honouring' );
    like( $fn, qr/\$>\s*==\s*0/, 'and tests for root' )
        or diag( 'Moving content as root leaves root-owned files in the site '
            . 'tree, which is exactly what stops the manager working '
            . 'afterwards.' );
};

subtest 'a skip still announces itself' => sub {
    # SM319: every path that returns without fetching says ACL PROBE SKIPPED,
    # because absence-of-FAIL was read as a pass one layer up - which is the
    # defect this probe originally shipped with.
    my ($probe) = $src =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'run_acl_probe is present' ) or return;
    # Counted on the TOKEN, not on the call shape around it: these are written
    # with single quotes, double quotes and a continuation line between them,
    # and an earlier version of this assertion matched only one of the three -
    # failing on formatting while the property it cared about held.
    my @returns = $probe =~ /ACL PROBE SKIPPED/g;
    cmp_ok( scalar @returns, '>=', 3,
        'the new refusal paths all use the designated skip token' )
        or diag( 'A new way to decline to measure that does not say so reads '
            . 'as a healthy site to the deploy script parsing this.' );
};

subtest 'cleanup returns the content it moved' => sub {
    my ($fn) = $src =~ /\nsub _acl_probe_cleanup \{(.*?)\n\}\n/s;
    ok( $fn, '_acl_probe_cleanup is present' ) or return;
    like( $fn, qr/_probe_unprotect/,
        'it unprotects through the engine' )
        or diag( 'Deleting the acls.json key alone orphans the moved copies in '
            . 'the private store - the inverse of the original defect, and '
            . 'just as quiet.' );
    like( $fn, qr/private_path/,
        'and removes its own private litter by path' );
};

done_testing();
