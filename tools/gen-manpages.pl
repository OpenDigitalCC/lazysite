#!/usr/bin/perl
# gen-manpages.pl - render the CLI tools' in-script POD to man pages with
# pod2man (SM126-adjacent / review D7). Man pages are a build artefact (like the
# tarball), generated at release, not committed. Default output is man/man1/
# under the repo; pass a directory to override.
#
#   perl tools/gen-manpages.pl [OUTDIR]
#
# t/tools/27-manpages.t checks the POD is valid and that this generates
# non-empty pages.
use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Path     qw(make_path);

my $root   = dirname( dirname( abs_path($0) ) );
my $outdir = shift @ARGV // "$root/man/man1";
make_path($outdir) unless -d $outdir;

my %scripts = (
    'lazysite-users' => "$root/tools/lazysite-users.pl",
    'lazysite-check' => "$root/tools/lazysite-check.pl",
    'lazysite'       => "$root/tools/lazysite-cli.pl",
    'install'        => "$root/install.pl",
);

my $rc = 0;
for my $name ( sort keys %scripts ) {
    my $src = $scripts{$name};
    my $out = "$outdir/$name.1";
    my @cmd = ( 'pod2man', '--section=1', "--name=" . uc($name),
        '--center=lazysite', '--release=lazysite', $src, $out );
    if ( system(@cmd) == 0 ) {
        print "wrote $out\n";
    }
    else {
        warn "pod2man failed for $name\n";
        $rc = 1;
    }
}
exit $rc;
