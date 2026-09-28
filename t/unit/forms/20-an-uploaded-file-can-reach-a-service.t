#!/usr/bin/perl
# SM905 U1: the difference between a photograph being STORED and being PROCESSED.
#
# A connector is already the governed way out - an operator-vetted destination, a
# credential in the reserved tree, declared modes, a rate cap, one audit record
# per call. Every control that ought to apply to sending a customer's photograph
# to a service already applied. The only thing missing was that the payload could
# not contain the photograph: the handler passed the visible text fields and never
# read `$ctx->{files}`, though `$ctx` was used on the line above for origin, actor
# and trigger.
#
# The email handler had done it for releases, a few lines up the same file, which
# is the template this follows - same key, same shape, same default of false.
#
# AND A CEILING THAT REFUSES. A phone photograph is 3 to 8 MB. Sending part of one
# is worse than sending none, because the destination cannot tell it was short.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Handlers ();

my $docroot = site_tempdir();
$Lazysite::Handlers::DOCROOT = $docroot;

# The connector is the thing under the handler, and this test is about what the
# handler HANDS it. So the call is captured rather than performed.
my @sent;
{
    require Lazysite::Manager::Connectors;
    no warnings 'redefine', 'once';
    *Lazysite::Manager::Connectors::call = sub {
        my ( $id, $payload, %opt ) = @_;
        push @sent, { id => $id, payload => $payload, opt => {%opt} };
        return { ok => 1, call_id => 'c1' };
    };
}

sub a_photo {
    return { filename => 'photo.jpg', type => 'image/jpeg', data => ( 'x' x 2048 ) };
}

sub deliver {
    my ( $handler, @files ) = @_;
    @sent = ();
    return Lazysite::Handlers::_to_connector(
        { connector => 'crm', %{$handler} },
        { name => 'Ada', _secret => 'hidden' },
        { origin => 'form', actor => 'ada', source => 'contact', files => [@files] },
    );
}

subtest 'without asking, nothing changes' => sub {
    my $r = deliver( {}, a_photo() );
    ok( $r->{ok}, 'the call is made' );
    is( scalar @sent, 1, 'the connector was called once' ) or return;
    ok( !exists $sent[0]{payload}{files},
        'the payload carries no files when attach_files is off' )
        or diag('Default false, like the email handler. Opt in, per handler.');
    is( $sent[0]{payload}{name}, 'Ada', 'and the visible fields still go' );
    ok( !exists $sent[0]{payload}{_secret},
        'while a hidden field still does not' );
};

subtest 'ASKED FOR, THE FILE GOES' => sub {
    my $r = deliver( { attach_files => 'true' }, a_photo() );
    ok( $r->{ok}, 'the call is made' );
    is( scalar @sent, 1, 'the connector was called' ) or return;
    my $files = $sent[0]{payload}{files};
    is( ref $files, 'ARRAY', 'the payload carries a files array' )
        or diag( 'This is the whole row: a connector could always deliver, and '
            . 'never had the photograph to deliver.' );
    is( scalar @{$files}, 1, 'one file' );
    is( $files->[0]{filename}, 'photo.jpg',  'named' );
    is( $files->[0]{type},     'image/jpeg', 'typed' );
    is( $files->[0]{size},     2048,         'sized in bytes, not base64 length' );
    # Round-tripped rather than pattern-matched: what matters is that the bytes
    # the visitor uploaded are the bytes the destination can reconstruct.
    require MIME::Base64;
    is( MIME::Base64::decode_base64( $files->[0]{data} ), ( 'x' x 2048 ),
        'and carried as base64 that decodes back to the file' );
};

subtest 'over the ceiling it is REFUSED, and nothing is sent' => sub {
    my $big = { filename => 'big.jpg', type => 'image/jpeg', data => ( 'x' x ( 3 * 1024 * 1024 ) ) };
    my $r = deliver( { attach_files => 'true', attach_max_kb => 1024 }, $big );
    ok( !$r->{ok}, 'the handler refuses' );
    like( $r->{why}, qr/3072KB/, 'and says how big it was' );
    like( $r->{why}, qr/1024KB ceiling/, 'and what the ceiling is' );
    like( $r->{why}, qr/attach_max_kb/, 'and names the setting that raises it' );
    like( $r->{why}, qr/Nothing was sent/, 'and says nothing left the site' );
    is( scalar @sent, 0, 'the connector was never called' )
        or diag( 'A truncated payload is worse than a refusal: the destination '
            . 'cannot tell it was given part of a photograph.' );
};

subtest 'the ceiling has a low default, and a bad one does not disable it' => sub {
    my $big = { filename => 'big.jpg', type => 'image/jpeg', data => ( 'x' x ( 2 * 1024 * 1024 ) ) };

    my $r = deliver( { attach_files => 'true' }, $big );
    ok( !$r->{ok}, '2MB is refused with no ceiling set' );
    like( $r->{why}, qr/1024KB ceiling/, 'the default is 1024KB' )
        or diag('A phone photograph should need a deliberate decision.');

    # Asserting the REFUSAL alone was too weak, and a sabotage proved it: with the
    # validation removed, 'lots' numifies to 0 and every payload is over the
    # ceiling, so the refusal still happened and the test still passed. What has to
    # be true is that the ceiling IN FORCE is the default - which the message names.
    for my $bad ( '', 'lots', '-1', '10.5' ) {
        my $res = deliver( { attach_files => 'true', attach_max_kb => $bad }, $big );
        ok( !$res->{ok}, "a ceiling of '$bad' does not disable the ceiling" );
        like( $res->{why}, qr/1024KB ceiling/,
            "and '$bad' falls back to the default rather than being used" );
    }
};

subtest 'asked for, with no files, changes nothing' => sub {
    my $r = deliver( { attach_files => 'true' } );
    ok( $r->{ok}, 'the call is made' );
    ok( !exists $sent[0]{payload}{files},
        'and no empty files array is invented' );
};

done_testing();
