#!/usr/bin/perl
# SM1412 (ruling 159): `lazysite check` names a site whose lazysite/notify.conf
# still sets owner_contact (SM1362, retired and ignored from 0.16.8), as a WARN
# with the remedy - a notify handler on the form whose recipients name the
# people, a group. Silent when the key is absent or empty. It changes nothing,
# with or without --fix.
#
# With the check removed, no such WARN is printed (the first assertions fail).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
my $doc    = site_tempdir();
my $cgi    = "$doc/../cgi-bin";
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", $cgi );
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $c = <$f>; close $f; return $c }
sub check { run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname, @_ ) }

put( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
my $notify = "$doc/lazysite/notify.conf";
put( $notify, "mail.per_hour: 5\nowner_contact: owner\@example.org\n" );
my $before = slurp($notify);

my $out  = check();
my @warn = grep { /sets owner_contact/ } split /\n/, $out;
is( scalar @warn, 1, 'the key is named once' ) or diag $out;
like( $warn[0] // '', qr/\[ warn \]/,                       'as a WARN' );
like( $warn[0] // '', qr/no longer reads \(retired in 0\.16\.8\)/, 'saying it is ignored' );
like( $out, qr/add a notify handler on the Handlers page whose recipients name them/, 'the remedy' );
like( $out, qr/\[\{"groups":\["site-owners"\]\}\]/, '  naming a group' );

is( slurp($notify), $before, 'the check changed nothing' );
check('--fix');
is( slurp($notify), $before, 'and --fix changes nothing either' );

subtest 'silent when the key is not set, or set empty' => sub {
    put( $notify, "mail.per_hour: 5\n" );
    unlike( check(), qr/owner_contact/, 'absent: nothing said' );
    put( $notify, "owner_contact:\n" );
    unlike( check(), qr/owner_contact/, 'empty: nothing said' );
    unlink $notify;
    unlike( check(), qr/owner_contact/, 'no notify.conf: nothing said' );
};

done_testing;
