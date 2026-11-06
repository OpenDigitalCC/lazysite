#!/usr/bin/perl
# old-address-name: begin (SM1343, the test builds a site with the old template calls)
# SM1380 (found at the 0.16.5 edge deploy): THE TEMPLATE-CALL RENAME NAMES A
# DIRECTORY IT CANNOT READ, IN THE SUMMARY, AND PRINTS NO RAW PERL WARNING.
#
# install.pl's rewrite_template_calls (SM1345) walks the docroot, the lazysite
# directory and the private store with File::Find. Run as a user that cannot read
# part of the private store, File::Find printed "Can't opendir(...): Permission
# denied" to STDERR and the old visitor.in_list / visitor.in_any calls below it
# stayed unrenamed with nothing in the summary. Now the walk's warnings are
# collected and become one ADDRESS PROFILES warning naming the directory, and the
# once-step is not recorded, so the next upgrade tries again.
#
# Sabotage: with the collection taken out of rewrite_template_calls, STDERR carries
# the raw opendir line and the summary names nothing - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_manifest_guard repo_root);

plan skip_all => 'root reads a mode-000 directory, so the case cannot be built' if $> == 0;

my $MF_GUARD = repo_manifest_guard();
my $ROOT     = repo_root();
my $INSTALL  = "$ROOT/install.pl";

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $docroot = TestHelper::site_tempdir();
( my $cgibin = $docroot ) =~ s{/[^/]+\z}{/cgi-bin};
make_path($cgibin);

# As t/tools/315 runs it, but with STDOUT and STDERR apart.
sub install {
    my ($mode) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $errf = "$docroot.stderr";
    my @args = ( '--docroot', $docroot, '--cgibin', $cgibin, '--mode', $mode,
        '--serving-group', ( getgrgid( $) + 0 ) // ( $) + 0 ) ) );
    my $cmd = join ' ', map {quotemeta} $^X, $INSTALL, @args;
    my $out = `$cmd 2>\Q$errf\E`;
    my $rc  = $? >> 8;
    my $err = slurp($errf) // '';
    unlink $errf;
    return ( $rc, $out, $err );
}

my ( $rc, $out, $err ) = install('provision');
is( $rc, 0, 'the site is provisioned' ) or diag "$out\n$err";

my $lz   = "$docroot/lazysite";
my $sp   = "$lz/.install-state.json";
my $priv = "$docroot-lazysite-private";
my $shut = "$priv/sites";
make_path("$shut/inner");
spit( "$shut/inner/page.md", "---\ntitle: P\n---\n[% IF visitor.in_list('office') %]x[% END %]\n" );
spit( "$priv/open.md", "---\ntitle: O\n---\n[% IF visitor.in_list('office') %]y[% END %]\n" );
# The step not yet done, as on a 0.16.4 site.
spit( $sp, slurp($sp) =~ s/"address-profiles-converted",?//r =~ s/,(\s*\])/$1/r );
chmod 0000, $shut or die "chmod: $!";

( $rc, $out, $err ) = install('reinstall');
chmod 0755, $shut;
is( $rc, 0, 'the upgrade succeeds' ) or diag "$out\n$err";

unlike( $err, qr/Can't (?:opendir|stat|cd to)/, 'no raw File::Find warning on STDERR' ) or diag $err;
like( "$out\n$err", qr/ADDRESS PROFILES: could not read 1 directory as \S+: \Q$shut\E \([^)]+\)/,
    'the summary names the directory it could not read' ) or diag "$out\n$err";
like( "$out\n$err", qr/visitor\.in_list or visitor\.in_any call below it was not renamed.*run the upgrade again as root/s,
    '  and says what was left and how to finish it' );
like( slurp("$priv/open.md"), qr/visitor\.in_profile\('office'\)/, 'a readable file in the store is still renamed' );
like( slurp("$shut/inner/page.md"), qr/visitor\.in_list\('office'\)/, 'the unread one is untouched' );
unlike( slurp($sp) // '', qr/"address-profiles-converted"/, 'the step is not recorded, so the next upgrade tries again' );

( $rc, $out, $err ) = install('reinstall');
is( $rc, 0, 'readable again, the next upgrade succeeds' ) or diag "$out\n$err";
like( slurp("$shut/inner/page.md"), qr/visitor\.in_profile\('office'\)/, '  and renames what was left' );
like( slurp($sp) // '', qr/"address-profiles-converted"/, '  and records the step' );

# old-address-name: end

done_testing();
