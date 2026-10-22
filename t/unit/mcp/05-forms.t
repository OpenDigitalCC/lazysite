#!/usr/bin/perl
# SM161: forms discoverability - the create_form tool scaffolds a native :::form
# (never hand-written HTML); validate_page warns on hand-authored / third-party
# forms; audit_site lists broken (hand-authored / unbound) forms.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_child);

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/forms" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!; print {$cf} "site_name: X\nmcp_enabled: true\n"; close $cf;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> }; my $r = eval { decode_json($in) } || {};
print encode_json({ ok=>1, settings=>{ mcp=>1, manage_content=>1, manage_forms=>1, read_submissions=>1 } });
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
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
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

# --- SM214: form_list (MCP) discovers forms + submission counts, PII-free -------
{
    # a file handler + a form referencing it + a 2-row store
    open my $hc, '>', "$d/lazysite/forms/handlers.conf" or die $!;
    print {$hc} "handlers:\n  - id: local-storage\n    type: file\n    name: Local\n";
    close $hc;
    open my $fc, '>', "$d/lazysite/forms/feedback.conf" or die $!;
    print {$fc} "targets:\n  - handler: local-storage\n";
    close $fc;
    make_path("$d/lazysite/forms/submissions");
    open my $st, '>', "$d/lazysite/forms/submissions/feedback.jsonl" or die $!;
    print {$st} qq({"name":"alice"}\n{"name":"bob"}\n);
    close $st;

    my $r = mcp( { jsonrpc => '2.0', id => 3, method => 'tools/list' } );
    my @names = map { $_->{name} } @{ $r->{result}{tools} || [] };
    ok( ( grep { $_ eq 'form_list' } @names ), 'form_list appears in tools/list' );

    my $fl = call( 'form_list', {} );
    ok( $fl && $fl->{ok}, 'form_list ok' ) or diag encode_json( $fl || {} );
    my ($fb) = grep { $_->{name} eq 'feedback' } @{ $fl->{forms} || [] };
    ok( $fb, 'the feedback form is listed' );
    is_deeply( $fb->{handler_types}, ['file'], 'handler type resolved (file)' );
    ok( $fb->{has_store}, 'a submissions store is detected' );
    is( $fb->{row_count}, 2, 'row count is correct (a count, not content)' );
    ok( !exists $fb->{rows}, 'under its one name - the rows alias is gone (N13-30)' );
    unlike( encode_json($fl), qr/alice|bob/, 'form_list carries no submission content (PII-free)' );
}

# --- SM976 Q15f: create_form and audit_site read the form the page renders -----
# ("One reading, processor's" - Manager::Common::page_form, t/lint/219.)
{
    my $put = sub {
        open my $fh, '>', "$d/$_[0]" or die $!;
        print {$fh} $_[1];
        close $fh;
    };
    $put->( 'nextline.md', "---\ntitle: N\nform:\n  other\n---\n\nbody\n" );
    my $r = call( 'create_form', { path => '/nextline.md', name => 'mine' } );
    ok( !$r->{ok}, 'create_form: a page whose form is on the next line already has one' );
    like( $r->{error} // '', qr/different form \('other'\)/, '...named as the page renders it' );

    $put->( 'empty.md', "---\ntitle: E\nform: mine\nform: ''\n---\n\nbody\n" );
    $r = call( 'create_form', { path => '/empty.md', name => 'mine' } );
    ok( !$r->{ok}, 'create_form: a page whose last form: line binds nothing is not reported bound' );
    like( $r->{error} // '', qr/binds no form as the page renders/, '...and says why' );

    $put->( 'twolines.md', "---\ntitle: T\nform: decoy\nform: mine\n---\n\nbody\n" );
    $r = call( 'create_form', { path => '/twolines.md', name => 'mine' } );
    ok( $r && $r->{ok}, 'create_form: a page rendering this form (the last line) takes it' )
        or diag encode_json( $r || {} );

    $put->( 'audited.md', "---\ntitle: A\nform:\n  leadsq\n---\n\n:::form\nn | N\n:::\n" );
    my $au = call( 'audit_site', {} );
    my ($row) = grep { ( $_->{page} // '' ) =~ /audited/ } @{ $au->{broken_forms} || [] };
    is( $row && $row->{kind}, 'unbound', 'audit_site: the form on the next line is the page\'s' );
    is( $row && $row->{form}, 'leadsq', '...named as it renders' );
}

done_testing();
