#!/usr/bin/perl
# SM1446: A BACKUP THAT DID NOT FINISH IS NEVER LISTED AS A BACKUP.
#
# Found on a large nine-domain instance: the operator took a full backup from the
# Backups page, the request was killed mid-tar (a deadline in front of the
# manager), and backup-list showed lazysite-full-<stamp>.tar.gz - size 0, no
# digest - as a full backup. The name is claimed up front as an empty file and the
# archive renamed over it only when tar has finished, so a killed request left the
# empty claim. No audit row was written either: the trail's line is written after
# the action, and the action never returned.
#
# A full backup now runs detached from its request (ruling 248; t/unit/manager/977),
# so the request that can be killed mid-tar is a content backup's, which still
# runs in the request. Driven through lazysite-manager-api.pl, as the page drives
# it, with a stand-in tar that starts its archive and then hangs - the request is
# signalled while tar runs, as a deadline would:
#   - while tar runs the backup is listed as in progress, and restore refuses it
#     as in progress;
#   - KILL (cannot be caught): the claim stays; backup-list does not list it as a
#     backup or as in progress but under `unfinished`, with its time and how to
#     remove it; the trail holds the start, by file name; restore refuses it;
#   - TERM (the relay's first signal): nothing is left at all - no claim, no
#     staging directory, no marker - and tar is stopped;
#   - an archive tar wrote through its own name and did not finish (every one
#     before SM885, and site packages still) is unfinished too; a whole one with
#     no digest beside it (from before the digest) is still a backup;
#   - a finished backup records its sha256, and its audit outcome names the file;
#   - a site package tar did not finish is not applied.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes ();
use POSIX       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_child site_tempdir reap_child);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub csrf  { return hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/backups" );
spit( "$d/lazysite/lazysite.conf", "manager: enabled\nmanager_groups: managers\n" );
spit( "$d/lazysite/auth/.secret",  $secret );
spit( "$d/page.md",                "---\ntitle: P\n---\n\nbody\n" );
my $bk = "$d/lazysite/backups";

# The request's environment, as the auth wrapper hands it to the manager API.
sub api_env {
    my ( $qs, $method ) = @_;
    my %e = %ENV;
    delete @e{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS)};
    %e = ( %e,
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => $method,
        QUERY_STRING          => $qs,
        CONTENT_LENGTH        => ( $method eq 'POST' ? 2 : 0 ),
        HTTP_X_REMOTE_USER    => 'admin',
        HTTP_X_REMOTE_GROUPS  => 'managers',
        HTTP_X_CSRF_TOKEN     => csrf('admin'),
        LAZYSITE_AUTH_TRUSTED => 1 );
    return %e;
}

