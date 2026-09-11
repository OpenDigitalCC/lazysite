#!/usr/bin/perl
# lazysite-bundle-apply.pl - apply an offline publishing bundle produced by an
# agent that has no network (e.g. an editor working in a chat). The bundle is a
# single JSON document; this validates every path against the canonical deny
# list and confines writes to the docroot. Dry-run by default; --apply writes.
#
# Bundle format (JSON):
#   { "lazysite_bundle": 1,
#     "post": ["clear-cache"],              # optional post-extract actions
#     "files": [ { "path": "about.md", "content": "..." }, ... ] }
#
# Paths are docroot-relative. Core-only Perl; no CPAN.
use strict;
use warnings;
use JSON::PP       qw(decode_json);
use File::Path     qw(make_path);
use File::Basename qw(dirname);

# SM329: the house bootstrap, not `use lib` - t/lint/59 requires an
# `unshift @INC` that runs BEFORE the load it exists for, because a tool is run
# from wherever an operator happens to be and a relative lib path is not a
# guarantee. The lint exists because six tools once could not load the modules
# they declared, and no test noticed: nothing ran them the way an operator does.
BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util    ();
use Lazysite::Paths   ();
use Lazysite::Private ();

my ( $docroot, $apply, $file, $as_user );
while ( my $a = shift @ARGV ) {
    if    ( $a eq '--docroot' ) { $docroot = shift @ARGV }
    elsif ( $a eq '--apply' )   { $apply   = 1 }
    elsif ( $a eq '--as-user' ) { $as_user = shift @ARGV }
    elsif ( $a eq '--help' )    { usage(); exit 0 }
    else                        { $file = $a }
}
usage_die("--docroot is required") unless defined $docroot && length $docroot;
$docroot =~ s{/+$}{};
usage_die("docroot '$docroot' is not a directory") unless -d $docroot;

# SM619: become the tree's owner before --apply writes anything. Dropped
# unconditionally rather than only under --apply, so a dry run and a real run
# read the tree as the same identity - a preview performed as root can see
# files the apply will not be able to, and would then promise work it cannot do.
{
    my $d = Lazysite::Util::drop_to_tree_owner( $docroot, as_user => $as_user );
    if ( !$d->{dropped} && $> == 0 ) {
        die "lazysite-bundle-apply.pl: refusing to act on '$docroot' as root - $d->{why}\n";
    }
}

# Canonical deny list - the paths a bundle must never write. Reconciled from the
# WebDAV deny list, the manager blocked-paths, and the rsync excludes.
my @DENY = (
    qr{^lazysite/auth(?:/|$)},
    qr{^lazysite/forms(?:/|$)},
    qr{^lazysite/cache(?:/|$)},
    qr{^lazysite/logs(?:/|$)},
    qr{^lazysite/manager(?:/|$)},
    qr{^lazysite/lazysite\.conf$},
    qr{^cgi-bin(?:/|$)},
    qr{^manager(?:/|$)},
    qr{\.pl$},
);

my $raw = do { local $/; defined $file ? do { open my $fh, '<', $file or die "open $file: $!\n"; <$fh> } : <STDIN> };
my $bundle = eval { decode_json($raw) };
die "Bundle is not valid JSON: $@\n" unless ref $bundle eq 'HASH';
die "Not a lazysite bundle (missing lazysite_bundle marker)\n"
    unless $bundle->{lazysite_bundle};
my @files = @{ $bundle->{files} || [] };
die "Bundle has no files\n" unless @files;

my ( @ok, @denied );
for my $f (@files) {
    my $p = $f->{path} // '';
    $p =~ s{^/+}{};                                     # treat as docroot-relative
    if ( $p eq '' || $p =~ m{(?:^|/)\.\.(?:/|$)} ) {    # no traversal
        push @denied, { path => $f->{path}, why => 'invalid path' };
        next;
    }
    if ( grep { $p =~ $_ } @DENY ) {
        push @denied, { path => $p, why => 'denied path' };
        next;
    }
    # SM852: WHERE EACH FILE BELONGS, asked rather than assumed. An engine-tree
    # path goes to the engine tree, wherever it lives (SM293 moves it beside the
    # docroot); a content path resolves as every other write to the site's tree
    # does, so a page in a protected section is written into the private store.
    # Built as "$docroot/$p", a bundle recreated a gated section in the served
    # tree beside the protected copy, and the dry run called an existing
    # protected page a "create".
    my ( $abs, $where );
    if ( $p =~ m{\Alazysite/(.+)\z} ) {
        $abs   = Lazysite::Paths::lazysite_dir($docroot) . "/$1";
        $where = -e $abs ? 'engine' : '';
    }
    else {
        ( undef, $where ) = Lazysite::Private::resolve( $docroot, $p );
        ($abs) = Lazysite::Private::resolve_for_write( $docroot, $p );
        $abs //= "$docroot/$p";
    }
    my $op = $where ? 'overwrite' : 'create';
    $op .= ', protected' if index( $abs, Lazysite::Private::private_root($docroot) . '/' ) == 0;
    push @ok, { path => $p, abs => $abs, op => $op, content => $f->{content} // '' };
}

print "Bundle: ", scalar(@files), " file(s); ", scalar(@ok), " allowed, ",
    scalar(@denied), " denied.\n";
print "  [$_->{op}] $_->{path}\n"         for @ok;
print "  [DENIED:$_->{why}] $_->{path}\n" for @denied;

if ($apply) {
    for my $f (@ok) {
        make_path( dirname( $f->{abs} ) );
        open my $out, '>', $f->{abs} or die "write $f->{path}: $!\n";
        print $out $f->{content};
        close $out;
    }
    print "Applied ", scalar(@ok), " file(s) to $docroot.\n";
}
else {
    print "\nDry run - nothing written. Re-run with --apply to write.\n";
}

my @post = @{ $bundle->{post} || [] };
if (@post) {
    print "\nPost-extract actions to run:\n";
    for my $a (@post) {
        if ( $a eq 'clear-cache' ) {
            # SM852: the cache, not every .html - a legacy page or an author's
            # partial with no page source beside it is content (SM133, SM072).
            print "  - clear the page cache (theme/layout/config change):\n";
            print "      the manager's Cache page, or MCP invalidate_cache with path '*'\n";
        }
        else { print "  - $a\n" }
    }
}

exit( @denied && !$apply ? 0 : 0 );

sub usage {
    print <<"USAGE";
Usage: lazysite-bundle-apply.pl --docroot PATH [--apply] [BUNDLE.json]

  --docroot PATH   the site docroot to apply into
  --apply          write the files (default is a dry run / audit)
  BUNDLE.json      bundle file (or read from stdin)

Validates every path against the deny list and confines writes to the docroot.
USAGE
}
sub usage_die { my ($m) = @_; print STDERR "Error: $m\n\n"; usage(); exit 2 }
