#!/usr/bin/perl
# SM084 restore (eight-dimension review D5): the manager can restore a content
# snapshot. Round trip: snapshot v1 -> mutate to v2 + add a file -> restore ->
# v1 content is back, newer files survive (overlay semantics), a prerestore
# safety snapshot containing v2 exists (the restore is reversible), render
# caches for restored sources are cleared, and legacy static .html (no .md
# sibling, SM133) is untouched.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }
sub op {
    my ( $d, $qs ) = @_;
    return mapi( $d,
        REQUEST_METHOD       => 'POST',
        HTTP_X_REMOTE_USER   => 'admin',
        HTTP_X_REMOTE_GROUPS => 'managers',
        HTTP_X_CSRF_TOKEN    => csrf('admin'),
        QUERY_STRING         => $qs,
        body                 => '{}',
    );
}
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { open my $fh, '>', $_[0] or die $!; print $fh $_[1]; close $fh }

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
spit( "$d/lazysite/lazysite.conf", "manager: enabled\nmanager_groups: managers\n" );
spit( "$d/lazysite/auth/.secret",  $secret );

# v1 content + a render cache + a legacy static page (no .md sibling).
spit( "$d/page.md",     "---\ntitle: P\n---\n\nversion ONE\n" );
spit( "$d/page.html",   "<html>rendered cache of v1</html>" );
spit( "$d/legacy.html", "<html>LEGACY STATIC - not a cache</html>" );

# --- snapshot v1 ---
my $c = op( $d, 'action=backup-create' );
ok( $c->{ok}, 'backup-create ok' ) or diag explain $c;
my $snap = $c->{name};
like( $snap, qr/^manual-.*\.tar\.gz$/, 'manual snapshot named' );

# --- mutate: v2 + a new file ---
sleep 1;    # distinct timestamp for the prerestore snapshot name
spit( "$d/page.md",  "---\ntitle: P\n---\n\nversion TWO\n" );
spit( "$d/extra.md", "---\ntitle: X\n---\n\nadded after the snapshot\n" );

# --- restore ---
my $r = op( $d, "action=backup-restore&name=$snap" );
ok( $r->{ok}, 'backup-restore ok' ) or diag explain $r;
is( $r->{restored}, $snap, 'reports the restored snapshot' );
like( $r->{safety}, qr/^prerestore-.*\.tar\.gz$/, 'a prerestore safety snapshot was taken' );

like(   slurp("$d/page.md"), qr/version ONE/, 'restored file carries the snapshot content' );
ok(     -f "$d/extra.md",                     'file added after the snapshot survives (overlay)' );
ok(     !-f "$d/page.html",                   'render cache for a restored source was cleared' );
is(     slurp("$d/legacy.html"), "<html>LEGACY STATIC - not a cache</html>",
        'legacy static .html (no .md sibling) untouched by the cache clear' );
ok(     -f "$d/lazysite/backups/$r->{safety}", 'safety snapshot exists on disk' );

# The safety snapshot must contain the PRE-restore state (v2) - reversibility.
my $peek = qx(tar xzf \Q$d/lazysite/backups/$r->{safety}\E -O ./page.md 2>/dev/null);
like( $peek, qr/version TWO/, 'safety snapshot preserves the pre-restore content' );

# --- the restore is audited ---
my $audit = slurp("$d/lazysite/logs/audit.log") // '';
like( $audit, qr/backup-restore/, 'restore recorded in the audit trail' );

# --- refusals ---
ok( !op( $d, 'action=backup-restore&name=../evil.tar.gz' )->{ok}, 'traversal name refused' );
ok( !op( $d, 'action=backup-restore&name=nope.tar.gz' )->{ok},    'missing backup refused' );

done_testing();
