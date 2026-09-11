#!/usr/bin/perl
# SM833's remainder: a Perl reference never reaches a visitor, whatever put it
# in the template.
#
# The reported instance - a refused db count rendering ARRAY(0x...) - was fixed
# where it arose. The filing also asked for the net under the next one: a value
# reaching the page as a stringified reference is a defect the renderer can
# catch rather than pass through, and it publishes a heap address while it is at
# it. `[% theme %]` is the reference every site has: the theme data is a hash in
# every render, active theme or not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor load_processor);

my $d = site_tempdir();
setup_minimal_site($d);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

sub body_of {
    my ($uri) = @_;
    my $out = run_processor( $d, $uri ) // '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

spit( "$d/leak.md", "---\ntitle: Leak\n---\n\nBEFORE[% theme %]AFTER\n" );
my $out = body_of('/leak');
like( $out, qr/BEFORE/, 'the canary: the page rendered, so an absence below is not a blank page' );
unlike( $out, qr/HASH\(0x[0-9a-f]+\)/, 'no stringified reference reaches the visitor' );
like( $out, qr/BEFOREAFTER/, 'the reference is removed where it stood, and nothing else is' );
like( slurp("$d/leak.html"), qr/BEFOREAFTER/, 'and the cached copy is the clean one - the next visitor gets it too' );

# The log goes to STDERR, which the request rig discards; the sub is called
# directly to read it.
load_processor($d);
{
    my $log = '';
    local *STDERR;
    open STDERR, '>', \$log or die $!;
    my $clean = main::_strip_leaked_refs( 'x Foo::Bar=HASH(0x5f00d1e2c3b4) y', 'source', "$d/leak.md" );
    close STDERR;
    is( $clean, 'x  y', 'a blessed reference goes too, class name and all' );
    like( $log, qr/a Perl reference reached the page and was removed.*leak\.md/,
        'and the removal is logged, naming the page, so a lost value can be found' );
}

# An author writing ABOUT the defect is not the defect: the address is in the
# source, so it was typed, not leaked.
spit( "$d/about-the-bug.md",
    "---\ntitle: Bug\n---\n\nThe page printed `ARRAY(0x55d4c3a2b1e8)` where a number belonged.\n" );
like( body_of('/about-the-bug'), qr/ARRAY\(0x55d4c3a2b1e8\)/, 'an address the author wrote is left as written' );

done_testing();