sub api {
    my ( $qs, $method ) = @_;
    local %ENV = api_env( $qs, $method // 'POST' );
    my $out = run_child( [ $^X, $mapi ], stdin => '{}' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

# A tar that starts the archive it is given and then hangs, as a tar of a large
# tree is still running when the request's deadline comes. It records its pid.
my $bin = "$d/../fakebin";
make_path($bin);
spit( "$bin/tar", <<'PERL' );
#!/usr/bin/perl
my $out = $ARGV[1];
open my $p, '>', $ENV{N824_TAR_PID} or exit 2;
print {$p} $$;
close $p;
open my $o, '>', $out or exit 2;
print {$o} "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03";    # a gzip stream, begun
close $o;
sleep 60;
exit 0;
PERL
chmod oct('0755'), "$bin/tar" or die $!;

# Start backup-create with the hanging tar, wait until tar is running, signal
# the request, and stop whatever tar is left. Returns the claimed name.
sub killed_backup {
    my ( $qs, $sig, $while ) = @_;
    my $pidf = "$d/../tar.pid";
    unlink $pidf;
    my %before = map { ( s{.*/}{}r => 1 ) } glob "$bk/lazysite-*.tar.gz";
    spit( "$d/../body", '{}' );
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        %ENV = ( api_env( $qs, 'POST' ), PATH => "$bin:$ENV{PATH}", N824_TAR_PID => $pidf );
        open STDIN,  '<', "$d/../body"     or POSIX::_exit(127);
        open STDOUT, '>', "$d/../api.out"  or POSIX::_exit(127);
        open STDERR, '>', "$d/../api.err"  or POSIX::_exit(127);
        exec $^X, $mapi or POSIX::_exit(127);
    }
    my $until = Time::HiRes::time() + 60;
    Time::HiRes::sleep(0.05) until ( -s $pidf ) || Time::HiRes::time() > $until;
    ok( -s $pidf, "$sig: tar is running when the request is signalled" );
    my ($claim) = grep { !$before{$_} } map { s{.*/}{}r } glob "$bk/lazysite-*.tar.gz";
    $while->($claim) if $while;
    kill $sig, $pid;
    reap_child( $pid, label => 'manager api' );
    my $tar = slurp($pidf);
    kill 'KILL', $tar if $tar =~ /\A\d+\z/ && kill 0, $tar;
    return $claim // '';
}

# --- KILL: the claim stays, and is listed as what it is ----------------------------
my $running;
my $claim = killed_backup( 'action=backup-create', 'KILL', sub { $running = api( 'action=backup-list', 'GET' ); } );
is_deeply( [ map { $_->{name} } @{ $running->{in_progress} || [] } ], [$claim],
    'while tar runs, the backup is listed as in progress' ) or diag explain $running;
is_deeply( $running->{unfinished}, [], 'and not as unfinished' );
like( $claim, qr/\Alazysite-manual-\d{8}T\d{6}Z\.tar\.gz\z/, 'the request had claimed its name' );
ok( -f "$bk/$claim" && -z "$bk/$claim", 'a KILL leaves the empty claim behind (it cannot be caught)' );

my $l = api( 'action=backup-list', 'GET' );
ok( $l->{ok}, 'backup-list answers' ) or diag explain $l;
is_deeply( [ map { $_->{name} } @{ $l->{backups} || [] } ], [],
    'the unfinished claim is NOT listed as a backup' );
my ($u) = grep { $_->{name} eq $claim } @{ $l->{unfinished} || [] };
ok( $u, 'it is listed as unfinished' ) or diag explain $l;
ok( ( $u->{mtime} // 0 ) > 0, 'with its time' );
like( $u->{remedy} // '', qr/no backup is being taken now.*backup-delete name=\Q$claim\E.*rm lazysite\/backups\/\Q$claim\E/,
    'and how to remove it' );

my $audit = slurp("$d/lazysite/logs/audit.log");
like( $audit, qr/\| admin \| backup-create \| manual \| [^|]* \| started \| ui \| file=\Q$claim\E$/m,
    'the trail holds the start, naming the file' );
unlike( $audit, qr/\| backup-create \| manual \| [^|]* \| (?:ok|fail) /, 'and no outcome - the request never wrote one' );

# --- a manual one, killed the same way, is not restored by name ----------------------
my $during;
my $mclaim = killed_backup( 'action=backup-create', 'KILL', sub { $during = api("action=backup-restore&name=$_[0]") } );
is( $during->{kind}, 'in-progress', 'while it is being taken, restore refuses it as in progress' ) or diag explain $during;
like( $during->{error} // '', qr/is being taken now: there is nothing to restore/, 'saying so' );
like( $mclaim, qr/\Alazysite-manual-/, 'a content backup killed mid-tar' );
my $r = api("action=backup-restore&name=$mclaim");
ok( !$r->{ok}, 'restore refuses the unfinished one' );
is( $r->{kind}, 'unfinished', 'as unfinished' );
like( $r->{error} // '', qr/\Q$mclaim\E is an unfinished backup/, 'naming it' );
ok( !glob("$bk/lazysite-prerestore-*"), 'before taking any safety snapshot' );

my $del = api( 'action=backup-delete', 'POST' );    # the name rides the body; this one names none
ok( !$del->{ok}, 'backup-delete needs a name' );
unlink "$bk/$claim", "$bk/$mclaim", glob("$bk/.*.pid");
system( 'rm', '-rf', glob("$bk/.stage-*") );

# --- TERM: nothing is left at all ----------------------------------------------------
my $tclaim = killed_backup( 'action=backup-create', 'TERM' );
like( $tclaim, qr/\Alazysite-manual-/, 'TERM: a content backup was under way' );
opendir my $dh, $bk or die $!;
my @left = grep { !/\A\.\.?\z/ } readdir $dh;
closedir $dh;
is_deeply( \@left, [], 'nothing is left in backups/: no claim, no staging directory' )
    or diag explain \@left;
my $tpid = slurp("$d/../tar.pid");
Time::HiRes::sleep(0.3);
ok( !( kill 0, $tpid ), 'and tar was stopped' );
like( slurp("$d/../api.err"), qr/backup interrupted - nothing was kept/, 'the log says so' );

# --- an archive cut off part way, and a whole one from before the digest ------------
{
    spit( "$bk/lazysite-full-20260701T101010Z.tar.gz", "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03" . ( "\x55" x 64 ) );
    require IO::Compress::Gzip;
    IO::Compress::Gzip::gzip( \( 'x' x 4096 ) => "$bk/lazysite-manual-20260702T101010Z.tar.gz" )
        or die $IO::Compress::Gzip::GzipError;
    my $l2 = api( 'action=backup-list', 'GET' );
    is_deeply( [ map { $_->{name} } @{ $l2->{unfinished} || [] } ], ['lazysite-full-20260701T101010Z.tar.gz'],
        'an archive whose stream stops part way, with no digest, is unfinished' );
    is_deeply( [ map { $_->{name} } @{ $l2->{backups} || [] } ], ['lazysite-manual-20260702T101010Z.tar.gz'],
        'a whole one with no digest (from before the digest) is still a backup' );
    unlink glob("$bk/lazysite-*");
}

# --- a finished backup: its digest, and an outcome that names it ---------------------
my $c = api('action=backup-create');
ok( $c->{ok}, 'a content backup that finishes' ) or diag explain $c;
ok( length( $c->{sha256} // '' ) == 64, 'records its sha256' );
ok( -f "$bk/$c->{name}.sha256", 'in the sidecar beside it' );
my ($row) = grep { $_->{name} eq ( $c->{name} // '' ) } @{ api( 'action=backup-list', 'GET' )->{backups} };
is( $row->{sha256_status}, 'verified', 'which the listing verifies' );
$audit = slurp("$d/lazysite/logs/audit.log");
like( $audit, qr/\| backup-create \| manual \| [^|]* \| started \| ui \| file=\Q$c->{name}\E$/m, 'its start' );
like( $audit, qr/\| backup-create \| manual \| [^|]* \| ok \| ui \| file=\Q$c->{name}\E$/m,
    'and its outcome, naming the file' );

# --- a site package tar did not finish is not applied ----------------------------------
{
    require Lazysite::Manager::SitePackage;
    no warnings 'once';
    local $Lazysite::Manager::SitePackage::DOCROOT = $d;
    my $pkg = "$bk/lazysite-site-shop.example-20261112T070000Z.tar.gz";
    spit( $pkg, '' );
    my $a = Lazysite::Manager::SitePackage::package_apply( $pkg, content_root => 'sites/shop' );
    ok( !$a->{ok}, 'an unfinished site package is not applied' );
    is( $a->{kind}, 'unfinished', 'as unfinished' );
    like( $a->{error} // '', qr/lazysite-site-shop\.example-20261112T070000Z\.tar\.gz is an unfinished package.*site-backup-delete/,
        'naming it and how to remove it' );
    ok( !-e "$d/sites/shop", 'and nothing was written' );
}

done_testing();
