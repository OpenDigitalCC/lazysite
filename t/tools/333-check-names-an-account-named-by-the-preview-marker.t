#!/usr/bin/perl
# SM1390 (ruling 147): `lazysite check` names an account named by the preview
# cookie's marker. Since SM1390 the session verifier refuses a payload beginning
# with that marker, so such an account signs in and is refused on every request;
# the creating doors refuse the name now, and this is the answer for an account
# that already existed. The marker is the verifier's constant, so the test asks
# it rather than spelling it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Auth::Session ();

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;
my $marker = Lazysite::Auth::Session::PREVIEW_MARKER();

sub site {
    my ($users) = @_;
    my $doc = site_tempdir();
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    if ( defined $users ) {
        open my $fh, '>', "$doc/lazysite/auth/users" or die $!;
        print {$fh} $users;
        close $fh;
    }
    return $doc;
}
sub run_check { my ($doc) = @_; return qx($^X \Q$script\E --docroot \Q$doc\E 2>&1) }

my $out = run_check( site("alice:x\n$marker:x\nbob:x\n") );
like( $out, qr/an account named '\Q$marker\E', the preview cookie's marker/, 'the account is named' ) or diag $out;
like( $out, qr/cannot sign in/, 'with what it means' );
like( $out, qr/users rename \Q$marker\E NEW-NAME/, 'and the remedy' );

my $quiet = run_check( site("alice:x\n${marker}x:x\nx$marker:x\n") );
like( $quiet, qr/no account is named by the preview cookie's marker/, 'names that merely contain it are not it: OK' );
unlike( $quiet, qr/cannot sign in/, 'and nothing is named' );

my $none = run_check( site(undef) );
unlike( $none, qr/preview cookie's marker/, 'a site with no users file says nothing either way' );

done_testing();
