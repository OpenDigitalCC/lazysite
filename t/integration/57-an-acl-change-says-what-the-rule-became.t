#!/usr/bin/perl
# SM465: an acl-set is audited WITH the rule, before and after.
#
# THE GAP. The trail recorded that a permission changed, who changed it and on
# what path - and not what it changed to. So the one question an audit of a
# permission change exists to answer was the one it could not.
#
# It matters more than an ordinary omission because a rule is NOT VERSIONED the
# way content is. A page's history holds every version, so a log entry naming
# the page is enough. The ACL store holds one value, the latest, so the rule in
# force between two changes exists nowhere once the second lands - and that
# interval is exactly what an audit is asked about.
#
# NAMES ARE INCLUDED, the release manager's decision (2026-08-22) with the
# trade stated and accepted: account and group names land in the audit log,
# which may carry different retention from the account store. The rejected
# alternative - "read: 2 principals" - leaves an auditor unable to tell whether
# the RIGHT people were named, which is the whole question.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/lazysite/logs", "$docroot/section" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $pg, '>', "$docroot/section/index.md" or die $!;
print {$pg} "---\ntitle: S\n---\nBody\n";
close $pg;

sub cgi_env {
    return ( env_passthrough(), DOCUMENT_ROOT => $docroot,
        HTTP_X_REMOTE_USER => 'auditor', LAZYSITE_AUTH_TRUSTED => 1 );
}

sub api_get {
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $_[0] );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}
my $TOKEN = api_get('action=csrf-token')->{token};

sub acl_set {
    my ( $path, $payload ) = @_;
    my $body = encode_json($payload);
    my $tmp  = "$docroot/.b";
    open my $bf, '>', $tmp or die $!;
    print {$bf} $body;
    close $bf;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'POST',
        QUERY_STRING => "action=acl-set&path=$path",
        CONTENT_TYPE => 'application/json', CONTENT_LENGTH => length($body),
        HTTP_X_CSRF_TOKEN => $TOKEN );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$tmp\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}

sub audit_lines {
    open my $fh, '<', "$docroot/lazysite/logs/audit.log" or return ();
    my @l = grep { /acl-set/ } <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

subtest 'a first grant records what the rule became' => sub {
    ok( acl_set( 'section', { read => ['alice'], write => ['alice'] } )->{ok},
        'the rule is set' );
    my @l = audit_lines();
    ok( scalar @l, 'an audit entry exists' ) or return;
    like( $l[-1], qr/read: alice/, 'the read list is recorded, by name' )
        or diag( "entry was: $l[-1]" );
    like( $l[-1], qr/write: alice/, 'and the write list' );
    like( $l[-1], qr/\bnew\b/, 'and it is marked as a first grant' )
        or diag( 'An operator needs to tell a first grant from a widening.' );
};

subtest 'a change records BOTH sides' => sub {
    ok( acl_set( 'section', { read => [ 'alice', 'bob' ], write => ['alice'] } )->{ok},
        'the rule is widened' );
    my @l = audit_lines();
    like( $l[-1], qr/read: alice.*->.*read: alice, bob/,
        'the entry shows what it was and what it became' )
        or diag( "entry was: $l[-1]\n"
            . 'A rule is not versioned like content: once the next write '
            . 'lands, the previous value exists nowhere. If the trail does '
            . 'not hold it, nothing does.' );
};

subtest 'an EMPTY list is recorded as unrestricted, not as absent' => sub {
    # SM462: an empty write list means NO restriction. Recording it as absent
    # would make the trail disagree with enforcement about the single most
    # misread rule in the system.
    ok( acl_set( 'section', { read => ['alice'], write => [] } )->{ok},
        'reads restricted, writes left open' );
    my @l = audit_lines();
    like( $l[-1], qr/write: \(unrestricted\)/,
        'the trail says the writes are open' )
        or diag( "entry was: $l[-1]" );
};

subtest 'a refused acl-set still records why' => sub {
    my $before = scalar audit_lines();
    my $r      = acl_set( '', { read => ['alice'] } );
    ok( !$r->{ok}, 'acl-set with no path is refused (SM306)' );
    my @l = audit_lines();
    isnt( scalar @l, $before, 'and the refusal is audited' )
        or diag( 'A refused permission change is exactly what an audit of an '
            . 'attempted escalation would look like.' );
    unlike( $l[-1], qr/->/, 'with a reason rather than a rule that never applied' );
};

done_testing();
