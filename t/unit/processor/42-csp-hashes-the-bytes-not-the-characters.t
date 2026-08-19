#!/usr/bin/perl
# SM384: the CSP hash must be over the BYTES the browser receives.
#
# A TT-rendered response is a CHARACTER string. Digest::SHA operates on bytes
# and DIES on a wide character - "Wide character in subroutine entry" - so a
# single non-ASCII character anywhere inside an inline <script> aborted the
# response mid-headers and the browser got a 200 with an empty body.
#
# ON THE MANAGER THAT WAS EVERY PAGE, IN THE DEFAULT MODE. The manager's own
# scripts carry non-ASCII, and report-only is the default, so the manager was
# down in every mode except `csp: off`.
#
# AND THE QUIETER HALF: U+0080-U+00FF does not die. It hashes the LATIN-1 byte
# where the browser hashes the two UTF-8 bytes it actually received, so the hash
# does not match and the script is silently refused.
#
# WHY NO TEST SAW IT. Nothing in this suite renders a manager page end to end
# through the real layout, and every fixture's inline script was ASCII. Found by
# driving a real browser against a real manager - which is also why the shipped
# catalogue was clean: by luck, not by design.
use strict;
use warnings;
use utf8;
use Test::More;
use Digest::SHA  qw(sha256);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                ();
use Lazysite::SecurityHeaders qw(inline_script_hashes);

# The processor's ADR-0001 copy, evaluated out of its source - it cannot be
# loaded, because the file runs its main body at file scope.
my $root = TestHelper::repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};
my ($sub) = $src =~ /(\nsub _inline_script_hashes \{.*?\n\}\n)/s;
ok( $sub, 'the processor carries its own copy' );
eval "package ProcCopy; use Digest::SHA qw(sha256); "
    . "use MIME::Base64 qw(encode_base64); $sub 1;"
    or die "eval: $@";

# A KNOWN VECTOR, computed from the UTF-8 bytes rather than by calling the code
# under test - a hash wrong in both copies agrees with itself perfectly.
sub want_hash {
    my ($text) = @_;
    my $bytes = $text;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    return "'sha256-" . encode_base64( sha256($bytes), '' ) . "'";
}

# DOUBLE QUOTES, and it matters more than it looks. The first version of this
# used single quotes, so \x{e9} was a literal backslash-x-brace sequence and
# every case was pure ASCII - the fixture never contained a non-ASCII character
# at all, and the whole file passed against the UNFIXED code.
my %CASE = (
    'plain ascii'            => "var a = 1;",
    'latin-1 range (U+00E9)' => "var s = \"caf\x{e9}\";",
    'em dash (U+2014)'       => "var s = \"a \x{2014} b\";",
    'CJK (U+4E2D)'           => "var s = \"\x{4e2d}\x{6587}\";",
    'emoji (U+1F600)'        => "var s = \"\x{1f600}\";",
);

# The fixture has to prove it IS what it claims, or the run above repeats.
for my $name ( sort keys %CASE ) {
    next if $name eq 'plain ascii';
    ok( $CASE{$name} =~ /[^\x00-\x7F]/,
        "fixture '$name' really contains a non-ASCII character" )
        or diag( 'Single-quoted \x{...} is a literal backslash sequence. A '
            . 'fixture that is secretly ASCII passes against the defect.' );
}

for my $name ( sort keys %CASE ) {
    my $body = $CASE{$name};
    my $html = "<html><head><script>$body</script></head></html>";

    subtest $name => sub {
        my @mod = eval { inline_script_hashes($html) };
        ok( !$@, 'the module does not die' )
            or diag( "died: $@\n"
                . 'A response that dies mid-headers reaches the browser as a '
                . '200 with an empty body - which is what the manager was '
                . 'doing in the default mode.' );

        my @proc = eval { ProcCopy::_inline_script_hashes($html) };
        ok( !$@, 'and neither does the processor copy' ) or diag("died: $@");

        is_deeply( \@mod, [ want_hash($body) ],
            'the module hashes the UTF-8 bytes a browser would' )
            or diag( 'A hash over the CHARACTERS does not match what the '
                . 'browser received, and the script is refused with nothing '
                . 'anywhere to say why.' );
        is_deeply( \@proc, \@mod, 'and the two copies agree' );
    };
}

done_testing();
