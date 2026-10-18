#!/usr/bin/perl
# SM1081: tools/vendor-oom.sh refreshes the pinned snapshot of OOM from ONE commit,
# writes a MANIFEST that says where it came from and holds a sha256 per file, refuses
# a deb that was not built from that commit, and prints what the SM747 filing needs.
#
# Run against a SCRATCH OOM repository and a SCRATCH destination (VENDOR_OOM_DEST, an
# override that exists for this test alone) - never the real OOM, never the real
# snapshot, no network.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(sha256_hex);
use IPC::Open3  qw(open3);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/vendor-oom.sh";
ok( -x $script, 'the tool is there and executable' ) or BAIL_OUT('tools/vendor-oom.sh');

my $t    = tempdir( CLEANUP => 1 );
my $repo = "$t/oom";

sub spit { my ( $p, $c ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $f, '>', $p or die "$p: $!"; print {$f} $c; close $f }

my %FILE = (
    'lib/Odoo/Ops.pm'             => "package Odoo::Ops;\nour \$VERSION = '9.99';\n1;\n",
    'lib/Odoo/Thing.pm'           => "package Odoo::Thing;\n1;\n",
    't/lib/Odoo/Test/FakeOdoo.pm' => "package Odoo::Test::FakeOdoo;\n1;\n",
    'behaviours/crm.lead/16.yaml' => "a: 1\n",
    'profiles/crm/16.yaml'        => "b: 2\n",
    'docs/MAPPER-SPEC.md'         => "# Spec\n\n## Open\n\n- one\n",
    'debian/copyright'            => "Format: x\nLicense: Artistic-1.0-Perl\n",
    'bin/oomd'                    => "#!/usr/bin/perl\nprint 1;\n",
    'bin/oom-ops'                 => "#!/usr/bin/perl\nprint 2;\n",
    'lib/Odoo/NotVendoredFromHere.txt' => "x\n",
);
spit( "$repo/$_", $FILE{$_} ) for keys %FILE;
my @git = ( 'git', '-C', $repo, '-c', 'user.name=t', '-c', 'user.email=t@t.example' );
system( 'git', 'init', '-q', $repo ) == 0                 or die;
system( @git, 'add', '-A' ) == 0                          or die;
system( @git, 'commit', '-q', '-m', 'Package 9.99' ) == 0 or die;
my $SPEC_SHA = sha256_hex( $FILE{q{docs/MAPPER-SPEC.md}} );
chomp( my $commit = `git -C $repo rev-parse HEAD` );

sub run_tool {
    my (@args) = @_;
    my $dest = "$t/dest";
    system( 'rm', '-rf', $dest );
    my $pid = open3( my $stdin, my $both, undef, 'env', "VENDOR_OOM_DEST=$dest", 'bash', $script, @args );
    close $stdin;
    my $out = do { local $/; <$both> };
    waitpid $pid, 0;
    return ( $? >> 8, $out, $dest );
}

subtest 'a commit becomes a snapshot with a MANIFEST that says so' => sub {
    my ( $rc, $out, $dest ) = run_tool( $commit, $repo );
    is( $rc, 0, 'it runs' ) or diag $out;
    for my $f ( 'lib/Odoo/Ops.pm', 't/lib/Odoo/Test/FakeOdoo.pm', 'behaviours/crm.lead/16.yaml', 'profiles/crm/16.yaml',
        'docs/MAPPER-SPEC.md', 'COPYRIGHT-OOM', 'MANIFEST' ) {
        ok( -f "$dest/$f", "$f is in the snapshot" );
    }
    ok( -x "$dest/bin/oomd", 'bin/oomd is in the snapshot and executable (SM1164)' );
    ok( !-e "$dest/bin/oom-ops", 'and it is the only file taken from bin/' );
    my $m = do { open my $fh, '<', "$dest/MANIFEST" or die $!; local $/; <$fh> };
    like( $m, qr/^source-commit: \Q$commit\E$/m,    'the MANIFEST names the commit' );
    like( $m, qr/^source-subject: Package 9\.99$/m, 'and its subject' );
    like( $m, qr/^source-deb: none/m,               'and says there was no deb' );
    like( $m, qr/^spec-sha256: \Q$SPEC_SHA\E$/m,    'and the spec\'s hash' );
    my %h = reverse( $m =~ /^([0-9a-f]{64})  (\S.*)$/mg );
    is( $h{'lib/Odoo/Ops.pm'}, sha256_hex( $FILE{'lib/Odoo/Ops.pm'} ), 'a file\'s hash is its content\'s' );
    ok( !exists $h{MANIFEST}, 'the MANIFEST does not list itself' );
    ok( -f "$dest/lib/Odoo/NotVendoredFromHere.txt", q{the whole of lib/ comes, not only the .pm files} );
    like( $out, qr/\| Source \| `t\/vendor\/oom\/docs\/MAPPER-SPEC\.md` \|/, 'and it prints the filing\'s Source row' );
    like( $out, qr/\| sha256 at filing \| `$SPEC_SHA` \|/, 'and the hash the filing must now say' );
};

subtest 'it refuses what it cannot vouch for' => sub {
    my ( $rc, $out ) = run_tool( 'deadbeefdeadbeef', $repo );
    isnt( $rc, 0, 'an unknown commit is refused' );
    like( $out, qr/no commit deadbeefdeadbeef/, 'by name' );
    ( $rc, $out ) = run_tool();
    isnt( $rc, 0, 'no commit is refused' );
};

subtest 'a deb must have been built from that commit' => sub {
    plan skip_all => 'dpkg-deb is not installed' unless system('command -v dpkg-deb >/dev/null 2>&1') == 0;
    for my $case ( [ same => 1 ], [ other => 0 ] ) {
        my ( $name, $matches ) = @$case;
        my $d = "$t/deb-$name";
        spit( "$d/DEBIAN/control", "Package: libodoo-oom-perl\nVersion: 9.99\nArchitecture: all\nMaintainer: t <t\@t.example>\nDescription: scratch\n" );
        spit( "$d/usr/share/perl5/$_", ( $matches || !/Thing/ ? $FILE{ 'lib/' . $_ } : "package Odoo::Thing;\n# different\n1;\n" ) )
            for qw(Odoo/Ops.pm Odoo/Thing.pm Odoo/NotVendoredFromHere.txt);
        my $docdir = "$d/usr/share/doc/libodoo-" . 'oom-perl';
        make_path($docdir);
        open my $z, '|-', 'sh', '-c', 'gzip -n > "$1"', 'sh', "$docdir/MAPPER-SPEC.md.gz" or die $!;
        print {$z} $FILE{'docs/MAPPER-SPEC.md'};
        close $z;
        system("dpkg-deb --root-owner-group -b $d $t/$name.deb >/dev/null 2>&1") == 0 or die "dpkg-deb failed";
        my ( $rc, $out, $dest ) = run_tool( '--deb', "$t/$name.deb", $commit, $repo );
        if ($matches) {
            is( $rc, 0, 'a deb whose library and spec are the commit\'s is accepted' ) or diag $out;
            like( do { open my $fh, '<', "$dest/MANIFEST" or die $!; local $/; <$fh> }, qr/^source-deb: 9\.99$/m, 'and its version is in the MANIFEST' );
        }
        else {
            isnt( $rc, 0, 'a deb built from another commit is refused' );
            like( $out, qr/deb's library is not commit/, 'by name' );
        }
    }
};

done_testing();
