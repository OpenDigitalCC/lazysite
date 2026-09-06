#!/usr/bin/perl
# SM724: the manager pages a start page may name, and the capability that
# reaches each, are held as data in Lazysite::Manager::StartPage::%PAGES. The
# nav in starter/lazysite/manager/layout.tt has always held the same knowledge
# as template conditionals. Two copies drift: a page the nav shows but the
# table refuses cannot be chosen; a page the table offers but the nav hides
# lands a sign-in on a refusal. This pins them to each other, from the nav's
# own markup.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                   qw(repo_root);
use Lazysite::Manager::StartPage ();

my $root  = repo_root();
my $tt    = do { local ( @ARGV, $/ ) = "$root/starter/lazysite/manager/layout.tt"; <> };
my ($nav) = $tt =~ /(<nav class="mg-nav".*?<\/nav>)/s;
ok( $nav, 'found the manager nav' ) or done_testing, exit;

# Every nav link: page id, and the condition (if any) that shows it.
my %nav;
my $q = chr(34);
for my $line ( split /\n/, $nav ) {
    while ( $line =~ /(?:\[% IF ([^%]+?) %\])?<a href=$q\/manager\/?([a-z-]*)$q/g ) {
        my ( $cond, $page ) = ( $1, $2 );
        $page = 'index' unless length $page;
        my @caps = $cond ? ( $cond =~ /manager_caps\.(\w+)/g ) : ();
        my ($plugin) = $cond ? ( $cond =~ /enabled_plugins\.(\w+)/ ) : ();
        # a page inside two IFs (data: plugin AND cap) - the outer IF is on the same line
        if ( $line =~ /\[% IF enabled_plugins\.(\w+) %\]\[% IF ([^%]+?) %\]<a href=$q\/manager\/\Q$page\E$q/ ) {
            $plugin = $1;
            @caps   = ( $2 =~ /manager_caps\.(\w+)/g );
        }
        $nav{$page} = { caps => [ sort @caps ], plugin => $plugin };
    }
}
cmp_ok( scalar keys %nav, '>=', 12, 'the nav names a dozen or more pages' );

my %table = %Lazysite::Manager::StartPage::PAGES;

subtest 'every nav page is a start page, with the same gate' => sub {
    for my $page ( sort keys %nav ) {
        ok( $table{$page}, "$page: in the table" ) or next;
        is_deeply( [ sort @{ $table{$page}{caps} } ], $nav{$page}{caps}, "$page: the same capabilities (any-of)" );
        # SM759: the table names the registry key (plugins/x.pl); the nav's condition is the id (x).
        my $tp = $table{$page}{plugin} ? ( $table{$page}{plugin} =~ s{^plugins/}{}r =~ s/\.pl\z//r ) : undef;
        is( $tp, $nav{$page}{plugin}, "$page: the same plugin condition" );
    }
};

subtest 'every table page is in the nav - nothing is offered that the nav would hide' => sub {
    for my $page ( sort keys %table ) {
        ok( $nav{$page}, "$page: shown by the nav" );
    }
};

done_testing();
