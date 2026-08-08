#!/usr/bin/perl
# SM240: action_save_binary writes BYTES.
#
# action_save opens '>:utf8' and is text-only, so an MCP-only agent could not
# place a single non-text byte on a site it otherwise had full manage_content
# over - no webfont, no photograph, no favicon.ico. That gap is why MCP-built
# sites import fonts from a CDN, hotlink photography and have no favicon: each is
# a rule the agent was given and could not follow.
#
# The point of these tests is that adding the capability adds NO privilege. The
# gates must be exactly action_save's: engine-owned paths, the dangerous-extension
# blocklist, the size cap and the per-file ACL all refuse identically. And the
# bytes must survive - a round-trip through the text path is precisely what
# corrupts them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/manager/locks", "$d/assets" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

$Lazysite::Manager::Files::DOCROOT   = $d;
$Lazysite::Manager::Files::LOCK_DIR  = "$d/lazysite/manager/locks";
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT        = $d;

sub slurp_raw {
    open my $fh, '<', $_[0] or return undef;
    binmode $fh;
    local $/;
    return <$fh>;
}

# --- bytes survive, which is the whole point ---------------------------------
# A PNG header plus a NUL and a high byte: all three are things the :utf8 text
# path mangles.
my $png = "\x89PNG\r\n\x1a\n\x00\xff\xfe\x01\x02";
{
    my $r = Lazysite::Manager::Files::action_save_binary(
        'assets/logo.png', 'alice', $png );
    ok( $r->{ok}, 'a binary write succeeds' );
    is( $r->{bytes}, length($png), 'it reports the byte count' );
    ok( $r->{created}, 'and reports the file as created' );
    is( slurp_raw("$d/assets/logo.png"), $png,
        'the bytes round-trip EXACTLY - no encoding, no truncation at the NUL' );
}

# Overwriting reports created=false, so a caller can tell the two apart.
{
    my $r = Lazysite::Manager::Files::action_save_binary(
        'assets/logo.png', 'alice', $png . "\x00" );
    ok( $r->{ok}, 'overwrite succeeds' );
    ok( !$r->{created}, 'and is reported as an edit, not a create' );
}

# --- the gates are action_save's, unchanged ----------------------------------
{
    # Executable extensions: the DANGEROUS_RE blocklist is enforced inside
    # is_blocked_path, so a binary write inherits it rather than re-stating it.
    for my $bad (qw(evil.pl evil.cgi evil.php .htaccess)) {
        my $r = Lazysite::Manager::Files::action_save_binary( $bad, 'alice', $png );
        ok( !$r->{ok}, "refuses an executable/config extension: $bad" );
    }

    # Engine-owned areas.
    my $r = Lazysite::Manager::Files::action_save_binary(
        'lazysite/auth/users', 'alice', $png );
    ok( !$r->{ok}, 'refuses a write into the auth store' );

    # Traversal.
    my $t = Lazysite::Manager::Files::action_save_binary(
        '../escape.png', 'alice', $png );
    ok( !$t->{ok}, 'refuses a traversal path' );
}

# --- the size cap is named, not silent ---------------------------------------
{
    my $limits = Lazysite::Manager::Common::load_upload_limits();
    my $over   = 'x' x ( ( $limits->{max_bytes} // 10 * 1024 * 1024 ) + 1 );
    my $r = Lazysite::Manager::Files::action_save_binary(
        'assets/huge.bin', 'alice', $over );
    ok( !$r->{ok}, 'refuses a file over the cap' );
    is( $r->{kind}, 'too-large', 'with a machine-readable kind' );
    like( $r->{error}, qr/at most \d+/, 'and the limit named in the message' );
    ok( !-e "$d/assets/huge.bin", 'nothing is written when it is refused' );
}

# --- a refusal never leaves debris -------------------------------------------
{
    my @tmp = glob("$d/assets/*.tmp");
    ok( !@tmp, 'no temp files left behind' ) or diag "@tmp";
}

done_testing();
