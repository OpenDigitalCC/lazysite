#!/usr/bin/perl
# SM161: forms discoverability - the create_form tool scaffolds a native :::form
# (never hand-written HTML); validate_page warns on hand-authored / third-party
# forms; audit_site lists broken (hand-authored / unbound) forms.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/forms" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!; print {$cf} "site_name: X\n"; close $cf;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> }; my $r = eval { decode_json($in) } || {};
print encode_json({ ok=>1, settings=>{ mcp=>1, manage_content=>1, manage_forms=>1 } });
STUB
close $sf;
chmod 0755, $stub;

sub mcp {
    my ($payload) = @_;
    my $body = encode_json($payload);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body; close $in;
    my $resp = do { local $/; <$out> };
    close $out; waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
}
sub call { my $r = mcp( { jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => { name => $_[0], arguments => $_[1] || {} } } );
    return $r && $r->{result} ? $r->{result}{structuredContent} : undef; }

# --- create_form scaffolds a native :::form + form: NAME, not delivering yet ---
{
    my $r = call( 'create_form', { path => '/contact.md', name => 'contact' } );
    ok( $r && $r->{ok}, 'create_form ok' ) or diag encode_json( $r || {} );
    is( $r->{form}, 'contact', 'reports the form name' );
    ok( !$r->{delivers}, 'reports the form is not delivering until bound' );
    like( $r->{next}, qr/bind_form/, 'points at bind_form as the next step' );

    my $page = do { open my $fh, '<', "$d/contact.md" or die $!; local $/; <$fh> };
    like( $page, qr/^form: contact$/m, 'front matter carries form: contact' );
    like( $page, qr/^:::form$/m,       'a native :::form block was inserted' );
    like( $page, qr/^submit \| Send$/m, 'default submit line present' );
}

# --- create_form is listed as a tool (discoverable at scan time) ---------------
{
    my $r = mcp( { jsonrpc => '2.0', id => 2, method => 'tools/list' } );
    my @names = map { $_->{name} } @{ $r->{result}{tools} || [] };
    ok( ( grep { $_ eq 'create_form' } @names ), 'create_form appears in tools/list' );
}

# --- validate_page warns on hand-authored / mailto / third-party forms ---------
{
    my $hand = call( 'validate_page',
        { content => "---\ntitle: T\n---\n\n<form action=\"x\"><input name=\"e\"></form>\n" } );
    ok( ( grep { $_->{kind} eq 'hand-authored-form' } @{ $hand->{warnings} || [] } ),
        'hand-written <form> HTML is flagged' );

    my $mail = call( 'validate_page',
        { content => "---\ntitle: T\n---\n\n<form action=\"mailto:x\@y.com\"></form>\n" } );
    ok( ( grep { $_->{kind} eq 'form-mailto' } @{ $mail->{warnings} || [] } ),
        'a mailto: form action is flagged (data governance)' );

    my $third = call( 'validate_page',
        { content => "---\ntitle: T\n---\n\n<form action=\"https://formspree.io/f/abc\"></form>\n" } );
    ok( ( grep { $_->{kind} eq 'form-third-party' } @{ $third->{warnings} || [] } ),
        'a third-party form endpoint is flagged as a leak' );
}

# --- audit_site lists the unbound form scaffolded above ------------------------
{
    my $a = call( 'audit_site', {} );
    ok( $a && $a->{ok}, 'audit_site ok' );
    ok( ( grep { $_->{kind} eq 'unbound' && $_->{form} eq 'contact' } @{ $a->{broken_forms} || [] } ),
        'audit_site flags the unbound contact form' );
}

done_testing();
