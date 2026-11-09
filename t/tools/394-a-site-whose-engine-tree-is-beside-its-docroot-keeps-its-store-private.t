#!/usr/bin/perl
# T-115 (SM1361, 0.16.9): A SITE WHOSE ENGINE TREE SITS BESIDE ITS DOCROOT KEEPS
# ITS ACCOUNT AND FORM STORES PRIVATE.
#
# On the beside layout (SM293/SM850: <docroot>-lazysite), released 0.16.8:
#   - mode_for named the tree as `/lazysite/` only, so an upgrade laid the auth
#     and forms seeds - and forms/smtp.conf - at 0644;
#   - the group-write step joined its rows to "$docroot/", missing every file;
#   - forms/ (declared 2770) was applied by the check alone;
#   - the check tested world bits on the secrets only.
#
# A site provisioned by the real install.pl into the beside layout, put in that
# state (world bits on the seeds, smtp.conf and both directories, the user store
# without group write, the state one version back), then upgraded in place:
#   - nothing under auth/ or forms/ keeps a world bit, files or directories;
#   - the user store carries group write again;
# and the real lazysite-check.pl names a world-readable users file, `--fix`
# clears it to its declared mode, and the check is clean after.
use strict;
use warnings;
use Test::More;
use File::Find ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site slurp spit);
use PayloadStage  qw(make_stage run_install);

my $MF    = repo_manifest_guard();
my $stage = make_stage( $MF->path );

my ( $docroot, $cgibin, $root ) = new_site();
my $lz = "$docroot-lazysite";
make_path($lz);    # the beside layout, before anything is laid
my ( $rc, $out ) = run_install( $stage, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'provision' );
is( $rc, 0, 'provisioned' ) or diag $out;
ok( -f "$lz/lazysite.conf" && !-e "$docroot/lazysite", 'into the tree beside the docroot' );

sub mode { return ( ( stat $_[0] )[2] // 0 ) & 07777 }

sub world {    # every path under auth/ and forms/ with a world bit
    my @w;
    File::Find::find( { no_chdir => 1, wanted => sub {
        return if -l $_;
        push @w, sprintf( '%s %04o', $_, mode($_) ) if mode($_) & 0007;
    } }, grep { -d } "$lz/auth", "$lz/forms" );
    return @w;
}

# ---- the state released 0.16.8 left -----------------------------------------
my @seeds = grep { -f } ( glob("$lz/auth/*.example"), glob("$lz/forms/*.example"), "$lz/forms/smtp.conf" );
ok( scalar @seeds >= 2, 'the seeds are there: ' . scalar @seeds );
chmod 0644, @seeds;
chmod 02775, "$lz/auth", "$lz/forms";
# An example the operator EDITED, at the mode 0.16.8 laid: the plan keeps an
# edited file, so only the install's own mode step (ruling 215) puts it right.
my ($edited) = grep {/\.example\z/} @seeds;
spit( $edited, slurp($edited) . "\n# an operator's note\n" );
chmod 0644, $edited;
my $edited_text = slurp($edited);
# The lock the auth code takes (auth/.consume.lock), left as an earlier release
# made it, at the umask.
spit( "$lz/auth/.consume.lock", '' );
chmod 0664, "$lz/auth/.consume.lock";
spit( "$lz/auth/users", "someone:x\n" );
chmod 0640, "$lz/auth/users";
{
    my $c = slurp("$lz/lazysite.conf");
    $c =~ s/^update_channel:.*\n//mg;
    spit( "$lz/lazysite.conf", $c . "update_channel: all\n" );
    my $s = slurp("$lz/.install-state.json");
    $s =~ s/"version"\s*:\s*"[^"]*"/"version" : "0.16.2"/;
    spit( "$lz/.install-state.json", $s );
}
ok( scalar( world() ) >= 3, 'world bits on the seeds and both directories, as 0.16.8 left them' );

# ---- the upgrade ---------------------------------------------------------------
( $rc, $out ) = run_install( $stage, '--docroot', $docroot, '--cgibin', $cgibin, '--mode', 'upgrade', '--force' );
is( $rc, 0, 'the upgrade succeeds' ) or diag $out;
is_deeply( [ world() ], [], 'nothing under auth/ or forms/ keeps a world bit' );
is( sprintf( '%04o', mode("$lz/forms") ), '2770', 'forms/ is its declared 2770' );
ok( mode("$lz/auth/users") & 0020, 'the user store carries group write again (the group-write step reaches it)' );
is( sprintf( '%04o', mode($edited) ), '0640', 'the edited example has its declared mode' );
is( slurp($edited), $edited_text, 'and its content is the operator\'s, untouched' );

my $check = "$stage/tools/lazysite-check.pl";
my $g     = getgrgid( $) + 0 ) // ( $) + 0 );
sub run_check {
    my (@extra) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $cmd = join ' ', map {quotemeta} $^X, $check, '--docroot', $docroot, '--cgibin', $cgibin, '--group', $g, @extra;
    return `$cmd 2>&1`;
}
like( run_check(), qr/\[  ok  \] nothing in lazysite\/auth\/ or lazysite\/forms\/ is world-readable/,
    'after the upgrade the check passes, with no repair' );

# ---- the auth code's lock takes the store's mode -----------------------------------
unlink "$lz/auth/.consume.lock";
{
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $code = 'umask 022; require Lazysite::Auth::Settings; $Lazysite::Auth::Settings::AUTH_DIR = $ARGV[0]; '
        . 'my $l = Lazysite::Auth::Settings::_consume_lock(); print defined $l ? "held\n" : "none\n"';
    my $cmd = join ' ', map {quotemeta} $^X, "-I$stage/lib", '-e', $code, "$lz/auth";
    like( `$cmd 2>&1`, qr/^held$/m, 'the auth code takes its consume lock' );
}
is( sprintf( '%04o', mode("$lz/auth/.consume.lock") ), '0660', 'at 0660 whatever the umask' );
{
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $code = 'umask 022; require Lazysite::Util; my $l = Lazysite::Util::store_lock($ARGV[0]); print defined $l ? "held\n" : "none\n"';
    my $cmd = join ' ', map {quotemeta} $^X, "-I$stage/lib", '-e', $code, "$lz/forms/contact.jsonl";
    like( `$cmd 2>&1`, qr/^held$/m, 'a form store\'s sidecar lock is taken' );
}
is( sprintf( '%04o', mode("$lz/forms/.contact.jsonl.lock") ), '0660', 'at 0660 too' );

# ---- the check, and its fix, for drift after the upgrade -------------------------
chmod 0644, "$lz/auth/users";
like( run_check(), qr{\[ FAIL \] lazysite/auth/users is world-readable \(0644\)}, 'the check names the world-readable user store' );
like( run_check(), qr{chmod 0660 '\Q$lz\E/auth/users'}, 'with the fix, on the beside path' );
my $fixed = run_check('--fix');
like( $fixed, qr{fixed: chmod 0660 \Q$lz\E/auth/users \(was 06[46]4\)}, '--fix sets the declared mode' );
is( sprintf( '%04o', mode("$lz/auth/users") ), '0660', 'and the file is 0660' );
like( run_check(), qr/\[  ok  \] nothing in lazysite\/auth\/ or lazysite\/forms\/ is world-readable/, 'and the check is clean after' );

chmod 02775, "$lz/forms";
like( run_check(), qr{\[ FAIL \] lazysite/forms/ has world access \(2775\)}, 'a world-readable forms/ directory is named' );
run_check('--fix');
is( sprintf( '%04o', mode("$lz/forms") ), '2770', 'and --fix sets it to 2770' );

done_testing();
