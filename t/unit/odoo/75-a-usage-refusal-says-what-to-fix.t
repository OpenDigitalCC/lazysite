#!/usr/bin/perl
# SM1186 (OOM Lab L-18): "A read whose operation throws a usage error answers 400
# 'the operation refused what it was given - see the event log'. The operation's
# own message, for example a bad date, is not passed on, so a page cannot tell
# the person what to fix."
#
# OOM's `usage` errors are its statements about the caller's own input, written
# for the caller, so the page now gets the message (and the fix line) of those -
# capped, stripped of control characters, and WITHHELD when it carries a host
# path, a long token or a traceback. Every other kind keeps the generic sentence
# and its text stays in the event log (SM747 OB5). The batch path is the same
# fault() as a single call.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Odoo::Error;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
$Lazysite::Odoo::TRANSPORT = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
bind( $d, id => 'week', operation => 'shop.week', modes => 'public', params => 'date=date' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body ) = @_;
    my ( $out, $err ) = ( '', '' );
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', ( $ENV{COOKIE} ? ( HTTP_COOKIE => $ENV{COOKIE} ) : () ) );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my ($vcookie) = grep { /\Alzs_odoo_visitor=/ } @$vc;
$vcookie =~ s/;.*//s;
my $VT = $tok->{visitor_token};

sub one {
    my ($date) = @_;
    local $ENV{COOKIE} = $vcookie;
    return request( 'POST', '', { binding => 'week', params => { date => $date }, visitor_token => $VT } );
}

sub batch {
    my (@dates) = @_;
    local $ENV{COOKIE} = $vcookie;
    my ( $st, undef, $j ) = request( 'POST', '',
        { calls => [ map { { binding => 'week', params => { date => $_ } } } @dates ], visitor_token => $VT } );
    return ( $st, $j );
}

subtest 'a usage refusal reaches the page with the operation\'s own message and fix' => sub {
    my ( $st, undef, $j, $raw ) = one('bad');
    is( $st,        400,       'answered 400' ) or diag $raw;
    is( $j->{kind}, 'invalid', 'kind invalid, as before' );
    is( $j->{error}, "shop.week: date 'bad' is not a date", 'the operation\'s message is the error' );
    is( $j->{fix},   'give the date as YYYY-MM-DD',          'and its fix line is passed' );
    unlike( $j->{error}, qr/see the event log/, 'not the generic sentence' );
};

subtest 'an over-long message is capped, and control characters are cleaned' => sub {
    my ( undef, undef, $j ) = one('long');
    ok( length( $j->{error} ) <= 300, 'the message is at most 300 characters' ) or diag length $j->{error};
    like( $j->{error}, qr/\Ashop\.week: many words/, 'and still begins with the operation\'s words' );
    ( undef, undef, $j ) = one('ctrl');
    unlike( $j->{error}, qr/[\x00-\x1f\x7f]/, 'no control character in the message' );
    like( $j->{error}, qr/first line second/, 'a line break becomes a space' );
    unlike( $j->{fix}, qr/[\x00-\x1f\x7f]/, 'nor in the fix line' );
    like( $j->{fix}, qr/\Afix it now\z/, 'which is one clean line' );
};

subtest 'a message carrying a host path or a long token is withheld whole' => sub {
    for my $date (qw(path token)) {
        my ( $st, undef, $j, $raw ) = one($date);
        is( $st,        400,       "$date: answered 400" );
        is( $j->{kind}, 'invalid', "$date: invalid" );
        like( $j->{error}, qr/see the event log/, "$date: the generic sentence" );
        ok( !exists $j->{fix}, "$date: and no fix line, which may name the same path" );
        unlike( $raw, qr{/srv/secret|rows\.csv|AAAAAAAAAA}, "$date: nothing of it in the answer" );
    }
};

subtest 'an Odoo fault is still the generic sentence, with no fault text' => sub {
    my ( $st, undef, $j, $raw ) = one('fault');
    isnt( $j->{kind}, 'invalid', 'a fault is not a usage error' );
    unlike( $raw, qr/Traceback|abc123|x\.py/, 'the fault text is not returned' );
    ok( !exists $j->{fix}, 'no fix line' );
};

subtest 'the unit: only usage carries its text; every other kind keeps its sentence' => sub {
    for my $k (qw(fault transport refused config error)) {
        my $r;
        quiet( sub { $r = Lazysite::Odoo::fault( Odoo::Error->new( kind => $k, message => 'plain words', fix => 'plain fix' ) ) } );
        unlike( $r->{error}, qr/plain words/, "$k: its message is not returned" );
        ok( !exists $r->{fix}, "$k: nor its fix" );
    }
    my $r;
    quiet( sub { $r = Lazysite::Odoo::fault("bad date at /usr/share/perl5/X.pm line 3.\n") } );
    is( $r->{kind}, 'internal', 'a die that is not OOM\'s stays internal' );
    unlike( $r->{error}, qr/bad date|perl5/, 'with no text' );
};

subtest 'a batch call carries its own message, and the others are unharmed' => sub {
    my ( $st, $j ) = batch( 'bad', '2026-10-19', 'path', 'ctrl' );
    is( $st, 200, 'the batch is answered' );
    my @r = @{ $j->{results} // [] };
    is_deeply( [ map { $_->{status} } @r ], [ 400, 200, 400, 400 ], 'each its own status' ) or diag explain \@r;
    is( $r[0]{error}, "shop.week: date 'bad' is not a date", 'the failing call has the operation\'s message' );
    is( $r[0]{fix},   'give the date as YYYY-MM-DD',          'and its fix' );
    like( $r[2]{error}, qr/see the event log/, 'a path-bearing message is withheld in a batch too' );
    unlike( $r[3]{error}, qr/[\x00-\x1f\x7f]/, 'and a control character is cleaned' );
};

subtest 'the event log line is unchanged: the full text is there' => sub {
    my ( $log, $r ) = quiet( sub { Lazysite::Odoo::fault(
                Odoo::Error->new( kind => 'usage', message => 'cannot read /srv/secret/x.csv', fix => 'f' ),
                binding => 'week', operation => 'shop.week', mode => 'public' ) } );
    like( $log, qr{/srv/secret/x\.csv}, 'the whole message is logged' );
    like( $log, qr/kind=invalid/,       'with the kind' );
};

done_testing();
