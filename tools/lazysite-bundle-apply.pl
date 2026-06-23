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
use JSON::PP qw(decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my ( $docroot, $apply, $file );
while ( my $a = shift @ARGV ) {
    if    ( $a eq '--docroot' ) { $docroot = shift @ARGV }
    elsif ( $a eq '--apply' )   { $apply = 1 }
    elsif ( $a eq '--help' )    { usage(); exit 0 }
    else                        { $file = $a }
}
usage_die("--docroot is required") unless defined $docroot && length $docroot;
$docroot =~ s{/+$}{};
usage_die("docroot '$docroot' is not a directory") unless -d $docroot;

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
    $p =~ s{^/+}{};                                  # treat as docroot-relative
    if ( $p eq '' || $p =~ m{(?:^|/)\.\.(?:/|$)} ) { # no traversal
        push @denied, { path => $f->{path}, why => 'invalid path' };
        next;
    }
    if ( grep { $p =~ $_ } @DENY ) {
        push @denied, { path => $p, why => 'denied path' };
        next;
    }
    my $abs  = "$docroot/$p";
    my $op   = ( -e $abs ) ? 'overwrite' : 'create';
    push @ok, { path => $p, abs => $abs, op => $op, content => $f->{content} // '' };
}

print "Bundle: ", scalar(@files), " file(s); ", scalar(@ok), " allowed, ",
      scalar(@denied), " denied.\n";
print "  [$_->{op}] $_->{path}\n" for @ok;
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
            print "  - clear the HTML cache (theme/layout/config change):\n";
            print "      find $docroot -name '*.html' -delete\n";
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
