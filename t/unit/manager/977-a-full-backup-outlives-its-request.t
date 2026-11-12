#!/usr/bin/perl
# SM1446 (ruling 248): A FULL BACKUP OUTLIVES ITS REQUEST.
#
# On a large instance tar outlasts every deadline in front of the manager, so the
# request that took a full backup was killed mid-tar. A full backup now runs in a
# worker detached from the request (Lazysite::Util::detach): the request answers
# at once with the name and in_progress, and a pid marker beside the claim lets
# the listing tell a backup being taken from one that stopped.
#
# Driven through lazysite-manager-api.pl with stand-in tars:
#   - a tar that takes longer than the caller waits: backup-create answers before
#     tar could have finished, with in_progress and the name; the listing shows it
#     in progress (not as a backup, not as unfinished); it then finishes and is
#     listed as a backup with a verified sha256 and no marker left; the trail has
#     the worker's start and outcome rows, naming the file, and no other row;
#   - a tar that hangs, whose worker is killed with KILL: the listing says
#     unfinished, not in progress;
#   - a marker whose process is alive but which is older than the stated age, or
#     whose process is gone, is unfinished - never in progress for ever, and does
#     not block a new full backup;
#   - while a full backup is in progress another is refused (in-progress, 409),
#     naming the running one and when it started, and nothing is claimed.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_child site_tempdir);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my ($real_tar) = grep { -x } map { "$_/tar" } split /:/, $ENV{PATH};
plan skip_all => 'no tar on PATH' unless $real_tar;

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/backups" );
spit( "$d/lazysite/lazysite.conf", "manager: enabled\nmanager_groups: managers\n" );
spit( "$d/lazysite/auth/.secret",  $secret );
spit( "$d/page.md",                "---\ntitle: P\n---\n\nbody\n" );
my $bk  = "$d/lazysite/backups";
my $bin = "$d/../fakebin";
make_path($bin);
my $pidf = "$d/../tar.pid";

# A tar that records its pid, then either waits N seconds and runs the real tar
# (slow) or begins a gzip stream and hangs (hang).
spit( "$bin/tar", <<"PERL" );
#!/usr/bin/perl
open my \$p, '>', \$ENV{N824_TAR_PID} or exit 2;
print {\$p} \$\$;
close \$p;
if ( \$ENV{N824_TAR_MODE} eq 'slow' ) { sleep 3; exec '$real_tar', \@ARGV; exit 2 }
open my \$o, '>', \$ARGV[1] or exit 2;
print {\$o} "\\x1f\\x8b\\x08\\x00\\x00\\x00\\x00\\x00\\x00\\x03";
close \$o;
sleep 120;
exit 0;
PERL
chmod oct('0755'), "$bin/tar" or die $!;

sub api {
    my ( $qs, $method, %env ) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS)};
    %ENV = ( %ENV,
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => $method,
        QUERY_STRING          => $qs,
        CONTENT_LENGTH        => ( $method eq 'POST' ? 2 : 0 ),
        HTTP_X_REMOTE_USER    => 'admin',
        HTTP_X_REMOTE_GROUPS  => 'managers',
        HTTP_X_CSRF_TOKEN     => hmac_sha256_hex( 'csrf:admin:' . int( time() / 3600 ), $secret ),
        LAZYSITE_AUTH_TRUSTED => 1,
        %env );
    my $out = run_child( [ $^X, $mapi ], stdin => '{}', timeout => 60 )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub names { my ( $l, $k ) = @_; return [ map { $_->{name} } @{ $l->{$k} || [] } ] }

sub wait_for {
    my ( $cond, $secs ) = @_;
    my $until = Time::HiRes::time() + $secs;
    until ( $cond->() ) {
        return 0 if Time::HiRes::time() > $until;
        Time::HiRes::sleep(0.2);
    }
    return 1;
}

# --- a tar that takes longer than the caller waits -----------------------------------
my $t0 = Time::HiRes::time();
my $c  = api( 'action=backup-create&scope=full', 'POST',
    PATH => "$bin:$ENV{PATH}", N824_TAR_PID => $pidf, N824_TAR_MODE => 'slow' );
