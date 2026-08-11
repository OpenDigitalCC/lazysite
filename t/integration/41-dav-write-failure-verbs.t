#!/usr/bin/perl
# SM284: all five WebDAV write verbs against ONE unwritable directory.
#
# SM235 made a PUT into an unwritable directory explain itself: 507 (the request
# is valid and the server is at fault, which a 403 would deny), the condition
# named, the server-fault-versus-permission-decision distinction stated, and no
# filesystem path. DELETE, MOVE, COPY and MKCOL met the identical condition and
# answered "Delete failed", "Operation failed" or a 409 worded almost exactly
# like the one MKCOL returns for a genuinely missing parent. An agent that meets
# those has nothing to decide with: retry, ask, or give up are all consistent
# with a bare 500.
#
# The fixture is the same for all five, which is most of why doing four together
# is cheaper than doing one - and why it took this long to notice that only one
# was covered. SM235's own test is a SOURCE-TEXT test, because a CI image running
# as root makes every directory writable and the branch unreachable. That is a
# real constraint and it is also how four verbs stayed uncovered: a source match
# proves a call site exists, never that the response is right. This drives the
# CGI for real and skips when it cannot.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_dav_site);

if ( $> == 0 ) {
    plan skip_all => 'running as root: every directory is writable, so the '
        . 'condition under test cannot be created';
}

my $root = repo_root();
my $site = setup_dav_site();
my $d    = $site->{docroot};

my $LOCKED = "$d/content/locked";
make_path($LOCKED);

sub spit {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return;
}

# Inside the directory we are about to lock: a delete target and a move source.
spit( "$LOCKED/victim.md", "---\ntitle: V\n---\nvictim\n" );
spit( "$LOCKED/mover.md",  "---\ntitle: M\n---\nmover\n" );
# Outside it: a copy source, so the COPY case fails on the DESTINATION side.
spit( "$d/content/source.md", "---\ntitle: S\n---\nsource\n" );

chmod 0555, $LOCKED or die "chmod: $!";
ok( !-w $LOCKED, 'the fixture directory is genuinely unwritable' )
    or plan skip_all => 'could not make a directory unwritable here';

# Drive the real CGI. Body on stdin via a file, the way a web server delivers it.
sub dav {
    my (%o)  = @_;
    my $body = defined $o{body} ? $o{body} : '';
    my $bf   = tempdir( CLEANUP => 1 ) . '/body';
    spit( $bf, $body );

    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{HTTP_AUTHORIZATION}      = $site->{auth};
    $ENV{REQUEST_METHOD}          = $o{method};
    $ENV{PATH_INFO}               = $o{path};
    $ENV{CONTENT_LENGTH}          = length $body;
    if ( defined $o{destination} ) {
        $ENV{HTTP_DESTINATION} = "/dav$o{destination}";
    }
    else {
        delete $ENV{HTTP_DESTINATION};
    }
    return scalar qx(sh -c \Q$^X \Q$root/lazysite-dav.pl\E < \Q$bf\E 2>/dev/null\E);
}

# What every one of the five owes the caller. Kept as one sub because the point
# of the filing is that the five answers must have the SAME SHAPE - stating it
# once is the assertion.
sub asserts_server_fault {
    my ( $out, $label ) = @_;
    like( $out, qr/Status:\s*507/, "$label: 507 - valid request, server at fault" );
    like( $out, qr/is not writable by the server/i,
        "$label: names the condition" );
    like( $out, qr/not a permission decision about your request/i,
        "$label: separates a server fault from a refusal, which is the "
            . 'distinction an agent decides on' );
    like( $out, qr/operator must fix/i, "$label: names who can fix it" );
    unlike( $out, qr/\Q$d\E/,             "$label: no filesystem path" );
    unlike( $out, qr{/home/|/tmp/|/var/}, "$label: no filesystem path at all" );
    return;
}

subtest 'PUT - the case SM235 already covered, as the control' => sub {
    my $out = dav(
        method => 'PUT',
        path   => '/content/locked/new.md',
        body   => "---\ntitle: N\n---\nnew\n",
    );
    asserts_server_fault( $out, 'PUT' );
};

