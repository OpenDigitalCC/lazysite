#!/usr/bin/perl
# SM418 (CRITICAL): a file upload confined on the REQUEST STRING, not the path.
#
# action_file_upload was the one file-write handler that never called
# validate_path. It stripped slashes from the target directory, kept `..`, and
# then:
#
#   -d "$DOCROOT/content/../lazysite/auth"     SUCCEEDS - the dir really exists
#   realpath boundary check                    SUCCEEDS - it really is inside
#   is_blocked_path("content/../lazysite/...") MISSES  - guard is \Alazysite/
#   write to "$DOCROOT/content/../lazysite/..." the OS resolves `..`
#
# so an unscoped manage_content editor could overwrite lazysite/auth/.secret -
# the cookie-signing key - and mint operator sessions. Reported from a review
# with a working reproduction; reproduced again here before the fix, which is
# what this test is.
#
# THE CONTROL MATTERS AS MUCH AS THE ESCAPE. A handler that refused everything
# would pass every refusal assertion in this file, so an ordinary upload must
# be proven to still work, and a legitimately-blocked target must still be
# refused for its own reason.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Upload ();
use Lazysite::Manager::Common ();

my $SECRET = "ORIGINAL-ENGINE-SECRET\n";

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/forms" );
    open my $s, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$s} $SECRET;
    close $s;
    $Lazysite::Manager::Upload::DOCROOT = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    return $d;
}

# A real multipart body, so the parser and the handler both run for real.
sub upload {
    my ( $dir, $fname, $data, %o ) = @_;
    my $B    = '----SM418';
    my $body = "--$B\r\n"
        . qq{Content-Disposition: form-data; name="overwrite"\r\n\r\n}
        . ( $o{overwrite} ? 1 : 0 ) . "\r\n"
        . "--$B\r\n"
        . qq{Content-Disposition: form-data; name="file"; filename="$fname"\r\n}
        . "Content-Type: application/octet-stream\r\n\r\n"
        . "$data\r\n"
        . "--$B--\r\n";
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$B";
    return Lazysite::Manager::Upload::action_file_upload( $dir, $body );
}

