#!/usr/bin/perl
# n814 (SM1437), ruling 206: A CHECK THAT COULD NOT READ THE PAGES MUST NOT SAY OK.
#
# Run as the site user, the page-set check printed
#   [  ok  ] 0 public page(s), each with a title and a description of its own
# for a docroot that, run as root, has 17 undescribed pages and 4 shared titles.
# The processor's page walk opened a directory it could not read, skipped it and
# said nothing, so an empty set read as a clean one. The walk now hands back what
# it could not read, and the check names it, names the user, and does not say ok.
#
# Needs a user who is not root (a root user reads every directory).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'a root user can read every directory' if $> == 0;

my $script = repo_root() . '/tools/lazysite-check.pl';
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub check_out { run_child( [ $^X, $script, '--docroot', $_[0] ], stderr => 'merge' )->{out} // '' }

my $doc = site_tempdir();
make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$doc/index.md",               "---\ntitle: Home\nsubtitle: Welcome\n---\nH\n" );

subtest 'every page readable: the line says ok' => sub {
    my $out = check_out($doc);
    like( $out, qr/\[  ok  \] 1 public page\(s\), each with a title and a description of its own/, 'ok' ) or diag $out;
    unlike( $out, qr/page title check could not read/, 'and names nothing unread' );
};

subtest 'a directory the user cannot open: named, and not ok' => sub {
    make_path("$doc/members");
    spit( "$doc/members/a.md", "---\ntitle: A\n---\nA\n" );
    chmod 0000, "$doc/members" or die $!;
    my $out = check_out($doc);
    chmod 0755, "$doc/members";
    like( $out, qr/\[ warn \] the page title check could not read 1 path\(s\) as \S+: \Q$doc\E\/members \(/,
        'the warning names the directory and the user' )
        or diag $out;
    like( $out, qr/were not looked at, so the public page count/, 'and says the count is partial' );
    like( $out, qr/run the check as root/, 'with the user to run it as' );
    unlike( $out, qr/\[  ok  \] \d+ public page\(s\), each with a title and a description/,
        'and the ok line is not printed' )
        or diag $out;
};

subtest 'a page the walk could not open is named too' => sub {
    spit( "$doc/closed.md", "---\ntitle: Closed\nsubtitle: S\n---\nC\n" );
    chmod 0000, "$doc/closed.md" or die $!;
    my $out = check_out($doc);
    chmod 0644, "$doc/closed.md";
    like( $out, qr/page title check could not read 1 path\(s\) as \S+: \Q$doc\E\/closed\.md/, 'the page is named' )
        or diag $out;
    unlike( $out, qr/\[  ok  \] \d+ public page\(s\), each with a title/, 'not ok' );
};

done_testing;
