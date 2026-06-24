#!/usr/bin/perl
# SM079 step 3a: Lazysite::Manager::Common - shared path/deny/write helpers,
# unit-tested in-process.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(validate_path is_blocked_path write_file_checked
    is_blocked_config is_blocked_upload_target upload_limits);

my $d = tempdir( CLEANUP => 1 );
$Lazysite::Manager::Common::DOCROOT = $d;

# validate_path
my $r = validate_path('content/x.md');
ok( $r->{ok}, 'valid path accepted' );
is( $r->{rel}, 'content/x.md', 'leading slash normalised' );
ok( !validate_path('')->{ok}, 'empty path rejected' );
ok( !validate_path('../../etc/passwd')->{ok}, 'traversal rejected' );

# is_blocked_path (silence the WARN it logs)
{
    my $buf = '';
    local *STDERR;
    open STDERR, '>', \$buf or die;
    ok( is_blocked_path('lazysite/auth/.secret'), 'secret path blocked' );
    ok( is_blocked_path('cgi-bin/x.pl'),          '*.pl blocked' );
    ok( !is_blocked_path('content/about.md'),     'normal content allowed' );
}

# write_file_checked
my ( $ok, $err ) = write_file_checked( "$d/out.txt", 'hello' );
ok( $ok && !defined $err, 'write succeeds' );
open my $fh, '<', "$d/out.txt" or die;
is( do { local $/; <$fh> }, 'hello', 'content written' );
close $fh;
my ( $ok2, $err2 ) = write_file_checked( "$d/missing-dir/out.txt", 'x' );
ok( !$ok2 && $err2, 'write into a missing dir fails with an error' );

# is_blocked_config (deny-by-config: blocked path prefixes + upload extensions)
{
    my $buf = '';
    local *STDERR;
    open STDERR, '>', \$buf or die;
    ok( is_blocked_config('lazysite/auth/x'), 'lazysite/auth prefix blocked by config' );
    ok( is_blocked_config('cgi-bin/y'),       'cgi-bin prefix blocked' );
    ok( !is_blocked_config('content/page.md'), 'normal content not config-blocked' );
    ok( is_blocked_upload_target('evil.pl'),  'pl extension blocked for upload targets' );
    ok( !is_blocked_config('evil.pl'),        'extension only checked when requested' );
}
my $lim = upload_limits();
is( ref $lim, 'HASH', 'upload_limits returns a hashref' );
ok( $lim->{max_bytes} > 0, 'upload_limits has a max_bytes default' );

done_testing();
