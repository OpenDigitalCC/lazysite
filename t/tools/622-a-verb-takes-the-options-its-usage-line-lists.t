#!/usr/bin/perl
#
# n807 / SM1427: A VERB TAKES THE OPTIONS ITS USAGE LINE LISTS.
#
# `lazysite --help` said `repair --docroot D | --domain NAME | --all` and
# `probe --docroot D | --domain NAME | --all`. Both verbs read their sites through
# extract_site_targets, which took --domain and --all only, so `repair --docroot D`
# died with "Unknown option: docroot / bad options for repair" - while the check's
# own remedy text, and the installer's group message, tell a sysop to type exactly
# that. A site with no registry entry has no --domain to give.
#
# Two things are held here:
#   1. the verbs that run safely against a directory that is not there are RUN with
#      --docroot, and none may answer "Unknown option" (they stop at "not a
#      directory", which is a refusal about the site and proves the option was read);
#   2. every verb whose usage line lists --docroot is in one of two lists below, so
#      a verb added to the usage text must be put in one on purpose: run here, or
#      named as one this file does not run, with the reason.
# --docroot on a real site is then run through `repair` end to end.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $CLI  = "$root/tools/lazysite-cli.pl";

# Run here: each stops at "not a directory" for a docroot that is not there.
my @RUN = qw(repair probe migrate-engine-tree);

# Not run here, each because it writes or installs (a refusal would need a site),
# or because --docroot is optional for it (validate).
my @NOT_RUN = qw(provision upgrade reinstall backups starter channel policy validate);

my $usage = qx($^X \Q$CLI\E --help 2>&1);
my %listed;
while ( $usage =~ /^  ([a-z][a-z-]*) [^\n]*--docroot/mg ) { $listed{$1} = 1 unless $1 eq "lazysite" }    # "lazysite" opens an example
cmp_ok( scalar keys %listed, '>=', 8, 'the usage text was parsed (verbs that list --docroot found)' )
    or diag $usage;

my %known = map { $_ => 1 } @RUN, @NOT_RUN;
is_deeply( [ sort grep { !$known{$_} } keys %listed ], [],
    'every verb whose usage lists --docroot is either run here or named as not run' );
is_deeply( [ sort grep { !$listed{$_} } @RUN ], [], 'and every verb run here lists --docroot' );

my $T = Cwd::realpath( site_tempdir() );
local $ENV{LAZYSITE_REGISTRY_DIR} = "$T/registry";
make_path("$T/registry");

for my $verb (@RUN) {
    my $out = qx($^X \Q$CLI\E $verb --docroot /nonexistent/n807 2>&1);
    unlike( $out, qr/Unknown option|bad options|unknown option/i,
        "$verb takes --docroot, as its usage line says" )
        or diag $out;
    like( $out, qr/not a directory|no such|does not exist|no engine tree/i,
        "$verb reads the docroot it was given and refuses the missing one" )
        or diag $out;
}

# End to end: a site with no registry entry, named by its docroot.
my $doc = "$T/unlisted/public_html";
make_path( "$doc/lazysite/auth", "$doc/lazysite/logs" );
open my $fh, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$fh} "site_name: T\n";
close $fh;
my $out = qx($^X \Q$CLI\E repair --docroot \Q$doc\E --dry-run 2>&1);
like( $out, qr/^== unlisted$/m, 'repair --docroot names the site and checks it' ) or diag $out;
unlike( $out, qr/no sites registered|Unknown option/, 'and needs no registry entry' ) or diag $out;

my $both = qx($^X \Q$CLI\E repair --docroot \Q$doc\E --all 2>&1);
like( $both, qr/alternatives: give one/, '--docroot with --all is refused, not guessed' ) or diag $both;

done_testing();
