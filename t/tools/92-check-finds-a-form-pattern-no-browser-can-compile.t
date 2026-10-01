#!/usr/bin/perl
# SM921: `lazysite check` finds the bad patterns ALREADY PUBLISHED.
#
# The ruling split the check deliberately: validate_page REFUSES a new one while the
# author is writing it, and this WARNS about the fleet - the sites that already have
# one, which includes every site with a `tel` field, because the engine's own shipped
# default did not compile until 0.15.2. The render path is untouched, so none of
# those pages changes what it does on upgrade.
#
# It is a WARN and not a FAIL: a form that over- or under-validates is not a broken
# install, and a doctor that exits non-zero over page content would stop being run.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
ok( -f $script, 'the check tool is present' ) or BAIL_OUT('no check tool');

# site_tempdir, not a bare tempdir: t/lint/118 keeps a ratcheting ceiling on tests
# that hand the engine a tempdir root as a docroot, because a docroot IS a leaf of a
# site directory and code that walks upwards from it finds the test's own harness
# otherwise.
my $doc = site_tempdir();
my $cgi = "$doc/../cgi-bin";
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", $cgi );
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub page {
    my ( $name, $rules ) = @_;
    open my $fh, '>', "$doc/$name.md" or die $!;
    print {$fh} "---\ntitle: $name\nform: contact\n---\n\n:::form\n$rules\n:::\n";
    close $fh;
    return;
}

my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];
sub run {
    return run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi,
        '--group', $gname );
}

subtest 'a clean site says so' => sub {
    page( 'ok', 'phone | Phone | tel pattern:[0-9\s\(\)\+\.\-]{6,30}' );
    my $out = run();
    like( $out, qr/every form pattern in page content can be compiled/,
        'the OK line is explicit - a check that says nothing when it found nothing '
            . 'is indistinguishable from one that did not run' );
};

subtest 'the pattern the engine used to ship is found' => sub {
    page( 'bad', 'phone | Phone | tel pattern:[\d\s()+.-]{6,20}' );
    my $out = run();
    like( $out, qr/pattern no browser can compile/, 'it is reported' );
    like( $out, qr/bad\.md \(phone\)/,              'naming the page and the field' );
    like( $out, qr/validate nothing at all/,
        'and what it costs: the attribute is ignored in full, so the field is '
            . 'unvalidated rather than loosely validated' );
    like( $out, qr/\[ warn \] \d+ form field\(s\) carry a pattern/,
        'as a warn and not a FAIL - a form that validates loosely is not a broken '
            . 'install, and a doctor that fails over page content stops being run' );
};

subtest 'a pattern cut at a space is found too, because the check reads the line' => sub {
    unlink "$doc/bad.md";
    page( 'spaced', 'phone | Phone | tel pattern:[0-9 ()+.-]{6,30}' );
    my $out = run();
    like( $out, qr/spaced\.md \(phone\)/,
        'the whole pattern is read, so the parentheses after the space are seen - '
            . 'a checker tokenising on whitespace would see `[0-9`, which compiles, '
            . 'and pass a page the browser refuses' );
};

subtest 'the finding is counted as a warning, not a failure' => sub {
    # NOT asserted through the exit status: this fixture is a bare directory tree
    # and has plenty of its own FAILs (no CGI scripts, no manager), so a zero exit
    # was never available here and an assertion on it would have been measuring the
    # fixture. The line's own level is the thing under test.
    my $out = run();
    my ($line) = grep { /pattern no browser can compile/ } split /\n/, $out;
    ok( $line, 'the finding is in the output' );
    like( $line, qr/\[ warn \]/, 'at warn level' );
    unlike( $line, qr/\[ FAIL \]/, 'and not as a failure' );
};

done_testing();
