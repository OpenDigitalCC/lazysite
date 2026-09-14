#!/usr/bin/perl
# N141B: an over-long form field is REFUSED by name, never truncated and stored.
#
# Every submitted field used to go through sanitise_header($v, 10000), which
# TRUNCATES. A value longer than ten thousand characters was silently cut and
# the row was written with ok. The field report that found it: a signature
# captured as a data URL arrived with a valid PNG header and NO IEND - not a
# rejected submission, a corrupt one recorded as good.
#
# WHY TRUNCATION IS THE WRONG FAILURE HERE. sanitise_header is for
# header-shaped values, where cutting an over-long string is safe and nobody
# stores the result. Applied to the data it is the one place cutting is unsafe:
# the submitter is thanked, the row is kept, and nothing downstream can tell
# that what was stored is not what was typed. A corrupt value stored with an ok
# is worse than a refused one.
#
# Ten thousand bytes was also 0.015% of the 64 MiB request this handler already
# accepts, so it protected nothing $MAX_POST_BYTES was not already protecting -
# it only decided, silently, which submissions got damaged.
#
# The release manager's ruling: refuse over-length, and name the field.
#
# DRIVEN AS A REAL POST through the CGI, following 02-uploads.t: the defect is
# in what the handler does with a request, and the plugin runs its whole flow
# at load, so it cannot be poked at as a library.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $PLUGIN = 'plugins/form-handler.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

# A real docroot a level down, not a bare tempdir: $d is handed to the engine as
# DOCUMENT_ROOT below, which is exactly what t/lint/118 is about.
my $d = site_tempdir();
make_path("$d/lazysite/forms");
my $SECRET = 'test-secret-1234567890';
open my $sf, '>', "$d/lazysite/forms/.secret" or die $!;
print $sf "$SECRET\n";
close $sf;
open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
print $hc "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
    . "    enabled: true\n    path: $d/subs\n";
close $hc;
open my $fc, '>', "$d/lazysite/forms/contact.conf" or die $!;
print $fc "targets:\n  - handler: jsonl\n";
close $fc;

my $IP = 0;

sub post {
    my (%f) = @_;
    my $ts = time() - 10;    # inside the 3s..7200s window
    my @pairs = (
        [ '_form', 'contact' ], [ '_ts', $ts ],
        [ '_tk', hmac_sha256_hex( $ts, $SECRET ) ], [ '_hp', '' ],
        map { [ $_, $f{$_} ] } sort keys %f
    );
    my $body = join '&', map {
        my ( $k, $v ) = @$_;
        $v =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge;
        "$k=$v";
    } @pairs;

    my $bf = "$d/.body";
    open my $w, '>:raw', $bf or die $!;
    print {$w} $body;
    close $w;

    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = -s $bf;
    local $ENV{REMOTE_ADDR}    = '10.0.0.' . ( ++$IP );    # fresh IP: no rate limit
    my $out = qx($^X \Q$PLUGIN\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;                          # strip CGI headers
    return eval { decode_json($out) } // { _raw => $out };
}

sub records {
    my $f = "$d/subs/contact.jsonl";
    return () unless -f $f;
    open my $fh, '<', $f or return ();
    my @r = map { decode_json($_) } <$fh>;
    close $fh;
    return @r;
}

# --- a value that used to be cut in half is now stored WHOLE ------------------
#
# 40,000 characters: four times the old silent limit, and far short of the new
# one, so it must arrive intact rather than either truncated or refused.
my $long = 'A' x 40_000;
my $r = post( name => 'Ada', message => $long );
ok( $r->{ok}, 'a 40,000 character field is accepted' ) or diag explain $r;

my ($rec) = records();
ok( $rec, 'and stored' ) or do { done_testing(); exit };
is( length( $rec->{message} // '' ), 40_000,
    'the stored value is the whole value, not the first 10,000 characters' )
    or diag( 'This is the defect: sanitise_header truncated at 10,000 and the '
        . 'row was written with ok, so a signature data URL was stored with a '
        . 'valid header and no terminator.' );
is( $rec->{message}, $long, 'byte for byte' );

# --- over the limit: REFUSED, naming the field, storing nothing --------------
my $before = () = records();
my $huge = 'B' x ( 1024 * 1024 + 1 );    # one byte over
my $big = post( name => 'Ada', statement => $huge );

ok( !$big->{ok}, 'a field over the limit is refused' )
    or diag( 'Silently truncating is the behaviour being removed - accepting '
        . 'it here would mean the row is stored damaged again.' );
like( $big->{error} // '', qr/\bstatement\b/,
    'and the refusal NAMES THE FIELD' )
    or diag( 'The submitter has to know which box to shorten. A generic '
        . '"an error occurred" sends them to retype the whole form.' );
like( $big->{error} // '', qr/too long/i, 'and says what is wrong with it' );
like( $big->{error} // '', qr/nothing was saved/i,
    'and that nothing was kept, so they know to send it again' );

my $after = () = records();
is( $after, $before, 'nothing was written for the refused submission' )
    or diag( 'A refusal that still stores a partial row is the original defect '
        . 'wearing a different message.' );

# --- an ordinary short field is completely unaffected ------------------------
my $ok = post( name => 'Ada', message => 'Hello' );
ok( $ok->{ok}, 'an ordinary submission still succeeds' );
my @all = records();
is( $all[-1]{message}, 'Hello', 'and stores what was typed' );

# --- N141C: the LINE BREAKS a visitor typed survive too ----------------------
#
# The same call used to fold CR and LF to spaces, so a message written as three
# paragraphs was stored as one line and nobody was told. That is the truncation
# defect applied to structure instead of length: a header-shaped rule imposed on
# the data, silently, where the result IS kept.
#
# Ruled by the release manager: keep the newlines. The mail SUBJECT keeps its
# own fold in form-smtp.pl, one line before it is used, which is where a header
# genuinely cannot hold a newline.
my $para = "Dear sir\n\nThe roof leaks.\n\nRegards";
my $mp = post( name => 'Ada', message => $para );
ok( $mp->{ok}, 'a multi-line message is accepted' );

my @after = records();
is( $after[-1]{message}, $para, 'and stored with its line breaks intact' )
    or diag( 'Stored as: ' . ( $after[-1]{message} // '' )
        . "\nFolding CR/LF here loses the paragraphs the visitor typed, keeps "
        . 'the row, and reports success.' );

like( $after[-1]{message}, qr/\n/, 'the stored value really contains a newline' );

# CRLF and a lone CR are normalised to LF, so the store holds ONE spelling of
# "line break" rather than three - a reader comparing two submissions should not
# have to know which browser sent which.
my $crlf = post( name => 'Ada', message => "one\r\ntwo\rthree" );
ok( $crlf->{ok}, 'a CRLF submission is accepted' );
my @norm = records();
is( $norm[-1]{message}, "one\ntwo\nthree",
    'CRLF and a bare CR are both normalised to LF' )
    or diag( 'Three spellings of a line break in one store makes every later '
        . 'comparison and export depend on the submitting browser.' );

done_testing();
