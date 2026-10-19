#!/usr/bin/perl
# SM1131 (SM1128 phase 1, P1-2): NOTHING BUT THE ONE ACCESSOR READS THE IDENTITY
# HEADERS.
#
# Six readers each held their own answer to "who is calling": the page gate honoured
# the configured header names (auth_header_user and its three siblings, SM960) and
# the manager entry, the manager API, the per-file ACL code, the layout's admin bar
# and two data readers read the fixed HTTP_X_REMOTE_* names - so a proxy sending
# `Remote-User` opened a page and not the manager, and a groups header split on
# commas in one and on commas or whitespace in another.
#
# Lazysite::Auth::Identity::request_identity is the reader now. This pins the
# arrangement: no code outside it names HTTP_X_REMOTE_USER/_NAME/_EMAIL/_GROUPS or
# reads a configured auth_header_* name, except
#
#   - the PRODUCERS: lazysite-auth.pl (sets them from a verified cookie) and
#     lazysite-data.pl (the same, for its own verified session);
#   - the TRUST GATES, which strip them: apply_trust_gate in the processor and the
#     gate block at the top of the manager API.
#
# and every reader named in SM1131 calls the accessor.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "$f: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

sub code_of {
    my ($t) = @_;
    $t =~ s/^\s*#.*$//mg;     # whole-line comments
    $t =~ s/\s#\s.*$//mg;     # trailing comments
    $t =~ s/^__END__.*//ms;
    $t =~ s/^=\w+.*?^=cut\s*$//msg;    # pod
    return $t;
}

my @files;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            my $p = $File::Find::name;
            if ( -d $p ) {
                $File::Find::prune = 1 if $p =~ m{/(?:t|tmp|\.git|dist|docs|node_modules|download)\z};
                return;
            }
            push @files, $p if $p =~ /\.(?:pl|pm)\z/;
        },
    },
    $root
);

my $NAMES  = qr/HTTP_X_REMOTE_(?:USER|NAME|EMAIL|GROUPS)/;
my $CONFIG = qr/\bauth_header_(?:user|name|email|groups)\b/;

# Whole files allowed to name the fixed headers, and why.
my %ALLOW = (
    'lib/Lazysite/Auth/Identity.pm' => 'the accessor',
    'lazysite-auth.pl'              => 'producer: sets them from the verified cookie',
    'lazysite-data.pl'              => 'producer: sets them from its own verified session',
);

# A region of a file that is a trust gate: [ start marker, end marker ].
my %GATE = (
    'lazysite-processor.pl' => [ 'sub apply_trust_gate', 'sub handle_manager_path' ],
    'lazysite-manager-api.pl' => [ '# --- Trust gate', '# SM1131: THE REQUEST' ],
);

my @stray;
for my $f ( sort @files ) {
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    next if $ALLOW{$rel};
    my $code = code_of( slurp($f) );
    if ( my $g = $GATE{$rel} ) {
        my ( $from, $to ) = @$g;
        my $i = index( $code, $from );
        # the markers are comments in some cases: search the raw text instead
        my $raw = slurp($f);
        $i = index( $raw, $from );
        my $j = index( $raw, $to, $i + 1 );
        die "$rel: gate markers not found\n" if $i < 0 || $j < 0;
        $code = code_of( substr( $raw, 0, $i ) . substr( $raw, $j ) );
    }
    push @stray, "$rel: names a fixed identity header" if $code =~ $NAMES;
    push @stray, "$rel: builds a configured header's environment name" if $code =~ $CONFIG;
}
is_deeply( \@stray, [], 'no reader outside the accessor (and the producers and trust gates) names the identity headers' )
    or diag( join "\n", @stray );

