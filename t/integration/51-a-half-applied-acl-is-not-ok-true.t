#!/usr/bin/perl
# SM650: an ACL that was saved but could not move its content reported ok:true.
#
# The rule is in force and the engine honours it. The files never left the
# document root, so a front end that serves them without asking the engine is
# not covered. Both facts were in the reply - the first in `ok`, the second in
# `content_move_failed` and a warning - and a caller reads `ok`.
#
# The underlying condition is a HOST fault (a docroot back from a control-panel
# rebuild without group write, SM270) and the warning says so plainly: it names
# the fault as server configuration rather than a permission decision, names the
# diagnostic and names the repair. The REPORTING was the defect.
#
# It was invisible from both ends: the API said success, and proving the gate by
# hand confirmed it - everything under the rule answers 302 to an anonymous
# visitor. What is left undone only matters when something serves those files
# without asking the engine, which is the one thing nobody re-tests once the
# gate is proved.
#
# WHAT IS ASSERTED
#   a half-applied rule is NOT ok:true
#   it says the rule IS IN FORCE, because it is - a caller that backed out on a
#     false would otherwise remove a working rule
#   the warning text is unchanged and still carries the diagnostic
#   the rule really was written, and really does gate
#   a rule that applies cleanly is still ok:true - the refusal is not blanket
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename qw(dirname basename);
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/probe" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $pg, '>', "$docroot/probe/index.md" or die $!;
print {$pg} "---\ntitle: Probe\n---\n\nSecret-ish.\n";
close $pg;

my $users = "$root/tools/lazysite-users.pl";
qx($^X \Q$users\E --docroot \Q$docroot\E setup-manager pw123456789 2>/dev/null);

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'setup-manager',
        LAZYSITE_AUTH_TRUSTED => 1,
    );
}

# A REAL CSRF TOKEN, because the POST path requires one and a test that skips
# it measures the CSRF gate instead of the thing it came to measure - which is
# what the first version of this file did, reporting "Invalid or missing CSRF
# token" for every case.
my $TOKEN = do {
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET',
        QUERY_STRING => 'action=csrf-token' );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    ( eval { decode_json($out) } || {} )->{token};
};
ok( $TOKEN, 'a CSRF token was obtained' ) or BAIL_OUT('no token, nothing below is testing acl-set');

sub api {
    my ( $qs, $body ) = @_;
    return do {
        local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
        my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
        $out =~ s/\A.*?\r?\n\r?\n//s;
        eval { decode_json($out) } || { _raw => $out };
    } unless defined $body;

    my $json = encode_json($body);
    my $tmp  = "$docroot/.post-body";
    open my $bf, '>', $tmp or die $!;
    print {$bf} $json;
    close $bf;

    local %ENV = (
        cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length($json),
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$tmp\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { _raw => $out };
}


# The private store is where protected content is moved to. Made unwritable so
# the move fails exactly as it does on a docroot that came back from a
# control-panel rebuild - the condition SM270 describes.
my $priv = dirname($docroot) . '/' . basename($docroot) . '-lazysite-private';
make_path($priv);
chmod 0500, $priv;

my $half = api( 'action=acl-set&path=/probe', { read => ['setup-manager'] } );

SKIP: {
    skip 'the move succeeded - cannot simulate the host fault as this user', 5
        unless $half->{content_move_failed};

    ok( !$half->{ok}, 'a half-applied rule is not ok:true' )
        or diag( 'ok:true here is indistinguishable from a clean apply, and '
            . '`ok` is the field every caller reads' );
    is( $half->{kind}, 'partial', 'it names the state rather than only failing' );
    like( $half->{error} // '', qr/IN FORCE/,
        'and says the rule is in force - backing out would remove a working rule' );
    like( join( ' ', @{ $half->{warnings} || [] } ), qr/server configuration/,
        'the warning still names the fault as a host one, unchanged' );

    # The claim in the error has to be true, or it is worse than the ok:true it
    # replaced: a refusal that says "in force" while nothing was written would
    # be a second wrong answer.
    my $back = api('action=acl-get&path=/probe');
    ok( ( $back->{acl} && ref $back->{acl}{read} eq 'ARRAY'
            && @{ $back->{acl}{read} } ),
        'the rule really was written - the error tells the truth' );
}

chmod 0700, $priv;

# --- and a clean apply is still a success ----------------------------------
# Without this the fix could be "always refuse", which would pass everything
# above and break every ordinary call.
my $clean = api( 'action=acl-set&path=/probe', { read => ['setup-manager'] } );
ok( $clean->{ok}, 'a rule that applies cleanly is still ok:true' )
    or diag( $clean->{error} // 'no error' );
ok( !$clean->{content_move_failed}, 'and reports no failed move' );

done_testing();
