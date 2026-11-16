#!/usr/bin/perl
# n825 (SM1447, O-2 of the 0.16.12 addendum): run as a user who cannot read part of the
# site, the check printed "[ ok ] every form pattern in page content can be compiled" and
# "[ ok ] protected content is held outside the document root" and then warned that both
# could not read those directories, and "[ ok ] 0 public page(s), each with a title and a
# description of its own" where root finds the pages with no description.
#
# Two causes:
#   - a walk's ok line was printed whether or not the walk read everything (the warning
#     about the directories came after it): report_ok_read now prints none when its walk
#     left something unread;
#   - the public page set: a failed acls.json load governs (and so hides) EVERY page, and
#     the page walk did not say so, so the set was empty and the check said ok about it.
#     scan_pages now names the store as unread.
#
# Sabotage: put report( 'OK' back for the form-pattern or protected-content check, or take
# the acls.json note out of scan_pages, and the matching subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'running as root: a file is never unreadable to it' if $> == 0;

my $tool = repo_root() . '/tools/lazysite-check.pl';
my ($me) = getpwuid($>);

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub run { my ($d) = @_; return run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'discard' )->{out} // '' }

my $OK = qr/\[\s*ok\s*\]/;

subtest 'an unreadable acls.json: the page set is not whole, so no ok about it' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/index.md",   "---\ntitle: Home\n---\nhi\n" );
    spit( "$d/about.md",   "---\ntitle: About\n---\nhi\n" );
    spit( "$d/lazysite/auth/acls.json", "{}" );
    chmod 0000, "$d/lazysite/auth/acls.json" or die $!;
    my $out = run($d);
    chmod 0660, "$d/lazysite/auth/acls.json";
    unlike( $out, qr/$OK \d+ public page\(s\), each with a title/, 'no ok about the public pages' ) or diag $out;
    like( $out, qr/the page title check could not read 1 path\(s\) as \Q$me\E: \S*acls\.json \(Permission denied\)/,
        'the check names the store and the user' ) or diag $out;
};

subtest 'unreadable private-store directories: no ok from the walks that missed them' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/index.md", "---\ntitle: Home\nsubtitle: Home.\n---\nhi\n" );
    my $priv = "$d-lazysite-private";
    my @dirs = map {"$priv/$_"} qw(a b c);
    for my $p (@dirs) { make_path($p) }
    chmod 0000, @dirs or die $!;
    my $out = run($d);
    chmod 0755, @dirs;
    unlike( $out, qr/$OK every form pattern in page content can be compiled/, 'no ok for the form patterns' ) or diag $out;
    unlike( $out, qr/$OK protected content is held outside the document root/, 'no ok for protected content' );
    like( $out, qr/the form-pattern check could not read 3 directories as \Q$me\E/, 'the warning names what was not read' );
    like( $out, qr/run the check as root, or fix the permissions of what it could not read.*owned by \Q$me\E, who ran this check/, 'and the user to run as' ) or diag $out;
};

subtest 'a readable tree still gets its ok lines' => sub {
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/index.md", "---\ntitle: Home\nsubtitle: Home.\n---\nhi\n" );
    my $out = run($d);
    like( $out, qr/$OK every form pattern in page content can be compiled/, 'the form-pattern ok' ) or diag $out;
    like( $out, qr/$OK 1 public page\(s\), each with a title and a description of its own/, 'and the page ok' );
};

done_testing();