subtest 'DELETE - was a bare 500 with "Delete failed"' => sub {
    my $out = dav( method => 'DELETE', path => '/content/locked/victim.md' );
    asserts_server_fault( $out, 'DELETE' );
    ok( -e "$LOCKED/victim.md", 'and the entry is still there, as the status says' );
};

subtest 'MKCOL - was a 409, indistinguishable from a missing parent' => sub {
    my $out = dav( method => 'MKCOL', path => '/content/locked/newdir' );
    asserts_server_fault( $out, 'MKCOL' );

    # The other 409. Both used to say "Cannot create collection"; a caller could
    # not tell "create the parent first" from "the operator must fix a
    # permission", which are different problems with different fixes.
    my $missing = dav( method => 'MKCOL', path => '/content/nope/deeper' );
    like( $missing, qr/Status:\s*409/, 'a missing parent is still 409' );
    like( $missing, qr/parent collection does not exist/i,
        'and says so - it is the CALLER who acts, by creating the parent' );
    unlike( $missing, qr/Status:\s*507/,   'not conflated with the server fault' );
    unlike( $missing, qr/is not writable/, 'and not worded like it either' );
};

subtest 'MOVE - the two-directory case, failing on the SOURCE' => sub {
    my $out = dav(
        method      => 'MOVE',
        path        => '/content/locked/mover.md',
        destination => '/content/moved.md',
    );
    asserts_server_fault( $out, 'MOVE' );
    like( $out, qr/source directory/i,
        'MOVE names WHICH directory - it has two, and the destination here is '
            . 'perfectly writable' );

    # The bug this case exposed: the removal was performed for effect and never
    # checked, so the copy-then-remove fallback answered 201 with both copies
    # live. A MOVE that leaves the original in place is a COPY, and the client
    # was told otherwise.
    ok( -e "$LOCKED/mover.md", 'the source survives, which is why it failed' );
    ok( !-e "$d/content/moved.md",
        'and no half-move is left at the destination reporting success' );
};

subtest 'COPY - failing on the DESTINATION' => sub {
    my $out = dav(
        method      => 'COPY',
        path        => '/content/source.md',
        destination => '/content/locked/copy.md',
    );
    asserts_server_fault( $out, 'COPY' );
    like( $out, qr/destination directory/i, 'COPY names the destination side' );
    ok( -e "$d/content/source.md", 'the source is untouched by a failed COPY' );
};

# --- and the ordinary path is unaffected -------------------------------------
# A helper that answers 507 whenever anything goes wrong would be worse than the
# bare 500 it replaced. The verbs must still succeed where they always did.
subtest 'the same five verbs still work on a writable directory' => sub {
    my $put = dav(
        method => 'PUT',
        path   => '/content/ok.md',
        body   => "---\ntitle: OK\n---\nfine\n",
    );
    like( $put, qr/Status:\s*20[01]/, 'PUT succeeds' );

    my $mkcol = dav( method => 'MKCOL', path => '/content/newdir' );
    like( $mkcol, qr/Status:\s*201/, 'MKCOL succeeds' );

    my $copy = dav(
        method      => 'COPY',
        path        => '/content/ok.md',
        destination => '/content/ok-copy.md',
    );
    like( $copy, qr/Status:\s*20[1-4]/, 'COPY succeeds' );
    ok( -e "$d/content/ok-copy.md", 'and the copy exists' );

    my $move = dav(
        method      => 'MOVE',
        path        => '/content/ok-copy.md',
        destination => '/content/ok-moved.md',
    );
    like( $move, qr/Status:\s*20[1-4]/, 'MOVE succeeds' );
    ok( -e "$d/content/ok-moved.md", 'the entry is at the destination' );
    ok( !-e "$d/content/ok-copy.md", 'and gone from the source - a real move' );

    my $del = dav( method => 'DELETE', path => '/content/ok-moved.md' );
    like( $del, qr/Status:\s*204/, 'DELETE succeeds' );
    ok( !-e "$d/content/ok-moved.md", 'and the entry is gone' );
};

# Leave the tree removable so CLEANUP can do its job.
chmod 0755, $LOCKED;

done_testing();
