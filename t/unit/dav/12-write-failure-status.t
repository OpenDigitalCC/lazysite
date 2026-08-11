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

# SM284: and the other four verbs, which met the identical condition and each
# had their own two-word body. Named individually rather than as a pattern,
# because a regression here reads as a wording change and would be reviewed as
# one - these strings are the whole of what an agent had to act on.
for my $gone ( 'Delete failed', 'Operation failed', 'Cannot create collection\\\\n' ) {
    unlike( $src, qr/send_status\(\s*\d+,\s*body\s*=>\s*"\Q$gone\E/,
        "the bare \"$gone\" answer is gone" );
}

my @calls = ( $src =~ /(_write_failure\()/g );
cmp_ok( scalar @calls, '>=', 8,
    'all five write verbs call the helper (PUT open / close / rename / create, '
        . 'plus MKCOL, DELETE, MOVE and COPY)' );

# The two-directory verbs must say WHICH directory. MOVE can fail on either
# side, and "the target directory" would be a guess presented as a fact.
like( $src, qr/\[\s*\$dst->\{abs\},\s*'destination'\s*\]/,
    'MOVE/COPY label the destination' );
like( $src, qr/\[\s*\$src->\{abs\},\s*'source'\s*\]/,
    'and MOVE labels the source, which is the side a caller cannot guess' );

# MKCOL's two 409s. One is the caller's problem (create the parent), the other
# was a server fault wearing a client error's status.
like( $src, qr/parent collection does not exist/,
    'MKCOL says a missing parent is a missing parent' );

# --- the helper's contract --------------------------------------------------
like( $src, qr/sub _write_failure/, '_write_failure is defined' );
like( $src, qr/send_status\(\s*507/s,
    'an unwritable target answers 507 (valid request, server at fault)' );
like( $src, qr/507 => 'Insufficient Storage'/,
    '507 carries a reason phrase' );
like( $src, qr/the \$role directory is not writable/,
    'and the body names the condition, and which directory it means' );
# SM284 widened the message from "the target directory" to "the $role
# directory" so MOVE can distinguish its two. 'target' stays the DEFAULT, which
# is what keeps PUT's wording byte-identical to what SM235 shipped and reviewed.
like( $src, qr/\(\s*\$w,\s*'target'\s*\)/,
    "an unlabelled path is still the 'target' directory" );
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
