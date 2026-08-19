#!/usr/bin/perl
# SM389: a static is streamed, not read whole into a pool worker.
#
# _serve_content_static read the entire file into memory before writing a byte,
# in a PERSISTENT worker - so one request for a large upload sized that worker
# to the file and kept it there. Nothing capped it: WebDAV accepts 64m bodies
# by front-end configuration, and an operator publishing video has no reason to
# think a fetch of their own file is a memory event.
#
# A CAP WAS THE OTHER OPTION AND IS WORSE - refusing to serve a file the
# operator legitimately published, to protect a limit they never set, trades an
# availability defect for a resource one.
#
# What this can assert without measuring RSS: the bytes are correct at a size
# well past one block, and the read is blocked rather than slurped in the
# source. The second half is a source assertion and says so - a memory
# assertion from inside the same process would be measuring the wrong thing.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor repo_root);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

make_path("$docroot/lazysite/auth");
open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$acl} "{}\n";
close $acl;

# Several blocks' worth, with a pattern that catches a boundary error: a
# single-block file would pass even if the loop only ever ran once.
make_path("$docroot/lazysite-assets/big");
my $path = "$docroot/lazysite-assets/big/blob.txt";
my $body = join '', map { sprintf "%06d-%s\n", $_, 'x' x 50 } 1 .. 5000;
open my $out, '>', $path or die $!;
binmode $out;
print {$out} $body;
close $out;

subtest 'the file really is bigger than one read block' => sub {
    cmp_ok( length($body), '>', 65_536 * 3,
        'the fixture spans several 64 KiB blocks' )
        or diag( 'A file inside one block would pass with a slurp, a single '
            . 'read, or a broken loop alike.' );
};

subtest 'every byte arrives, in order' => sub {
    my $res = run_processor( $docroot, '/lazysite-assets/big/blob.txt' );
    like( $res, qr{^Content-type: text/plain}mi, 'it was served' )
        or diag($res);

    my ($sent) = $res =~ /\n\r?\n(.*)\z/s;
    is( length( $sent // '' ), length($body), 'the whole file arrived' )
        or diag( 'A short read here is a truncated download - the failure a '
            . 'block loop introduces if it stops on a partial read.' );
    is( sha256_hex( $sent // '' ), sha256_hex($body),
        'and byte-for-byte identical, so no block was dropped or repeated' );
};

subtest 'and it is read in blocks rather than slurped' => sub {
    # A SOURCE assertion, and stated as one. Memory use cannot be observed
    # honestly from inside the same process, and the property that matters -
    # the worker's footprint is a constant, not a function of the file - is
    # structural.
    my $src = do {
        my $p = repo_root() . '/lazysite-processor.pl';
        open my $fh, '<', $p or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /(\nsub _serve_content_static \{.*?\n\}\n)/s;
    ok( $sub, '_serve_content_static is present' ) or return;

    like( $sub, qr/while \( my \$n = read \$fh/,
        'the body is read in blocks' );
    unlike( $sub, qr/local \$\/;\s*<\$fh>/,
        'and not slurped whole' )
        or diag( 'A slurp in a persistent worker sizes that worker to the '
            . 'largest file anyone fetches, and keeps it there.' );
};

done_testing();
