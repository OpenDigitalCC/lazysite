#!/usr/bin/perl
# SM1103: a save the filesystem refuses says who tried to write where, and a
# save with no path is refused as one rather than written at the docroot.
#
# The 0.15.6/0.15.7 edge results ("Root items, unchanged", row V4): every
# manager `save` failed with "Cannot write file: Permission denied" at
# write_file_checked's create, even after `lazysite check --fix`, while WebDAV,
# MCP and acl-set wrote the same folders; and the failed save's audit target was
# "/". The tester's correction found the cause: the harness sent `path` in the
# JSON body, `save` reads it from the query, so the save had no path, resolved
# to the docroot and tried to create `<docroot>.<pid>.tmp` in the docroot's
# parent. The error said nothing that pointed there, and the hint it carried
# (check --fix) could not help.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use File::Basename qw(dirname);
use TestHelper     qw(repo_root site_tempdir);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';
plan skip_all => 'root writes anywhere' if $> == 0;

my @ALL = qw(ui manage_content);
my $s   = new_site( root => repo_root() );
my $d   = $s->docroot;
$s->add_user('writer');
$s->grant( 'writer', 'editors', [@ALL], \@ALL );

my $me  = getpwuid($>);
my $grp = getgrgid( ( split ' ', $) )[0] );