sub slurp {
    my ($p) = @_;
    return '' unless -f $p;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

subtest 'THE ESCAPE: a traversing target cannot reach the auth store' => sub {
    my $d = fixture();
    my $r = upload( 'content/../lazysite/auth', '.secret',
        'MALICIOUS-UPLOAD-MARKER', overwrite => 1 );

    ok( !$r->{ok}, 'the upload is refused' ) or diag explain $r;
    is( slurp("$d/lazysite/auth/.secret"), $SECRET,
        'and the cookie-signing secret is UNTOUCHED - this is the assertion '
            . 'the whole finding is about' );
    ok( !-e "$d/lazysite/auth/.secret.tmp.$$", 'no temp file left behind' );
};

subtest 'deeper and dressed-up spellings are refused too' => sub {
    my $d = fixture();
    for my $dir (
        'content/../../etc',
        'content/./../lazysite/auth',
        'content/../lazysite/../lazysite/auth',
        '../lazysite/auth',
        )
    {
        my $r = upload( $dir, '.secret', 'X', overwrite => 1 );
        ok( !$r->{ok}, "refused: $dir" );
    }
    is( slurp("$d/lazysite/auth/.secret"), $SECRET, 'secret still original' );
};

subtest 'a filename cannot carry the traversal either' => sub {
    my $d = fixture();
    my $r = upload( 'content', '../lazysite/auth/.secret', 'X', overwrite => 1 );
    # sanitise_upload_filename takes the basename, so this lands as ".secret"
    # inside content/ - harmless - but the auth store must be untouched either
    # way, and that is what is asserted rather than the mechanism.
    is( slurp("$d/lazysite/auth/.secret"), $SECRET,
        'the auth store is untouched however the traversal is spelled' );
    ok( !-e "$d/lazysite/.secret", 'and nothing landed a level up' );
};

subtest 'A SYMLINK PIVOT is collapsed - the layer the `..` check cannot see' => sub {
    # THIS CASE EXISTS BECAUSE THE SABOTAGE MATRIX DEMANDED IT. With only the
    # traversal cases above, two sabotages PASSED: handing the blocklist the
    # raw request string, and ignoring validate_path's verdict entirely. Both
    # survived because the upfront `..` refusal had already caught every input
    # I was testing, so the per-file validation was never the thing under test
    # - defence in depth with only the outer layer measured.
    #
    # A symlink has no `..` to reject. `content/escape` is a perfectly ordinary
    # request string that RESOLVES into the auth store, so only the canonical
    # rel derived by validate_path can refuse it - which is exactly the
    # "collapses symlink pivots" the function documents about itself.
    my $d = fixture();
    symlink "$d/lazysite/auth", "$d/content/escape"
        or plan skip_all => 'no symlink support on this filesystem';

    my $r = upload( 'content/escape', '.secret', 'PIVOT-MARKER', overwrite => 1 );
    ok( !$r->{ok} || @{ $r->{errors} || [] },
        'an upload through a symlink into the auth store is refused' )
        or diag explain $r;
    is( slurp("$d/lazysite/auth/.secret"), $SECRET,
        'and the secret is untouched - the blocklist saw the CANONICAL path' );
};

subtest 'a symlink OUT of the docroot is refused' => sub {
    my $outside = tempdir( CLEANUP => 1 );
    my $d       = fixture();
    symlink $outside, "$d/content/away"
        or plan skip_all => 'no symlink support on this filesystem';

    my $r = upload( 'content/away', 'loot.txt', 'X', overwrite => 1 );
    ok( !$r->{ok} || @{ $r->{errors} || [] }, 'refused' ) or diag explain $r;
    ok( !-e "$outside/loot.txt", 'and nothing was written outside the docroot' );
};

# WHAT THE SABOTAGE MATRIX COULD NOT PROVE, recorded rather than faked.
#
# Deleting the `unless ($v->{ok})` guard does not fail any test here, and I
# could not write one that discriminates it. The reason is worth knowing: every
# input that would reach validate_path's ok=0 branch is already refused by the
# handler's own upfront checks - `..` by the SM418 rejection, and a symlink
# leaving the docroot by the pre-existing realpath boundary test on the target
# directory. So the guard is genuinely unreachable through this entry point
# today.
#
# It stays, and is not decoration: it is the only check that sees the RESOLVED
# per-file target, so it is what holds if either upfront check is ever loosened
# or a future caller reaches the loop another way. An earlier version of this
# file asserted "refused by validation, not by a write that happened to fail" -
# that assertion PASSED with the guard deleted, because the upfront check had
# already refused the request. A test that passes for a reason unrelated to
# what it names is worse than no test, so it was removed rather than reworded.

subtest 'CONTROL: an ordinary upload still works' => sub {
    # Without this, a handler that refused everything would pass this file.
    my $d = fixture();
    my $r = upload( 'content', 'photo.png', 'PNGDATA' );
    ok( $r->{ok}, 'the upload succeeds' ) or diag explain $r;
    is( scalar @{ $r->{saved} || [] }, 1,         'one file saved' );
    is( slurp("$d/content/photo.png"), 'PNGDATA', 'with the right bytes' );
    is( $r->{saved}[0]{path}, 'content/photo.png',
        'and the reported path is the canonical one, not the request string' );
};

subtest 'CONTROL: a directly-named blocked target is still refused' => sub {
    # No traversal - the honest spelling. This must be refused by the
    # blocklist, which is a different code path from the `..` rejection, so a
    # fix that only rejected `..` would leave this open.
    my $d = fixture();
    my $r = upload( 'lazysite/auth', '.secret', 'X', overwrite => 1 );
    ok( !$r->{ok} || @{ $r->{errors} || [] },
        'refused when named directly too' );
    is( slurp("$d/lazysite/auth/.secret"), $SECRET, 'secret untouched' );
};

done_testing();