my $took = Time::HiRes::time() - $t0;
ok( $c->{ok}, 'a full backup is started' ) or diag explain $c;
ok( $c->{in_progress}, 'and answered as in progress' );
like( $c->{name} // '', qr/\Alazysite-full-\d{8}T\d{6}Z\.tar\.gz\z/, 'with its name' );
cmp_ok( $took, '<', 3, 'before its tar could have finished (it waits 3 s first)' );
my $name = $c->{name} // '';

my $l = api( 'action=backup-list', 'GET' );
is_deeply( names( $l, 'in_progress' ), [$name], 'while it runs the listing shows it in progress' )
    or diag explain $l;
is_deeply( names( $l, 'backups' ),    [], 'not as a backup' );
is_deeply( names( $l, 'unfinished' ), [], 'and not as unfinished' );

ok( wait_for( sub { grep { $_ eq $name } @{ names( api( 'action=backup-list', 'GET' ), 'backups' ) } }, 60 ),
    'it finishes after its request has ended, and is listed as a backup' );
my ($row) = grep { $_->{name} eq $name } @{ api( 'action=backup-list', 'GET' )->{backups} || [] };
is( $row->{sha256_status}, 'verified', 'with a verified sha256' );
ok( !-e "$bk/.$name.pid", 'and no marker left beside it' );
my @rows = grep { /\| backup-create \| full \|/ } split /\n/, slurp("$d/lazysite/logs/audit.log");
is( scalar @rows, 2, 'the trail has two rows for it' ) or diag join "\n", @rows;
like( $rows[0] // '', qr/\| started \| ui \| file=\Q$name\E\z/, "the worker's start, naming the file" );
like( $rows[1] // '', qr/\| ok \| ui \| file=\Q$name\E\z/,      "and its outcome" );

# --- a worker killed with KILL ------------------------------------------------------
unlink $pidf;
my $h = api( 'action=backup-create&scope=full', 'POST',
    PATH => "$bin:$ENV{PATH}", N824_TAR_PID => $pidf, N824_TAR_MODE => 'hang' );
my $hname = $h->{name} // '';
ok( $h->{in_progress}, 'a second full backup is started' ) or diag explain $h;
ok( wait_for( sub { -s $pidf }, 30 ), 'its tar is running' );
my ($worker) = slurp("$bk/.$hname.pid") =~ /\A(\d+) /;
ok( $worker && kill( 0, $worker ), 'the marker names a live worker' );
is_deeply( names( api( 'action=backup-list', 'GET' ), 'in_progress' ), [$hname], 'listed in progress' );
kill 'KILL', $worker;
wait_for( sub { !kill 0, $worker }, 10 );
my $tar = slurp($pidf);
kill 'KILL', $tar if $tar =~ /\A\d+\z/;
my $k = api( 'action=backup-list', 'GET' );
is_deeply( names( $k, 'in_progress' ), [], 'once the worker is killed it is not in progress' );
is_deeply( names( $k, 'unfinished' ), [$hname], 'it is unfinished' ) or diag explain $k;
unlink "$bk/$hname", "$bk/.$hname.pid";
system( 'rm', '-rf', glob("$bk/.stage-*") );

# --- a stale marker is unfinished, never in progress for ever --------------------------
{
    no warnings 'once';
    my $old = 'lazysite-full-20261101T000000Z.tar.gz';
    spit( "$bk/$old", '' );
    spit( "$bk/.$old.pid", "$$ " . ( time - 7 * 3600 ) . "\n" );
    my $dead = 'lazysite-full-20261102T000000Z.tar.gz';
    spit( "$bk/$dead", '' );
    spit( "$bk/.$dead.pid", '999999999 ' . time . "\n" );
    my $s = api( 'action=backup-list', 'GET' );
    is_deeply( names( $s, 'in_progress' ), [], 'a marker older than the stated age, or of a dead process, is not in progress' );
    is_deeply( [ sort @{ names( $s, 'unfinished' ) } ], [ $old, $dead ], 'both are unfinished' );

    # --- one full backup at a time (ruling 206) ------------------------------------
    my $ok = api( 'action=backup-create&scope=full', 'POST' );
    ok( $ok->{ok} && $ok->{in_progress}, 'a stale or dead marker does not block a new full backup' )
        or diag explain $ok;
    ok( wait_for( sub { grep { $_ eq ( $ok->{name} // '' ) } @{ names( api( 'action=backup-list', 'GET' ), 'backups' ) } }, 60 ),
        'and it finishes' );

    my $live = 'lazysite-full-20261112T090000Z.tar.gz';
    spit( "$bk/$live", '' );
    spit( "$bk/.$live.pid", "$$ " . time . "\n" );
    opendir my $dh, $bk or die $!;
    my %before = map { ( $_ => 1 ) } readdir $dh;
    closedir $dh;
    my $no = api( 'action=backup-create&scope=full', 'POST' );
    ok( !$no->{ok}, 'while a full backup is in progress, another is refused' );
    is( $no->{kind}, 'in-progress', 'as in progress' );
    like( $no->{error} // '', qr/already being taken: \Q$live\E, started \d{4}-\d\d-\d\d \d\d:\d\d UTC/,
        'naming the running one and when it started' );
    opendir $dh, $bk or die $!;
    my @new = grep { !$before{$_} } readdir $dh;
    closedir $dh;
    is_deeply( \@new, [], 'and nothing is claimed' );
}

done_testing();
