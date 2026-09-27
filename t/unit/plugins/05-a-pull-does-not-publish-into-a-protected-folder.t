#!/usr/bin/perl
# SM881: a pull must not publish a file that belongs in a protected folder.
#
# THE EXPOSURE, stood up here for the first time. git merge writes the worktree
# and the worktree IS the docroot, so a remote commit adding a file under a
# folder the sysop has gated puts that file straight into the public tree. The
# operator's only signal is that the pull succeeded. This filing was graded from
# reading and the ruling asked for the exposure itself to be reproduced before
# anything was built; the first subtest below is that reproduction, and it fails
# on the unfixed code.
#
# WHY THE OBVIOUS FIX DOES NOT WORK, which the filing demonstrated rather than
# assumed: `Private::resolve_for_write` answers PUBLIC for the pulled file,
# correctly, because an ancestor existing in the docroot settles it and git has
# just created that ancestor. So the question goes to the ACL store instead,
# through `Acl::gating_for` - the engine's one supported answer.
#
# AND THE THIRD STATE IS TESTED, because it is the part that could do damage. A
# store that will not parse must stop the relocation, not drive it: guessing
# "gated" would move every changed file into the private store and unpublish the
# site on the next pull.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Git     ();
use Lazysite::Private ();

my $ROOT   = "$FindBin::Bin/../../..";
my $PLUGIN = "$ROOT/plugins/git-sync.pl";
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;
plan skip_all => 'git not installed on this host'
    unless Lazysite::Git::git_available();

$ENV{LAZYSITE_GIT_SYNC_ALLOW_LOCAL} = 1;
$ENV{LAZYSITE_ACTING_USER}          = 'alice';

sub t_spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub t_slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }

sub run_plugin {
    my (@args) = @_;
    open my $fh, '-|', $^X, $PLUGIN, @args or die "cannot run plugin: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    return eval { decode_json($out) } // { ok => 0, error => "no JSON: " . ( $out // '' ) };
}

sub mksite {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/cache" );
    t_spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    t_spit( "$d/lazysite/nav.conf",      "Home | /\n" );
    t_spit( "$d/index.md",               "home\n" );
    Lazysite::Git::reset_cache();
    my $r = Lazysite::Git::init( $d, 'installer' );
    die "init failed: $r->{error}" unless $r->{ok};
    Lazysite::Git::reset_cache();
    return $d;
}

sub mkremote {
    my $r = tempdir( CLEANUP => 1 ) . '/remote.git';
    system( 'git', 'init', '--bare', '-q', '-b', 'main', $r ) == 0 or die 'bare init';
    return $r;
}

sub conf_sync {
    my ( $d, $remote ) = @_;
    t_spit( "$d/lazysite/git-sync.conf", "remote_url: $remote\nbranch: main\n" );
}

sub wgit {
    my ( $w, @args ) = @_;
    system( 'git', '-C', $w, '-c', 'user.name=other', '-c',
        'user.email=other@example', @args ) == 0
        or die "git @args failed";
}

