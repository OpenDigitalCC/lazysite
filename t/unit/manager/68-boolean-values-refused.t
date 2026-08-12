#!/usr/bin/perl
# SM291: a malformed boolean is refused, not read as false.
#
# Measured by the site agent against 0.10.7, from outside, over MCP:
#
#   draft: "yes-please"  -> ok:1, flag CLEARED, the folder went 404 -> 302
#   draft: "enabled"     -> ok:1, flag CLEARED
#   draft: ["true"]      -> ok:1, flag CLEARED
#
# SM278 made the validator enforce the argument NAME and `required`; it never
# enforced the declared TYPE, and the fallback ran in the destructive
# direction. The inversion is the point: OMITTING draft is safe and documented
# as safe, while a malformed draft published a section that had been hidden -
# so a typo was the more dangerous of the two mistakes, and the caller was told
# it had succeeded.
#
# Covered at BOTH levels, and the writer is the one that matters: every surface
# funnels through it (SM267), and the control API hands it form-encoded strings
# that no JSON schema ever sees.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files qw(action_acl_set action_acl_get);
use Lazysite::Auth::Acl      qw(load_acls);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/upcoming");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

sub set_draft {
    my ($v) = @_;
    return action_acl_set( 'upcoming', 'alice', ['alice'], undef, undef, $v );
}
sub is_draft {
    my $a = load_acls()->{upcoming};
    return ( ref $a eq 'HASH' && $a->{draft} ) ? 1 : 0;
}

# --- the values that must keep working --------------------------------------
subtest 'recognised spellings still work, in both directions' => sub {
    for my $t ( JSON::PP::true(), 1, 'true', 'TRUE', 'yes', 'on' ) {
        my $r = set_draft($t);
        ok( $r->{ok},   "'" . ( ref $t ? 'JSON true' : $t ) . "' accepted" );
        ok( is_draft(), '.. and the section is draft' );
    }
    for my $f ( JSON::PP::false(), 0, 'false', 'no', 'off', '' ) {
        my $r = set_draft($f);
        ok( $r->{ok}, "'" . ( ref $f ? 'JSON false' : ( length $f ? $f : 'empty' ) ) . "' accepted" );
        ok( !is_draft(), '.. and the section is published' );
    }
};

# --- the measured defect ----------------------------------------------------
subtest 'an unrecognised value is REFUSED, and changes nothing' => sub {
    set_draft('true');
    ok( is_draft(), 'start from a draft section' );

    for my $bad ( 'yes-please', 'enabled', 'maybe', ['true'], { a => 1 } ) {
        my $r     = set_draft($bad);
        my $shown = ref $bad ? ref $bad : $bad;
        ok( !$r->{ok}, "$shown is refused" );
        like( $r->{error} // '', qr/must be true or false/i,
            "$shown: the refusal says what is wanted" );

        # The assertion that is the whole filing: the section is STILL draft.
        # Before this, each of these published it and returned ok:1.
        ok( is_draft(), "$shown: the section is still hidden" );
    }
};

# --- and the refusal does not damage the rest of the entry ------------------
# A refused write must not half-apply: the read list the same call carried must
# not land while the draft flag is rejected.
subtest 'a refused draft leaves the whole entry untouched' => sub {
    set_draft('true');

    # CANONICAL, because load_acls builds a fresh hash each call and plain
    # encode_json follows hash order - which differs run to run. The first
    # version of this compared two non-canonical encodings and passed alone
    # while failing in the full suite, which is a flaky test rather than a
    # finding about the code.
    my $enc    = JSON::PP->new->canonical;
    my $before = $enc->encode( load_acls()->{upcoming} );

    action_acl_set( 'upcoming', 'alice', [ 'alice', 'bob' ], undef, undef, 'nonsense' );
    is( $enc->encode( load_acls()->{upcoming} ), $before,
        'the read list did not change either - the call was refused whole' );
};

done_testing();
