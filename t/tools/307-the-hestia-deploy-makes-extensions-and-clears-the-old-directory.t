#!/usr/bin/perl
# SM1142 S3 (R4): ON HESTIA THE ROOT-RUN SCRIPTS MAKE extensions/, IN THE SAME RELEASE.
#
# A Hestia domain root is mode 0551, so the site user - who runs install.pl -
# cannot create a sibling of public_html. The lazysite-app web template's hook
# and lazysite-hestia-domain.pl make the siblings for a NEW site; an existing
# site never has the template re-applied, so the deploy (root, before the
# user-run install) must make extensions/ on every run, or the upgrade that
# moves the site to it fails on the very first directory it needs. R4 ruled
# against a separate installer release ahead: the deploy runs first anyway.
#
# The other half is the old directory. install.pl's extensions-rename empties
# it but cannot remove it from the 0551 root, so the deploy does - after the
# install, only when empty (a file left there is one the step could not move,
# and the install's summary named it), and never with a recursive remove.
#
# Sabotage: drop the deploy's `mkdir -p "$DOM/extensions"` and the first
# group fails; make the removal `rm -rf` and the last fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root = repo_root();
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }

my $deploy = slurp("$root/installers/hestia/lazysite-hestia-deploy.sh");
my @lines  = split /\n/, $deploy;
my ($install_at) = grep { $lines[$_] =~ /^sudo -u "\$U" perl "\$STAGE\/install\.pl" --mode/ } 0 .. $#lines;
my ($mkdir_at)   = grep { $lines[$_] =~ /^mkdir -p "\$DOM\/extensions"$/ } 0 .. $#lines;
ok( defined $install_at, 'found the deploy\'s install call' ) or BAIL_OUT('the deploy changed shape');
ok( defined $mkdir_at, 'the deploy makes extensions/ beside the docroot' );
cmp_ok( $mkdir_at // 1e9, '<', $install_at, 'before the user-run install, on every run' );
like( $deploy, qr/^for tgt in [^\n]*"\$DOM\/extensions"[^\n]*; do$/m,
    'and hands it to the site user with the other trees the install writes' );

my ($old) = $deploy =~ /^OLD_EXT="\$DOM\/([a-z]+)"$/m;
ok( defined $old, 'the deploy names the old directory once' );
my ($rm_block) = $deploy =~ /^(if \[ -d "\$OLD_EXT" \]; then\n.*?\nfi)$/ms;
ok( $rm_block, 'and has a block that removes it' );
my ($rm_at) = grep { $lines[$_] eq 'if [ -d "$OLD_EXT" ]; then' } 0 .. $#lines;
cmp_ok( $rm_at // -1, '>', $install_at, 'after the install has emptied it' );
unlike( $rm_block // '', qr/\brm\b/, 'with rmdir only - never a recursive remove' );

# Run the block on an emptied and on a non-empty old directory.
my $t = site_tempdir();
for my $case ( [ 'emptied', 0 ], [ 'still holding a file', 1 ] ) {
    my ( $name, $keep ) = @$case;
    my $dom = "$t/$keep";
    make_path("$dom/$old");
    if ($keep) { open my $f, '>', "$dom/$old/left.pl" or die $!; close $f }
    my $r = run_child( [ 'bash', '-c', "set -e\nOLD_EXT='$dom/$old'\n$rm_block\n" ] );
    is( $r->{status}, 0, "the block runs cleanly on the $name directory" );
    is( -d "$dom/$old" ? 1 : 0, $keep, $keep ? 'and leaves it, saying so' : 'and removes it' );
}

like( slurp("$root/installers/hestia/lazysite-app.sh"),
    qr/^mkdir -p "\$domdir\/extensions" "\$domdir\/tools" "\$domdir\/lib"$/m,
    'the web template\'s hook makes extensions/ for a new site' );
like( slurp("$root/tools/lazysite-hestia-domain.pl"), qr/for my \$sib \(qw\(extensions tools lib\)\)/,
    'and so does lazysite-hestia-domain.pl' );

done_testing();
