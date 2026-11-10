#!/usr/bin/perl
# SM1426: THE SIGNED-IN MARKER HAS ONE WRITER.
#
# The display-only `lzs_session` marker (SM099) is set by a sign-in and set again by a
# renewal (SM1425). Its attributes - SameSite, Path, Max-Age and Secure - belong to one
# helper, Lazysite::Auth::Session::session_marker_header. The sign-in wrapper wrote its
# own copy of the line, so a change to the attributes could reach the renewals and
# miss the sign-in. This reads every engine program and module and holds the line that
# SETS the marker (a non-empty value) to that helper alone. The clearing lines, which
# send an empty value, are not the marker's attributes and are left to their callers.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my @files = ( glob("$root/lazysite-*.pl"), "$root/lazysite-processor", glob("$root/lib/Lazysite/*.pm"), glob("$root/lib/Lazysite/*/*.pm") );
ok( scalar @files > 10, 'the engine programs and modules were found' );

my @writers;
for my $f (@files) {
    my $t = slurp($f);
    push @writers, $f =~ s{^\Q$root\E/}{}r if $t =~ /Set-Cookie:\s*lzs_session=1/;
}
is_deeply( \@writers, ['lib/Lazysite/Auth/Session.pm'], 'only Session.pm writes the marker line' );

my $auth = slurp("$root/lazysite-auth.pl");
like( $auth, qr/Lazysite::Auth::Session::session_marker_header\(/, 'the sign-in wrapper gets the marker from the helper' );

done_testing();
