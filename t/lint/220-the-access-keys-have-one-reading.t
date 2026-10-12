#!/usr/bin/perl
# SM980 (ruled 2026-10-11, "Parse it + fail closed"): a page's access keys -
# auth, auth_groups, payment - have one reading everywhere.
#
# The gate reads them in the processor (lazysite-processor/front-matter.pm,
# _access_keys_read, called by auth.pm's peek and by parse_yaml_front_matter).
# `lazysite validate` and validate_page cannot load the processor, so
# Lazysite::Validate::read_access_keys is a MARKED COPY of that reading (ADR
# 0001's convention for a copy: allowed, marked, pinned). This is the pin: if
# the two disagreed, the validator would pass a page the gate refuses to
# everyone, or report one the gate serves.
#
# ASSERTED BY RUNNING BOTH ON THE SAME TEXTS, as t/lint/125, 129 and 219 do -
# never by comparing source: the strings themselves, a seeded generator of the
# fragments a hand-rolled reader gets wrong, and pages written to a site and read
# back through the gate's own peek.
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper         qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Validate ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

# SM993: both take where the page is - undef (unknown), 'content' or 'manager'.
sub proc { my ( $t, $w ) = @_; utf8::upgrade($t); return main::_access_keys_read( $t, $w ) }
sub lib { return Lazysite::Validate::read_access_keys( $_[0], $_[1] ) }

my @TEXTS = (
    "auth: required\nauth_groups:\n  - readers\n  - sysops\n",
    "auth: required\nauth_groups: [readers, sysops]\n",
    "auth_groups: [ \"readers\" , 'sysops' ]  # the team\n",
    "auth_groups: []\n",
    "auth_groups: [ ]\n",
    "auth_groups: readers\n",
    "auth_groups:\n",
    "auth_groups:\ntitle: T\n",
    "auth_groups: [readers, sysops\n",
    "auth_groups: [readers,]\n",
    "auth_groups: [read ers]\n",
    "auth_groups: [readers]\n  - sysops\n",
    "auth_groups:\n  - readers\n  nested: x\n",
    "auth_groups:\n  - readers # a comment\n\n  - 'sysops'\n",
    "auth_groups:\n  -\n",
    "auth_groups:\n- readers\n",    # a dash at column 0 is not under the key
    "AUTH_GROUPS: [readers]\n",
    "auth_groups: [a.b, c_d, e-f]\n",
    "auth_groups: [x]\nauth_groups: [y]\n",
    "auth: \"required\"\n",
    "auth: 'Required'\n",
    "auth: [required]\n",
    "auth: members\n",
    "auth: required # members only\n",
    "auth:\n",
    "Auth: required\n",
    "auth: manager\n",
    "payment: \"required\"\n",
    "payment: Required\n",
    "payment: yes\n",
    "payment: none\n",
    "payment_amount: 1\n",
    "title: T\r\nauth: required\r\nauth_groups: [a, b]\r\n",
    "tt_page_var:\n  auth: x\n",
    "sections:\n  - auth_groups: [x]\n",
    "",
);
for my $t (@TEXTS) {
    for my $w ( undef, 'content', 'manager' ) {
        is_deeply( proc( $t, $w ), lib( $t, $w ),
            'one reading (' . ( $w // 'anywhere' ) . '): ' . ( $t =~ s/\n/\\n/gr ) );
    }
}

subtest 'the pin can see a difference at all' => sub {
    is_deeply( proc("auth_groups: [a]\n")->{unreadable}, {}, 'a readable list is not unreadable' );
    is_deeply( proc("auth_groups:\n- a\n- b\n")->{auth_groups}, [qw(a b)],
        'a block list at the key\'s own column is read (valid YAML)' );
    is_deeply( proc("auth_groups: [a, b]\n")->{auth_groups}, [qw(a b)], 'the flow list is read' );
    ok( proc("auth_groups: a\n")->{unreadable}{auth_groups}, 'a bare name is not a list' );
    ok( proc("auth: \"x\"\n")->{unreadable}{auth}, 'an unknown auth value is unreadable' );
    ok( proc( "auth: manager\n", 'content' )->{unreadable}{auth}, 'auth: manager on a content page is unreadable' );
    is( proc( "auth: manager\n", 'manager' )->{auth}, 'manager', 'and read under the manager path' );
    is( proc("auth: manager\n")->{auth}, 'manager', 'and where the reader is not told' );
};

# A seeded generator: fragments a hand-rolled reader gets wrong, combined.
my @FRAG = (
    'auth_groups: [a, b]', "auth_groups:\n  - a\n  - b", 'auth_groups: a', 'auth_groups: []',
    "auth_groups:\n  - 'a'", 'auth_groups: ["a" , b ] # c', "auth_groups:\n  - a\n  x: y",
    'auth: required', 'auth: manager', 'auth: "optional"', 'auth: none', 'auth: yes', 'auth:', 'AUTH: Required',
    'payment: required', 'payment: "Required"', 'payment: maybe', 'title: T', 'form: f',
    "query_params:\n  - q", "tags:\n  - auth_groups", '# a comment', '',
);
srand(980);
for my $n ( 1 .. 300 ) {
    my $t = join "\n", map { $FRAG[ int rand @FRAG ] } 1 .. 1 + int rand 5;
    $t .= "\n";
    my $w = ( undef, 'content', 'manager' )[ int rand 3 ];
    my ( $p, $l ) = ( proc( $t, $w ), lib( $t, $w ) );
    is_deeply( $p, $l, "generated #$n" ) or do { diag( 'text: ' . ( $t =~ s/\n/\\n/gr ) ); last };
}

# Through the gate's own peek: a page on disk, read as the processor reads it.
my $i = 0;
for my $t (@TEXTS) {
    $i++;
    my $f = "$d/pin-$i.md";
    open my $fh, '>:utf8', $f or die $!;
    print {$fh} "---\n$t---\nbody\n";
    close $fh;
    main::_reset_peek_cache();
    my $peek = main::peek_auth($f);
    my $want = lib($t);
    is_deeply( $peek->{unreadable} // {}, $want->{unreadable}, "peek agrees on what is unreadable: page $i" );
    is_deeply( $peek->{groups}, ( $want->{auth_groups} && @{ $want->{auth_groups} } ? $want->{auth_groups} : [] ),
        "peek agrees on the groups: page $i" );
}

done_testing();
