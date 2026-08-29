#!/usr/bin/perl
# SM690 / SM691: what a brief PROMISES, and how long a pairing key lives.
#
# BOTH CAME FROM ONE BAD MORNING IN THE FIELD. The edge agent read a partner
# brief saying the account held `manage_domains`; `whoami` said false. It read
# another listing only `manage_users` + webdav for an account whose task needed
# `manage_forms`. Then all three pairing keys, minted the evening before,
# returned 401 - single-use AND fifteen minutes - and the only delivery that
# worked was pasting them into a transcript, which the brief's own rule marks as
# spending them.
#
# The capability divergence is NOT a wrong derivation. The list is already
# derived from @CAP_KEYS (SM573) and was right when it was written; the grant
# changed afterwards and the brief did not. So the fix is to say WHEN it was
# true, which turns "this document is wrong" into "this document is old" - the
# difference between distrusting it and re-checking the account.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $src = do { open my $fh, '<', $tool or die $!; local $/; <$fh> };

subtest 'the Capabilities section dates itself and defers to whoami' => sub {
    like( $src, qr/SNAPSHOT taken when this brief was generated/,
        'the list says it is a snapshot' )
        or diag( 'Without this the section reads as a promise, and a partner '
            . 'plans work against a grant that may have moved.' );
    like( $src, qr/\$stamped/, 'and carries the date it was taken' );
    # Matched across a line break: the template wraps, and a test that pins
    # prose to one line breaks on reflow rather than on meaning.
    like( $src, qr/`whoami`\s+is\s+the\s+authority/,
        'and names whoami as the authority' );

    # The stamp must be COMPUTED, not typed. A hard-coded date would be worse
    # than none: it would look like provenance and be a lie.
    like( $src, qr/my \$stamped = sprintf/,
        'the date is computed at generation time' );
};

subtest 'the pairing-key TTL is settable, bounded, and unchanged by default' => sub {
    like( $src, qr/\$PAIRING_TTL_DEFAULT\s*=\s*900\b/,
        'the default is still fifteen minutes' )
        or diag( 'Raising it loosens a credential handover. That is the '
            . "operator's decision, not something to change while fixing "
            . 'their report about delivery.' );

    like( $src, qr/pairing_key_ttl/, 'a site can set pairing_key_ttl' );
    like( $src, qr/\$PAIRING_TTL_MIN\s*=\s*60\b/,  'floored at a minute' );
    like( $src, qr/\$PAIRING_TTL_MAX\s*=\s*86_400\b/,
        'and ceilinged at a day - beyond that it is a standing credential, '
            . 'not a handover' );

    like( $src, qr/time\(\) \+ _pairing_ttl\(\)/,
        'the expiry uses the resolved value' )
        or diag( 'A setting nothing reads is a setting that lies.' );
    like( $src, qr/int\( _pairing_ttl\(\) \/ 60 \)/,
        'and the message quotes the value in force, not the default' )
        or diag( 'Telling an operator "15 min" while the key lives an hour is '
            . 'the same class of defect as the stale brief.' );
};

subtest 'the reader survives a missing or unreadable conf' => sub {
    # Minting a key is not the moment to fail on a config read.
    my ($fn) = $src =~ /(sub _pairing_ttl \{.*?\n\})/s;
    ok( $fn, 'the reader was found' ) or return;
    like( $fn, qr/return \$PAIRING_TTL_DEFAULT unless/,
        'an absent or non-numeric value falls back to the default' );
    like( $fn, qr/-f \$conf/, 'and a missing conf is not an error' );
};

done_testing();