sub audit_rows {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

sub parent_strays {
    my $p = dirname($d);
    opendir my $dh, $p or return ();
    return grep { /\.tmp\z/ } readdir $dh;
}

# --- 1. A refused create names the file, the folder, the process, the folder's
#        identity and mode, and why the mode refuses it.
mkdir "$d/locked" or die $!;
chmod 0555, "$d/locked";
my $r = $s->call( 'writer', 'save', query => 'action=save&path=/locked/a.md',
    body => { content => "---\ntitle: A\n---\nbody\n" } );
my $e = $r->{error} // '';
ok( !$r->{ok}, 'a save into a folder the process cannot write fails' ) or diag explain $r;
like( $e, qr/\ACannot write file: Permission denied creating 'a\.md\.\d+\.tmp' in '\/locked'/,
    '...naming the file it tried to create and the folder, docroot-relative' );
like( $e, qr/ as \Q$me:$grp\E;/, '...the user and group the process runs as' );
like( $e, qr/the folder is \Q$me:\E\S+ 0555/, "...the folder's owner, group and mode" );
like( $e, qr/it is not writable by its owner/, '...which bit refuses it' );
like( $e, qr/run: lazysite check --fix/, '...and the fix, because the mode is the cause' );
unlike( $e, qr/\Q$d\E/, '...without the host layout' );
my $log = $s->last_stderr;
like( $log, qr/\[ERROR\].*write refused/, 'the refusal is logged at ERROR' ) or diag $log;
like( $log, qr/process=\Q$me:$grp\E/, '...with the process identity' );
like( $log, qr/folder=\Q$me:\E\S+ 0555/, '...and the folder identity and mode' );
like( $log, qr/\Q$d\E\/locked\/a\.md\.\d+\.tmp/, '...and the full path, for the operator' );
my @rows = grep { /\| writer \| save \| \/locked\/a\.md \|/ } audit_rows();
is( scalar @rows, 1, 'the failed save is audited at the page it saved' ) or diag audit_rows();
chmod 0755, "$d/locked";

# --- 2. A path in the body is not where save reads it: refused, named, audited
#        at the page the request meant - and nothing is created anywhere.
my $b = $s->call( 'writer', 'save', query => 'action=save',
    body => { path => '/body-path.md', content => "---\ntitle: B\n---\nbody\n" } );
ok( !$b->{ok}, 'a save whose path rides the body is refused' ) or diag explain $b;
is( $b->{kind}  // '', 'missing-parameter', '...as a missing parameter' );
is( $b->{field} // '', 'path',    '...about path' );
like( $b->{error} // '', qr/path was sent in the body; save reads it from the query string/,
    '...saying where it was sent and where save reads it' );
like( $b->{error} // '', qr/'\/body-path\.md'/, '...and echoing the path it was sent' );
ok( !-e "$d/body-path.md", '...and the page was not written' );
is_deeply( [ parent_strays() ], [], '...nor anything beside the docroot' );
my @brows = grep { /\| writer \| save \| \/body-path\.md \| .*\| fail \|/ } audit_rows();
is( scalar @brows, 1, '...and the audit row names the page, not "/"' ) or diag audit_rows();

# --- 3. No path anywhere: named as missing.
my $n = $s->call( 'writer', 'save', query => 'action=save',
    body => { content => "x\n" } );
ok( !$n->{ok}, 'a save with no path is refused' ) or diag explain $n;
is( $n->{kind}  // '', 'missing-parameter', '...as a missing parameter' );
is( $n->{field} // '', 'path', '...about path' );
like( $n->{error} // '', qr/path is required \(in the query\)/, '...named, with where it goes' );
my @nrows = grep { /\| writer \| save \| +\|.*\| fail \| ui \| missing-parameter: path is required/ } audit_rows();
is( scalar @nrows, 1, '...and audited naming what was missing' ) or diag audit_rows();

# The same for every content write, and empty is as missing as absent.
for my $a (qw(delete mkdir move copy lock)) {
    my $m = $s->call( 'writer', $a, query => "action=$a&path=", body => {} );
    is( $m->{kind} // '', 'missing-parameter', "$a with an empty path is a missing parameter" )
        or diag explain $m;
}
my $mb = $s->call( 'writer', 'delete', query => 'action=delete', body => { path => '/open.md' } );
like( $mb->{error} // '', qr/path was sent in the body; delete reads it/,
    'a delete with its path in the body is told where path goes' );
is_deeply( [ parent_strays() ], [], '...and nothing is written beside the docroot' );

# --- 4. A folder is never a save's target (the docroot is one).
for my $p ( '/', '/locked' ) {
    my $f = $s->call( 'writer', 'save', query => "action=save&path=$p",
        body => { content => "x\n" } );
    ok( !$f->{ok}, "a save to the folder '$p' is refused" ) or diag explain $f;
    like( $f->{error} // '', qr/is a folder/, '...as a folder' );
    unlike( $f->{error} // '', qr/Cannot write|Rename failed/, '...before any write is tried' );
}
is_deeply( [ parent_strays() ], [], 'nothing was written beside the docroot' );

# --- 4b. The site root is never what a delete, move or copy takes.
for my $c ( [ 'delete', 'action=delete&path=/' ], [ 'move', 'action=move&path=/&to=/elsewhere' ],
    [ 'copy', 'action=copy&path=/&to=/elsewhere' ] )
{
    my ( $a, $q ) = @$c;
    my $f = $s->call( 'writer', $a, query => $q, body => {} );
    is( $f->{kind} // '', 'site-root', "a $a of the site root is refused as the site root" )
        or diag explain $f;
}
ok( -d $d && !-e "$d/elsewhere", '...and the site is where it was' );

# --- 5. Outside the site, check --fix is not offered: it repairs the site's tree.
{
    require Lazysite::Manager::Common;
    local $Lazysite::Manager::Common::DOCROOT = $d;
    my $out = site_tempdir();
    chmod 0555, $out;
    my ( $ok, $err ) = Lazysite::Manager::Common::write_file_checked( "$out/x.md", "x" );
    chmod 0755, $out;
    ok( !$ok, 'a write outside the site fails' );
    like( $err // '', qr/in a folder outside the site/, '...naming no host path' );
    unlike( $err // '', qr/check --fix/, '...and offers no fix that would not touch it' );
}

# What a successful save records is unchanged.
my $ok = $s->call( 'writer', 'save', query => 'action=save&path=/open.md',
    body => { content => "---\ntitle: O\n---\nbody\n" } );
ok( $ok->{ok}, 'a save with its path in the query succeeds' ) or diag explain $ok;

done_testing();
