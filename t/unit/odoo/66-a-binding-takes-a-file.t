#!/usr/bin/perl
# SM1162 (OOM Lab, expense app, L-9): "A binding takes no file ... A receipt photo
# can therefore reach Odoo only by the page compressing it to about 35 KB of JPEG
# and sending it as 48 text parameters." OOM 0.34's file parameters
# ({ name, bytes, mimetype? }) are what a binding now feeds, from a
# multipart/form-data request to the Odoo endpoint.
#
# Held here, on OOM's fake Odoo and with the endpoint driven as a CGI:
#   * a binding that maps a request file field to a file parameter takes the file;
#     the operation sees the right bytes (their sha256), name and a type read from
#     the BYTES, with the plain values of the JSON part beside it;
#   * saving refuses a binding that maps a file without `file_max_kb`, one above
#     the operation's max_bytes or the endpoint's ceiling, and a file mapped into a
#     parameter that is not a file;
#   * a body over the binding's cap is refused at its declared CONTENT_LENGTH with
#     413 too-large, before one byte of it is read;
#   * the type is decided from the bytes, and `file_types` and the client's claim
#     are held to it;
#   * nothing of the bytes is in any answer, the call record, the audit or the log
#     (a marker in the bytes is searched for in the whole site), and no file is
#     left in the site by a success, a refusal or an operation that dies;
#   * every check that was there still runs (tokens, mode, sign-in first); a
#     multipart batch is refused by name.
use strict;
use warnings;
use Test::More;
use File::Find ();
use JSON::PP qw(decode_json encode_json);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();
use Lazysite::Handlers      ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

my $MARK = 'MARKER-5d1e9b-do-not-log';
my $JPEG = "\xFF\xD8\xFF\xE0" . $MARK . ( 'j' x 600 );
my $PNG  = "\x89PNG\r\n\x1a\n" . $MARK . ( 'p' x 600 );
my $PDF  = "%PDF-1.4\n" . $MARK . ( 'f' x 600 );
my $TXT  = "plain text $MARK\n";

sub save {
    my (%h) = @_;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    return Lazysite::Handlers::action_handler_save( { type => 'odoo', name => $h{id}, %h }, unconstrained => 1 );
}

