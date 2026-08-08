#!/usr/bin/perl
# SM235: a WebDAV write that fails because the TARGET DIRECTORY is unwritable
# must answer 507 with a reason, not a bare 500.
#
# The reported case: every PUT to the docroot root returned 500 and wrote
# nothing, while PUTs into subdirectories under the same grant succeeded - the
# docroot itself was not writable by the server user. A 500 cannot distinguish a
# scope refusal, an environment fault and a genuine server error, so the agent
# probed to characterise it and then reported to the operator that root writes
# were denied by policy. They were not. A misleading error costs more than a
# terse one.
#
# The helper is exercised directly: driving a real unwritable-directory PUT would
# need a chmod the test suite cannot rely on (it runs as root in some CI images,
# where every directory is writable and the branch is unreachable).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-dav.pl" or die $!;
    local $/;
    <$fh>;
};

# --- every write failure routes through the one helper ----------------------
# Four sites reported a bare 500 with a two-word body: PUT open, PUT close, PUT
# rename, and MKCOL-adjacent create. If a new one is added that does not use the
# helper, the environment-fault case silently regresses to 500 there.
unlike( $src, qr/send_status\(\s*500,\s*body\s*=>\s*"(?:Cannot write|Write failed|Rename failed|Cannot create)/,
    'no write path still answers with a bare 500 and a two-word body' );
my @calls = ( $src =~ /(_write_failure\()/g );
cmp_ok( scalar @calls, '>=', 4,
    'every write path calls the helper (PUT open / close / rename, and create)' );

# --- the helper's contract --------------------------------------------------
like( $src, qr/sub _write_failure/, '_write_failure is defined' );
like( $src, qr/send_status\(\s*507/s,
    'an unwritable target answers 507 (valid request, server at fault)' );
like( $src, qr/507 => 'Insufficient Storage'/,
    '507 carries a reason phrase' );
like( $src, qr/target directory is not writable/,
    'and the body names the condition' );
like( $src, qr/not a permission\s*"?\s*\.?\s*"?decision about your request/s,
    'and separates it from a permission decision, which is the misreading' );

# The body must NOT leak the filesystem path - a client has no use for it and it
# discloses the layout. The helper takes $abs only to test its parent directory.
# NOTE the capture group: a captureless match in list context yields the success
# flag (1), not the matched text, which silently passes a `defined` check.
my ($body) = $src =~ /(sub _write_failure.*?^\})/ms;
ok( defined $body, 'helper body located' );
unlike( $body, qr/body\s*=>.*\$abs/s,
    'the response body does not interpolate the filesystem path' );
unlike( $body, qr/body\s*=>.*\$dir/s,
    'nor the directory' );
like( $body, qr/log_event\(/, 'the failure is logged for the operator' );

# --- the parent-directory test is what distinguishes the two cases ----------
like( $body, qr/-d \$dir && !-w \$dir/,
    'the environment fault is detected by testing the parent directory' );
like( $body, qr/send_status\(\s*500/s,
    'anything else still answers 500' );

done_testing();
