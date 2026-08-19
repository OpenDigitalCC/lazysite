#!/usr/bin/perl
# SM389: the front-door relay held whatever a client sent.
#
# TWO WAYS IN, and the second is the one a client controls:
#
#   a declared CONTENT_LENGTH was trusted whatever it said
#   NO CONTENT_LENGTH at all - chunked transfer encoding, which the CLIENT
#     chooses, not the operator - was slurped whole under `local $/`
#
# Either sizes the worker to the body, and an FCGI worker PERSISTS: the memory
# does not come back when the request ends. One request can leave a worker fat
# for the rest of its life, and the fuller Apache templates had no cap in front
# of it either (SM389).
#
# The cap is a MEMORY BACKSTOP, not a policy gate. Policy lives downstream -
# manager_upload_max_mb, upload_max_kb, WebDAV's own limit - each refusing with
# an error that names a setting the operator can change. So the backstop follows
# manager_upload_max_mb UP: an operator who raises the upload limit is entitled
# to have uploads work, and a fixed ceiling underneath it would present as
# "uploads broke after a config change" with nothing pointing at it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root      = repo_root();
my $processor = "$root/lazysite-processor.pl";
plan skip_all => "no $processor" unless -f $processor;

my $src = do { open my $fh, '<', $processor or die $!; local $/; <$fh> };

my ($reader) = $src =~ /(sub _read_request_body \{.*?\n\}\n)/s;
my ($capper) = $src =~ /(sub _front_body_cap \{.*?\n\}\n)/s;
ok( $reader, 'the body reader can be isolated' );
ok( $capper, 'the cap can be isolated' ) or BAIL_OUT('cannot extract');

# Run the extracted code in a child with a real STDIN and a real lazysite.conf.
sub drive {
    my (%o) = @_;
    my $d = tempdir( 'lazysite-body-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    mkdir "$d/lazysite";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} $o{conf} // '';
    close $cf;

    open my $bf, '>', "$d/body" or die $!;
    print {$bf} ( 'x' x ( $o{bytes} // 0 ) );
    close $bf;

    my $len     = defined $o{content_length} ? $o{content_length} : '';
    my $harness = <<"H";
use strict;
use warnings;
our \$LAZYSITE_DIR = '$d/lazysite';
sub _conf_value {
    my (\$key) = \@_;
    open my \$fh, '<', "\$LAZYSITE_DIR/lazysite.conf" or return undef;
    while ( my \$l = <\$fh> ) {
        next unless \$l =~ /^\\Q\$key\\E\\s*:\\s*(\\S+)/;
        close \$fh;
        return \$1;
    }
    close \$fh;
    return undef;
}
$capper
$reader
\$ENV{REQUEST_METHOD}  = '@{[ $o{method} // 'POST' ]}';
@{[ length $len ? "\$ENV{CONTENT_LENGTH} = $len;" : "delete \$ENV{CONTENT_LENGTH};" ]}
open STDIN, '<', '$d/body' or die \$!;
my ( \$body, \$too_big ) = _read_request_body( _front_body_cap() );
print length(\$body), ' ', ( \$too_big ? 1 : 0 ), ' ', _front_body_cap(), "\\n";
H
    open my $sh, '>', "$d/run.pl" or die $!;
    print {$sh} $harness;
    close $sh;
    my $out = `$^X \Q$d/run.pl\E 2>&1`;
    chomp $out;
    my ( $got, $big, $cap ) = split ' ', $out;
    return { got => $got, too_big => $big, cap => $cap, raw => $out };
}

my $MB = 1024 * 1024;

# --- the cap itself ----------------------------------------------------
is( drive( bytes => 0, content_length => 0 )->{cap}, 64 * $MB,
    'the default backstop is 64 MiB' );

is( drive( bytes => 0, content_length => 0, conf => "manager_upload_max_mb: 200\n" )->{cap},
    200 * $MB, 'it follows manager_upload_max_mb UP' );

is( drive( bytes => 0, content_length => 0, conf => "manager_upload_max_mb: 5\n" )->{cap},
    64 * $MB, 'but a SMALLER upload limit does not lower it - policy is downstream' );

is( drive( bytes => 0, content_length => 0, conf => "front_max_body_mb: 8\n" )->{cap},
    8 * $MB, 'front_max_body_mb overrides both, including downwards' );

# --- a declared length -------------------------------------------------
{
    my $r = drive( bytes => 1000, content_length => 1000, conf => "front_max_body_mb: 1\n" );
    is( $r->{got},     1000, 'a body within the cap is read whole' );
    is( $r->{too_big}, 0,    'and is not refused' );
}
{
    # Declared far over the cap. It must be refused WITHOUT reading, so the
    # body length returned is zero even though the data is sitting there.
    my $r = drive( bytes => 3 * $MB, content_length => 3 * $MB, conf => "front_max_body_mb: 1\n" );
    is( $r->{too_big}, 1, 'an oversize declared length is refused' );
    is( $r->{got},     0, 'and nothing was allocated for it' );
}

# --- no declared length: the case a client chooses ---------------------
{
    my $r = drive( bytes => 1000, method => 'POST', conf => "front_max_body_mb: 1\n" );
    is( $r->{got},     1000, 'a chunked body within the cap is read whole' );
    is( $r->{too_big}, 0,    'and is not refused' );
}
{
    my $r = drive( bytes => 3 * $MB, method => 'POST', conf => "front_max_body_mb: 1\n" );
    is( $r->{too_big}, 1, 'a chunked body over the cap is refused' );
    is( $r->{got},     0, 'and is not handed on' );
}

# A GET has no body to read whatever is on the handle.
{
    my $r = drive( bytes => 3 * $MB, method => 'GET', conf => "front_max_body_mb: 1\n" );
    is( $r->{got},     0, 'a GET reads no body' );
    is( $r->{too_big}, 0, 'and is not refused for one' );
}

done_testing();