# --- saving ------------------------------------------------------------------
subtest 'a binding that maps a file says how large it may be, and the cap holds' => sub {
    my %base = ( operation => 'shop.photo', modes => 'public' );
    my $r = save( id => 'nocap', %base, file_params => 'photo=photo' );
    ok( !$r->{ok}, 'a file mapped with no file_max_kb is refused' );
    like( $r->{error} // '', qr/file_max_kb is required/, 'saying it is required' );

    $r = save( id => 'big', %base, file_params => 'photo=photo', file_max_kb => 6 );
    ok( !$r->{ok}, 'a cap above the operation\'s max_bytes (5000) is refused' );
    like( $r->{error} // '', qr/file_max_kb.*max_bytes|max_bytes.*file_max_kb/s, 'naming both' );

    $r = save( id => 'words', %base, file_params => 'photo=photo', file_max_kb => 'lots' );
    ok( !$r->{ok}, 'a cap that is not a whole number is refused' );

    $r = save( id => 'ceil', operation => 'core.attach', modes => 'public', file_params => 'f=file',
        fixed => 'model=res.partner,record=1', file_max_kb => 999999 );
    ok( !$r->{ok}, 'a cap above the endpoint\'s ceiling is refused, whatever the operation allows' );
    like( $r->{error} // '', qr/ceiling/, 'naming the ceiling' );

    $r = save( id => 'plainp', %base, file_params => 'x=sink', file_max_kb => 4 );
    ok( !$r->{ok}, 'a file mapped into a parameter that is not a file is refused' );
    like( $r->{error} // '', qr/'sink'.*not a file/, 'naming the parameter' );

    $r = save( id => 'nosuch', %base, file_params => 'x=nothere', file_max_kb => 4 );
    ok( !$r->{ok}, 'and into one the operation does not declare' );

    $r = save( id => 'twice', %base, file_params => 'photo=photo', params => 'p=photo', file_max_kb => 4 );
    ok( !$r->{ok}, 'a parameter with a file source and another source is refused' );
    like( $r->{error} // '', qr/each parameter has one source/, 'as every parameter is' );

    $r = save( id => 'asplain', %base, params => 'photo=photo' );
    ok( !$r->{ok}, 'a plain request value cannot feed a file parameter' );

    $r = save( id => 'badtypes', %base, file_params => 'photo=photo', file_max_kb => 4, file_types => 'image/jpeg,*/*' );
    ok( !$r->{ok}, 'file_types holds type/subtype names, never a wildcard' );

    $r = save( id => 'okmany', %base, file_params => 'photo=photo,shots=shots', file_max_kb => 4,
        file_types => 'image/jpeg, image/png' );
    ok( $r->{ok}, 'a file and a list of files, with a cap and types, is accepted' ) or diag explain $r;

    $r = save( id => 'setfield', operation => 'core.set', modes => 'authenticated', callers => 'staff',
        file_params => 'logo=set.image_1920', params => 'id=id', fixed => 'model=res.partner', file_max_kb => 100 );
    ok( $r->{ok}, 'a file may feed a set.<field> (a binary field), OOM checks the field at plan' )
        or diag explain $r;

    $r = save( id => 'post', operation => 'discuss.post', modes => 'authenticated', callers => 'staff',
        file_params => 'pics=files', params => 'channel=channel,body=body', file_max_kb => 200 );
    ok( $r->{ok}, 'discuss.post\'s list of files is accepted' ) or diag explain $r;
};

bind( $d, id => 'snap', operation => 'shop.photo', modes => 'public', params => 'sink=sink',
    file_params => 'photo=photo,shots=shots', file_max_kb => 4, file_types => 'image/jpeg,image/png' );
bind( $d, id => 'snap_any', operation => 'shop.photo', modes => 'public', params => 'sink=sink',
    file_params => 'photo=photo', file_max_kb => 4 );
bind( $d, id => 'keep', operation => 'shop.photo_post', modes => 'public', apply => 'immediate',
    file_params => 'photo=photo', file_max_kb => 4 );
bind( $d, id => 'fall', operation => 'shop.photo_die', modes => 'public', file_params => 'photo=photo', file_max_kb => 4 );
bind( $d, id => 'plain', operation => 'shop.photo', modes => 'public', params => 'sink=sink' );
bind( $d, id => 'staff', operation => 'shop.photo', modes => 'authenticated', callers => 'staff',
    file_params => 'photo=photo', file_max_kb => 4 );
bind( $d, id => 'mine', operation => 'shop.photo', credential => 'session', modes => 'authenticated',
    file_params => 'photo=photo', file_max_kb => 4 );

# --- the endpoint ---------------------------------------------------------------
require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

# parts: [ name, filename|undef, claimed type|undef, bytes ]
sub multipart {
    my (@parts) = @_;
    my $b    = '----lzs' . substr( sha256_hex( join '', map { $_->[3] } @parts ), 0, 24 );
    my $body = '';
    for my $p (@parts) {
        my ( $name, $file, $type, $bytes ) = @$p;
        $body .= "--$b\r\nContent-Disposition: form-data; name=\"$name\""
            . ( defined $file ? "; filename=\"$file\"" : '' ) . "\r\n"
            . ( defined $type ? "Content-Type: $type\r\n" : '' ) . "\r\n$bytes\r\n";
    }
    $body .= "--$b--\r\n";
    return ( $body, "multipart/form-data; boundary=$b" );
}

my @LOG;    # everything the engine wrote to its log, every request

# One request. Returns ( status, cookies, json, raw, stdin_position ).
sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out = '';
    my $in  = defined $body ? ( ref $body ? encode_json($body) : $body ) : '';
    my $pos;
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $in,
            HTTP_HOST => 'localhost', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$in or die $!;
        binmode STDIN;
        my ($log) = quiet( sub { main::main() } );
        push @LOG, $log;
        $pos = tell STDIN;
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out, $pos );
}
sub cv { my ( $c, $n ) = @_; for (@$c) { return $1 if /\A\Q$n\E=([^;]*)/ } return undef }

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};

# A binding call with files: the JSON part carries the tokens and the plain
# values, the file parts the bytes; the binding is named in the query so its cap
# is known before the body is read.
sub upload {
    my ( $binding, $json, $files, %o ) = @_;
    my ( $body, $type ) = multipart(
        [ 'json', undef, 'application/json', encode_json( { visitor_token => $VT, %{ $json // {} } } ) ],
        map { [ $_->[0], $_->[1], $_->[2], $_->[3] ] } @{ $files // [] } );
    return request( 'POST', 'binding=' . ( $binding // '' ), $body,
        CONTENT_TYPE => $type, HTTP_COOKIE => $VC,
        ( defined $o{length} ? ( CONTENT_LENGTH => $o{length} ) : () ), %{ $o{env} // {} } );
}

sub tree {
    my %f;
    File::Find::find( { no_chdir => 1, wanted => sub { $f{$File::Find::name} = -s $_ if -f $_ } }, dirname_of($d) );
    return \%f;
}
sub dirname_of { my $x = shift; $x =~ s{/[^/]+\z}{}; return $x }    # the site, beside its docroot

sub holds_marker {
    my @hit;
    File::Find::find( { no_chdir => 1, wanted => sub {
                return unless -f $_;
                open my $fh, '<:raw', $_ or return;
                local $/;
                my $t = <$fh>;
                push @hit, $_ if index( $t, $MARK ) >= 0;
    } }, dirname_of($d) );
    return @hit;
}

my @RAW;    # every answer, to be searched for the marker at the end

subtest 'a file under the cap reaches the operation with its bytes, name and a type read from them' => sub {
    my ( $st, undef, $j, $raw ) = upload( 'snap', { params => { sink => 'hello' } },
        [ [ 'photo', 'receipt.jpg', 'image/jpeg', $JPEG ] ] );
    push @RAW, $raw;
    is( $st, 200, 'answered' ) or diag $raw;
    ok( $j->{ok}, 'ok' ) or diag explain $j;
    my $row = $j->{report}{rows}[0];
    is( $row->{seen}, sha256_hex($JPEG), 'the operation saw the bytes: the sha256 matches' );
    is( $row->{bytes},    length $JPEG,   'the size' );
    is( $row->{name},     'receipt.jpg',  'the name' );
    is( $row->{mimetype}, 'image/jpeg',   'the type, read from the bytes' );
    is( $j->{report}{sink}, 'hello', 'a plain value of the JSON part arrives beside it' );

    ( $st, undef, $j, $raw ) = upload( 'snap', {},
        [ [ 'photo', 'a.png', 'image/png', $PNG ], [ 'shots', 's1.jpg', 'image/jpeg', $JPEG ], [ 'shots', 's2.png', undef, $PNG ] ] );
    push @RAW, $raw;
    is( $st, 200, 'a file and a list of files' ) or diag $raw;
    is_deeply( [ map { $_->{name} } @{ $j->{report}{rows} } ], [qw(a.png s1.jpg s2.png)], 'all three, in order' );
    is_deeply( [ map { $_->{seen} } @{ $j->{report}{rows} } ],
        [ map { sha256_hex($_) } $PNG, $JPEG, $PNG ], 'each with its own bytes' );
};

subtest 'the type is decided from the bytes, not from the browser' => sub {
    my ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'receipt.jpg', 'image/jpeg', $PDF ] ] );
    push @RAW, $raw;
    is( $st, 400, 'PDF bytes under a .jpg name and a jpeg claim, where only jpeg and png are taken: refused' );
    is( $j->{kind}, 'invalid', 'invalid' );
    like( $j->{error} // '', qr/application\/pdf.*image\/jpeg, image\/png|not.*accepted/s, 'saying what the bytes are and what is taken' );
    unlike( $raw, qr/\Q$MARK\E/, 'and not the bytes' );

    ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'x.png', 'image/png', $JPEG ] ] );
    is( $st, 400, 'JPEG bytes claimed as PNG: refused, though both are taken' );
    like( $j->{error} // '', qr/claims image\/png.*image\/jpeg/s, 'the mismatch is named' );

    ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'n.txt', 'image/jpeg', $TXT ] ] );
    is( $st, 400, 'text claimed as an image: refused' );

    ( $st, undef, $j ) = upload( 'snap_any', {}, [ [ 'photo', 'n.txt', 'text/html', $TXT ] ] );
    is( $st, 200, 'a binding with no file_types takes it' );
    is( $j->{report}{rows}[0]{mimetype}, 'application/octet-stream', 'typed from its bytes, the claim ignored' );

    ( $st, undef, $j ) = upload( 'snap', {},
        [ [ 'photo', 'a.png', undef, $PNG ], [ 'shots', 'ok.jpg', undef, $JPEG ], [ 'shots', 'bad.pdf', undef, $PDF ] ] );
    is( $st, 400, 'in a list, one file of the wrong type refuses the call' );
    like( $j->{error} // '', qr/'shots'.*(?:2|second|\[1\])/, 'naming the list and which file' );
};

subtest 'a list holds no more than the operation allows' => sub {
    my @four = map { [ 'shots', "s$_.jpg", undef, $JPEG ] } 1 .. 4;
    my ( $st, undef, $j ) = upload( 'snap', {}, \@four );
    is( $st, 400, 'four files where three are allowed' );
    like( $j->{error} // '', qr/at most 3/, 'the cap is named' );
    ( $st, undef, $j ) = upload( 'snap', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ], [ 'photo', 'b.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'two files for a parameter that takes one' );
};

subtest 'over the cap is refused at CONTENT_LENGTH, before the body is read' => sub {
    my $cap = 4 * 1024;
    my ( $st, undef, $j, $raw, $pos ) = upload( 'snap', {}, [ [ 'photo', 'huge.jpg', undef, 'x' ] ],
        length => 10 * 1024 * 1024 );
    is( $st, 413, 'status 413' ) or diag $raw;
    is( $j->{kind}, 'too-large', 'kind too-large' );
    like( $j->{error} // '', qr/\b4 KB\b|4096|\b4 kb\b/i, 'naming the cap' );
    is( $pos, 0, 'not one byte of the body was read' );

    # the ceiling, whatever the binding says: a request larger than any binding may take
    ( $st, undef, $j, $raw, $pos ) = upload( 'snap', {}, [ [ 'photo', 'huge.jpg', undef, 'x' ] ], length => 900 * 1024 * 1024 );
    is( $st, 413, 'far over the endpoint\'s ceiling: 413' );
    is( $pos, 0, 'and unread' );

    # a body inside the allowance whose file is over the cap: refused when the file is seen
    my $big = "\xFF\xD8\xFF" . ( 'b' x ( $cap + 10 ) );
    ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'big.jpg', undef, $big ] ] );
    is( $st, 413, 'a file over the cap inside an allowed body: 413' );
    is( $j->{kind}, 'too-large', 'too-large' );
    my $at = "\xFF\xD8\xFF" . ( 'b' x ( $cap - 3 ) );
    ( $st, undef, $j ) = upload( 'snap', {}, [ [ 'photo', 'at.jpg', undef, $at ] ] );
    is( $st, 200, 'a file exactly at the cap passes' ) or diag explain $j;
};

subtest 'a request to a binding that takes no file, or none named, is refused by name' => sub {
    my ( $st, undef, $j ) = upload( 'plain', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'a binding that maps no file' );
    like( $j->{error} // '', qr/takes no file/, 'says so' );
    ( $st, undef, $j ) = upload( 'snap', {}, [ [ 'other', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'a file field the binding does not map' );
    like( $j->{error} // '', qr/'other'/, 'is named' );
    ( $st, undef, $j ) = upload( undef, {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'no binding in the query' );
    like( $j->{error} // '', qr/\?binding=/, 'says where to name it' );
    ( $st, undef, $j ) = upload( 'nothere', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 404, 'an unknown binding' );
    ( $st, undef, $j ) = upload( 'snap', { binding => 'plain' }, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'a JSON part naming another binding than the query' );
    ( $st, undef, $j ) = upload( 'snap', {}, [ [ 'photo', '../../etc/passwd', undef, $JPEG ] ] );
    is( $st, 200, 'a path in a file name is cut to its last part' ) or diag explain $j;
    is( $j->{report}{rows}[0]{name}, 'passwd', 'by the endpoint' );
    ( $st, undef, $j ) = upload( 'snap', {}, [ [ 'photo', undef, undef, $JPEG ] ] );
    is( $st, 400, 'a part with no file name is not a file' );
    ( $st, undef, $j ) = upload( 'snap', { params => { sink => 'a' } }, [ [ 'photo', 'z.jpg', undef, '' ] ] );
    is( $st, 400, 'an empty file' );
};

subtest 'a batch carries no files' => sub {
    my ( $st, undef, $j ) = upload( 'snap', { calls => [ { binding => 'snap' } ] }, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'a multipart request with calls is refused' );
    like( $j->{error} // '', qr/batch.*no files|no files.*batch/i, 'by name' );
    ( $st, undef, $j ) = upload( 'snap', { plan => 'a' x 32, confirm => JSON::PP::true }, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 400, 'nor a confirm' );
    ( $st, undef, $j ) = upload( 'snap', { signin => JSON::PP::true, login => 'a', password => 'b' }, [] );
    is( $st, 400, 'nor a sign-in' );
};

subtest 'every check that was there still runs' => sub {
    my $c0 = scalar @{ $fake->calls };
    my ( $body, $type ) = multipart( [ 'json', undef, undef, encode_json( { visitor_token => 'bad' } ) ], [ 'photo', 'a.jpg', undef, $JPEG ] );
    my ( $st, undef, $j );
    ( $st, undef, $j ) = request( 'POST', 'binding=snap', $body, CONTENT_TYPE => $type, HTTP_COOKIE => $VC );
    is( $st, 403, 'a bad visitor token: 403' );
    is( $j->{kind}, 'csrf', 'csrf' );
    ( $body, $type ) = multipart( [ 'json', undef, undef, '{}' ], [ 'photo', 'a.jpg', undef, $JPEG ] );
    ( $st, undef, $j ) = request( 'POST', 'binding=snap', $body, CONTENT_TYPE => $type, HTTP_COOKIE => $VC );
    is( $st, 403, 'no token: 403' );

    ( $st, undef, $j ) = upload( 'staff', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    isnt( $st, 200, 'an authenticated-only binding is not run by a visitor' );
    is( $j->{kind}, 'mode', 'refused as mode' );

    ( $st, undef, $j ) = upload( 'mine', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    is( $st, 401, 'a session binding with no session asks to sign in first (SM1168)' );
    is( $j->{kind}, 'signin-required', 'by name' );
    is( scalar @{ $fake->calls }, $c0, 'Odoo was asked for none of them' );
};

subtest 'a write takes a file, and the operation made what the bytes say' => sub {
    my $before = scalar @{ $fake->all_ids('x.basket') };
    my ( $st, undef, $j, $raw ) = upload( 'keep', {}, [ [ 'photo', 'till.jpg', 'image/jpeg', $JPEG ] ] );
    push @RAW, $raw;
    is( $st, 200, 'applied' ) or diag $raw;
    ok( $j->{applied}, 'applied' ) or diag explain $j;
    my $ids = $fake->all_ids('x.basket');
    is( scalar @$ids, $before + 1, 'one record' );
    my $rec = $fake->record( 'x.basket', $ids->[-1] );
    is( $rec->{basket_key}, 'till.jpg|' . sha256_hex($JPEG), 'the record names the file and the sha256 of the bytes the operation saw' );
    is( $rec->{qty}, length $JPEG, 'and the size' );
};

subtest 'an operation that dies, and a refusal, leave nothing behind' => sub {
    my $before = tree();
    my ( $st, undef, $j, $raw ) = upload( 'fall', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    push @RAW, $raw;
    isnt( $st, 200, 'the operation died: not a success' );
    ok( !$j->{ok}, 'not ok' );
    unlike( $raw, qr/fell over|\Q$MARK\E/, 'and the answer says neither its message nor the bytes' );
    ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'x.jpg', undef, $PDF ] ] );
    push @RAW, $raw;
    ( $st, undef, $j, $raw ) = upload( 'snap', {}, [ [ 'photo', 'a.jpg', undef, $JPEG ] ] );
    push @RAW, $raw;
    my $after = tree();
    my @new = grep { !exists $before->{$_} } sort keys %$after;
    my @temp = grep { m{(?:\.tmp|\.part|upload|multipart|\.pruning|/tmp)}i } @new;
    is_deeply( \@temp, [], 'no temporary file is left by a success, a refusal or a failure' ) or diag "@temp";
    is_deeply( [ grep { m{/(?:plans|runs)/[^/]+/blobs/}  && !m{/odoo/} } @new ], [], 'and no blob outside the plan store' );
};

subtest 'nothing of the bytes is in any answer, record, audit or log' => sub {
    my $any = grep { index( $_, $MARK ) >= 0 } @RAW;
    is( $any, 0, 'no answer carried the marker' );
    my @hit = holds_marker();
    @hit = grep { !m{/odoo/(?:plans|runs)/} } @hit;    # OOM's own run store: see below
    is_deeply( \@hit, [], 'no file of the site holds the marker (call record, audit, logs, docroot)' ) or diag "@hit";
    my $log = join '', @LOG;
    unlike( $log, qr/\Q$MARK\E/, 'the log holds no bytes' );
    my ($line) = grep { /a file was given to an operation/ && /name=receipt\.jpg/ } split /\n/, $log;
    ok( $line, 'the log has a line for the file' );
    like( $line // '', qr/\bbytes=@{[ length $JPEG ]}\b/, 'with its size' );
    like( $line // '', qr/\bsha256=@{[ sha256_hex($JPEG) ]}\b/, 'its sha256' );
    like( $line // '', qr{\bmimetype=image/jpeg\b}, 'and its type' );
    my $calls = Lazysite::Odoo::read_calls() || [];
    ok( scalar @$calls, 'the calls were recorded' );
    unlike( encode_json($calls), qr/\Q$MARK\E|receipt\.jpg.*bytes/, 'the record holds no bytes' );
    is( ( grep { $_->{binding} eq 'snap' } @$calls ) ? 1 : 0, 1, 'and names the binding' );
};

done_testing();