# The readers SM1131 names all go through the accessor.
my %READER = (
    'lazysite-processor/auth.pm'    => qr/_request_identity\(\s*conf/,
    'lazysite-processor.pl'         => qr/_request_identity\(\s*conf/,
    'lazysite-processor/layout.pm'  => qr/_request_identity\(/,
    'lazysite-processor/sources.pm' => qr/_request_identity\(/,
    'lazysite-manager-api.pl'       => qr/request_identity\(\s*lazysite_dir/,
    'lib/Lazysite/Auth/Acl.pm'      => qr/Identity::request_identity\(/,
    # SM1130: the wrapper's "does a trusted proxy name a user" is the reader's
    # answer too (it is a producer of the fixed names, so the sweep above allows
    # the file; this holds its read of the PROXY's user to the accessor).
    #
    # SM1181 S1: that read is Lazysite::Auth::Session::request_session's now, the one
    # decision the wrapper and the data endpoint both ask; each passes the proxy
    # answer it holds, and the function reads the proxy's user through the accessor.
    'lazysite-auth.pl'             => qr/Session::request_session\(\s*lazysite_dir\s*=>\s*\$LAZYSITE_DIR,\s*proxy\s*=>/,
    'lazysite-data.pl'             => qr/Session::request_session\(\s*lazysite_dir\s*=>\s*\$lz,\s*proxy\s*=>/,
    'lib/Lazysite/Auth/Session.pm' => qr/Identity::request_identity\(\s*lazysite_dir\s*=>\s*\$dir,\s*proxy\s*=>/,
    # SM1181 S3: the pool's front door decides a wrapped page by the same function,
    # with the render path's proxy answer (the gate's) and the request's own Cookie
    # header.
    'lazysite-processor/front-door.pm' =>
        qr/Session::request_session\(\s*lazysite_dir\s*=>\s*\$LAZYSITE_DIR,\s*proxy\s*=>\s*_proxy_identity\(\),\s*cookie\s*=>\s*\$cookie\s*\)/,
);
for my $rel ( sort keys %READER ) {
    like( code_of( slurp("$root/$rel") ), $READER{$rel}, "$rel reads the identity through the accessor" );
}
like( code_of( slurp("$root/lazysite-processor/auth.pm") ), qr/Lazysite::Auth::Identity::request_identity/,
    'and the processor reaches the accessor itself' );

# SM1181 S2 (SM1082 C2, T14, R3): THE SENTINEL, TOO.
#
# LAZYSITE_AUTH_TRUSTED is what makes the fixed names count, so a reader of it is
# a reader of identity. In a pooled worker it is a FastCGI parameter and is never
# believed (R3): the only trusted producer there is the value the front door holds
# (S3). This holds that every file - the front door's part and Session.pm among
# them, which is where the pool's identity will be decided - names the sentinel
# only where it is produced (the accessor's writer, the data endpoint) or judged
# (the accessor, the two trust gates); and that the processor's two judgements of
# it ask the runtime, and the processor hands the accessor its held value.
subtest 'the sentinel is read only by the accessor and the trust gates, never believed in the pool' => sub {
    my %SENTINEL_ALLOW = (
        'lib/Lazysite/Auth/Identity.pm' => 'the accessor (and write_identity_env, the wrapper\'s contract)',
        'lazysite-data.pl'              => 'producer: sets it for what it calls, from its own verified session',
    );
    my @named;
    for my $f ( sort @files ) {
        ( my $rel = $f ) =~ s{^\Q$root\E/}{};
        next if $SENTINEL_ALLOW{$rel};
        my $raw = slurp($f);
        if ( my $g = $GATE{$rel} ) {
            my $i = index( $raw, $g->[0] );
            my $j = index( $raw, $g->[1], $i + 1 );
            $raw = substr( $raw, 0, $i ) . substr( $raw, $j );
        }
        push @named, $rel if code_of($raw) =~ /\bLAZYSITE_AUTH_TRUSTED\b/;
    }
    is_deeply( \@named, [], 'no code outside the accessor, the data endpoint and the trust gates names the sentinel' )
        or diag( join "\n", @named );

    # SM1181 S3 (R4): nor while a value is held, on either runtime.
    my $proc = code_of( slurp("$root/lazysite-processor.pl") );
    like( $proc, qr/\(\s*ref\s+\$REQUEST_IDENT\s+eq\s+'HASH'\s*\|\|\s*_runtime\(\)\s*eq\s*'pool'\s*\)\s*\?\s*''\s*:\s*\(\s*\$ENV\{LAZYSITE_AUTH_TRUSTED\}/,
        'the processor\'s trust gate does not believe the sentinel in the pool, nor while a value is held' );
    like( code_of( slurp("$root/lib/Lazysite/Auth/Identity.pm") ), qr/!\$opt\{pool\}\s*&&\s*\(\s*\$ENV\{LAZYSITE_AUTH_TRUSTED\}/,
        'the accessor does not believe it when told it is in the pool' );
    my $auth = code_of( slurp("$root/lazysite-processor/auth.pm") );
    like( $auth, qr/request_identity\([^;]*\bidentity\s*=>\s*\$REQUEST_IDENT\b/s,
        'the processor hands the accessor the request\'s held identity value' );
    like( $auth, qr/request_identity\([^;]*\bpool\s*=>\s*\(\s*_runtime\(\)\s*eq\s*'pool'/s,
        'and tells it when it is a pooled worker' );
};

done_testing();