# Push the site to a fresh bare remote, then hand back a working clone of it
# standing in for somebody else's copy.
sub site_with_remote {
    my $d      = mksite();
    my $remote = mkremote();
    conf_sync( $d, $remote );
    my $p = run_plugin( '--action', 'push', '--docroot', $d );
    die "push failed: " . ( $p->{error} // '' ) unless $p->{ok};
    my $w = tempdir( CLEANUP => 1 ) . '/work';
    system( 'git', 'clone', '-q', $remote, $w ) == 0 or die 'clone failed';
    return ( $d, $w );
}

sub set_acls {
    my ( $d, $json ) = @_;
    t_spit( "$d/lazysite/auth/acls.json", $json );
}

# Commit a file on the remote side and push it.
sub remote_adds {
    my ( $w, $rel, $body ) = @_;
    my $dir = $rel;
    $dir =~ s{/[^/]+\z}{};
    make_path("$w/$dir") if length $dir && $dir ne $rel;
    t_spit( "$w/$rel", $body );
    wgit( $w, 'add',    '-A', '.' );
    wgit( $w, 'commit', '-q', '-m',     'remote edit' );
    wgit( $w, 'push',   '-q', 'origin', 'main' );
}

subtest 'THE EXPOSURE: a pull into a gated folder relocates instead of publishing' => sub {
    my ( $d, $w ) = site_with_remote();
    set_acls( $d, '{"content/private":{"read":["@staff"]}}' );
    remote_adds( $w, 'content/private/secret.md', "---\ntitle: Secret\n---\nboard minutes\n" );

    my $r = run_plugin( '--action', 'pull', '--docroot', $d );
    ok( $r->{ok}, 'the pull succeeds' ) or diag explain $r;

    ok( !-e "$d/content/private/secret.md",
        'the pulled file is NOT left in the public tree' )
        or diag( 'This is the exposure: git wrote the worktree, the worktree is '
            . 'the docroot, and the file is now fetchable by anyone.' );

    my $priv = Lazysite::Private::private_path( $d, 'content/private/secret.md' );
    ok( defined $priv && -e $priv, 'it is in the private store instead' );
    is( t_slurp($priv), "---\ntitle: Secret\n---\nboard minutes\n",
        'with its bytes intact' );

    like( $r->{message}, qr/protected folder/i,
        'and the operator is told it happened' );
    is_deeply( $r->{relocated}, ['content/private/secret.md'],
        'the result names what moved' );
};

subtest 'a pulled file outside any rule is left exactly where git put it' => sub {
    my ( $d, $w ) = site_with_remote();
    set_acls( $d, '{"content/private":{"read":["@staff"]}}' );
    remote_adds( $w, 'content/open.md', "public news\n" );

    my $r = run_plugin( '--action', 'pull', '--docroot', $d );
    ok( $r->{ok}, 'the pull succeeds' );
    is( t_slurp("$d/content/open.md"), "public news\n",
        'an ungated file stays public' )
        or diag( 'Relocating this would unpublish content nobody asked to '
            . 'protect, which is the failure mode worth more than the one '
            . 'being fixed.' );
    ok( !$r->{relocated} || !@{ $r->{relocated} }, 'and nothing is reported moved' );
};

subtest 'THE TRAP: an unreadable store stops the relocation and says so' => sub {
    my ( $d, $w ) = site_with_remote();
    set_acls( $d, '{ this is not json' );
    remote_adds( $w, 'content/private/secret.md', "board minutes\n" );

    my $r = run_plugin( '--action', 'pull', '--docroot', $d );
    ok( $r->{ok},             'the pull still applies the changes' );
    ok( $r->{gating_unknown}, 'and reports that the check could not be made' );
    like( $r->{message}, qr/could not be read/i,
        'in words naming the cause' );
    like( $r->{message}, qr/may now be public/i,
        'and saying what the consequence is' );

    ok( -e "$d/content/private/secret.md",
        'NOTHING was moved, because the answer was unknown' )
        or diag( 'Treating unknown as gated would relocate every changed file '
            . 'and silently unpublish the site on the next pull - worse than '
            . 'the exposure this closes.' );
};

subtest 'a relocated page keeps its aliases' => sub {
    # The second-order effect. The alias reindex asks whether the file exists in
    # the DOCROOT, and a relocation makes that false - so without care,
    # protecting a page would deindex it and break every link to it.
    my ( $d, $w ) = site_with_remote();
    set_acls( $d, '{"content/private":{"read":["@staff"]}}' );
    remote_adds( $w, 'content/private/secret.md',
        "---\ntitle: Secret\naliases:\n  - /old-secret-url\n---\nminutes\n" );

    my $r = run_plugin( '--action', 'pull', '--docroot', $d );
    ok( $r->{ok}, 'the pull succeeds' );
    my $aliases = t_slurp("$d/lazysite/aliases.json") // '';
    like( $aliases, qr{/old-secret-url},
        'the relocated page is still in the alias index' )
        or diag( 'A gated page is still a page: it has a URL and is served over '
            . 'the authenticated path, so deindexing it would break its links.' );
};

subtest 'the reserved tree is not relocated, whatever the rules say' => sub {
    # lazysite/ is configuration governed by the deny lists, not content governed
    # by an ACL entry. A site-wide rule must not sweep it into the private store.
    my ( $d, $w ) = site_with_remote();
    set_acls( $d, '{"/":{"read":["@members"]}}' );
    remote_adds( $w, 'content/anything.md', "words\n" );

    my $r = run_plugin( '--action', 'pull', '--docroot', $d );
    ok( $r->{ok},                  'the pull succeeds' );
    ok( -e "$d/lazysite/nav.conf", 'the reserved tree is still in place' );
    ok( !-e "$d/content/anything.md",
        'while the content a site-wide rule gates is relocated' );
};

done_testing();
