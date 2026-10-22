#!/usr/bin/perl
# SM1206: tools/vendor-oom.sh leaves everything it wrote group-writable, whatever the
# caller's umask. On 2026-10-19 it left directories 2755 and files 644/664, and the
# release manager (another user, same group) could not `git reset --hard` over them.
#
# Run against a SCRATCH OOM repository and a SCRATCH destination, no network.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find qw(find);
use IPC::Open3 qw(open3);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $script = repo_root() . '/tools/vendor-oom.sh';
my $t      = tempdir( CLEANUP => 1 );
my $repo   = "$t/oom";

sub spit {
    my ( $p, $c ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $f, '>', $p or die "$p: $!";
    print {$f} $c;
    close $f;
}

spit( "$repo/$_", "x\n" )
    for qw(lib/Odoo/Ops.pm t/lib/Odoo/Test/FakeOdoo.pm behaviours/account.payment.register/16.yaml
    profiles/crm/16.yaml docs/MAPPER-SPEC.md debian/copyright);
spit( "$repo/bin/oomd", "#!/usr/bin/perl\n" );
my @git = ( 'git', '-C', $repo, '-c', 'user.name=t', '-c', 'user.email=t@t.example' );
system( 'git', 'init', '-q', $repo ) == 0                 or die;
system( @git, 'add', '-A' ) == 0                          or die;
system( @git, 'commit', '-q', '-m', 'Package 9.99' ) == 0 or die;
chomp( my $commit = `git -C $repo rev-parse HEAD` );

# The destination's parent is setgid and group-writable, as the shared checkout's is.
my $parent = "$t/parent";
mkdir $parent or die;
chmod 02775, $parent;
my $dest = "$parent/dest";

umask 022;    # the umask that produced 2755/644; the tool must not depend on it
my $out = run_child( [ 'env', "VENDOR_OOM_DEST=$dest", 'bash', $script, $commit, $repo ],
    stderr => 'merge' )->{out};
is( $? >> 8, 0, 'the tool runs' ) or diag $out;

my ( @bad, @nosgid, $n );
find(
    { no_chdir => 1,
        wanted => sub {
            my $m = ( stat $_ )[2] & 07777;
            $n++;
            push @bad,    sprintf( '%s %04o', $_, $m ) unless $m & 020;
            push @nosgid, $_ if -d $_ && !( $m & 02000 );
        } },
    $dest
);
cmp_ok( $n, '>', 10, 'there is a tree to look at' );
is_deeply( \@bad,    [], 'no directory or file it wrote lacks group write' );
is_deeply( \@nosgid, [], 'and directories keep the parent\'s setgid' );
ok( -f "$dest/MANIFEST" && ( ( stat "$dest/MANIFEST" )[2] & 020 ), 'the MANIFEST is group-writable too' );
ok( -x "$dest/bin/oomd", 'bin/oomd stays executable' );

done_testing;
