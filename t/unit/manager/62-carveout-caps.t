#!/usr/bin/perl
# SM268 H4: the generic file surface reached two paths inside lazysite/ that
# every other plane gates on a capability.
#
# is_blocked_path denies the whole lazysite/ tree with four carve-outs, two of
# which are capability-governed elsewhere: nav.conf (manage_nav for nav-read,
# nav-save and WebDAV) and the submission store (read_submissions or
# manage_forms for form-submissions and read_form_submissions; WebDAV refuses it
# outright). The file surface asked only "is this path blocked", so a partner
# holding manage_content alone read every submission - names, addresses, message
# bodies - through `read`, and rewrote the navigation through `save`.
#
# Every security assertion below was confirmed FAILING before the fix, on both
# planes: the reads returned the submission body and the writes returned ok:1.
# The two that pass either way ('ordinary content', 'once granted') are the
# controls - without them a gate that refused everything would look like a fix.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_script repo_root);

my $SECRET = 'testsecret0123456789abcdef0123456789abcdef0123456789abcdef012345';
my $TOOL   = repo_root() . '/tools/lazysite-users.pl';

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/forms/submissions");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Test\nsite_url: http://localhost\n";
close $cf;

open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
print {$sf} "$SECRET\n";
close $sf;

# The two governed paths, with content distinctive enough that a leak is
# unmistakable in the assertion.
open my $sub, '>', "$docroot/lazysite/forms/submissions/contact.jsonl" or die $!;
print {$sub} encode_json(
    { name => 'Ada Lovelace', email => 'ada@example.org', message => 'SUBMISSION-BODY-MARKER' } ), "\n";
close $sub;

open my $nav, '>', "$docroot/lazysite/nav.conf" or die $!;
print {$nav} "Home|/\n";
close $nav;

# An ordinary content page, to show the gate is specific to the carve-outs.
open my $idx, '>', "$docroot/index.md" or die $!;
print {$idx} "---\ntitle: Home\n---\nCONTENT-BODY-MARKER\n";
close $idx;

sub cli {
    my (@args) = @_;
    my $cmd    = join ' ', map { quotemeta } $^X, $TOOL, '--docroot', $docroot, @args;
    return scalar qx($cmd 2>&1);
}

# A delegate with manage_content and nothing else. `ui` on the group is what
# makes site_grants_manager() true, i.e. this is a SECURED site - the gate is
# deliberately skipped on an unsecured/dev site, where every authenticated user
# is already the operator.
cli( 'add',       'editor',       'pw' );
cli( 'group-add', 'editor',       'site-editors' );
cli( 'group-set', 'site-editors', 'manage_content', 'on' );
cli( 'group-set', 'site-editors', 'ui',             'on' );

sub csrf { return hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $SECRET ) }

sub api_get {
    my ( $action, $path ) = @_;
    return run_script(
        'lazysite-manager-api.pl',
        env => {
            DOCUMENT_ROOT         => $docroot,
            REQUEST_METHOD        => 'GET',
            QUERY_STRING          => "action=$action&path=$path",
            HTTP_X_REMOTE_USER    => 'editor',
            HTTP_X_REMOTE_GROUPS  => 'site-editors',
            LAZYSITE_AUTH_TRUSTED => 1,
        },
    );
}

sub api_save {
    my ( $path, $content ) = @_;
    my $body = encode_json( { content => $content } );
    return run_script(
        'lazysite-manager-api.pl',
        stdin => $body,
        env   => {
            DOCUMENT_ROOT         => $docroot,
            REQUEST_METHOD        => 'POST',
            QUERY_STRING          => "action=save&path=$path",
            CONTENT_LENGTH        => length($body),
            HTTP_X_REMOTE_USER    => 'editor',
            HTTP_X_REMOTE_GROUPS  => 'site-editors',
            LAZYSITE_AUTH_TRUSTED => 1,
            HTTP_X_CSRF_TOKEN     => csrf('editor'),
        },
    );
}

subtest 'manage_content alone cannot read the submission store' => sub {
    my $out = api_get( 'read', 'lazysite/forms/submissions/contact.jsonl' );
    unlike( $out, qr/SUBMISSION-BODY-MARKER/,
        'the submitted message body did not come back' );
    like( $out, qr/read_submissions/,
        'and the refusal names the capability that would reach it' );
};

subtest 'manage_content alone cannot rewrite the navigation' => sub {
    my $out = api_save( 'lazysite/nav.conf', "Hijacked|http://evil.example/\n" );
    unlike( $out, qr/"ok"\s*:\s*1/, 'refused' );
    open my $fh, '<', "$docroot/lazysite/nav.conf" or die $!;
    my $now = do { local $/; <$fh> };
    close $fh;
    is( $now, "Home|/\n",
        'and nav.conf is byte-for-byte unchanged - a refusal that still wrote '
            . 'would be the whole defect' );
};

subtest 'ordinary content is unaffected' => sub {
    my $out = api_get( 'read', 'index.md' );
    like( $out, qr/CONTENT-BODY-MARKER/,
        'a gate that refused everything would pass the two tests above for '
            . 'the wrong reason' );
};

subtest 'the capability, once granted, reaches both' => sub {
    cli( 'group-set', 'site-editors', 'read_submissions', 'on' );
    cli( 'group-set', 'site-editors', 'manage_nav',       'on' );

    my $read = api_get( 'read', 'lazysite/forms/submissions/contact.jsonl' );
    like( $read, qr/SUBMISSION-BODY-MARKER/,
        'read_submissions reads the store' );

    my $save = api_save( 'lazysite/nav.conf', "Home|/\nAbout|/about\n" );
    like( $save, qr/"ok"\s*:\s*1/, 'manage_nav writes nav.conf' );
};

subtest 'no capability writes the submission store by hand' => sub {
    cli( 'group-set', 'site-editors', 'manage_forms', 'on' );
    my $out = api_save( 'lazysite/forms/submissions/contact.jsonl', "{}\n" );
    unlike( $out, qr/"ok"\s*:\s*1/,
        'append-only: the form handler writes it, holding every capability '
            . 'does not' );
};

# --- the same gate on the MCP plane -----------------------------------------
# Cross-plane parity is the point of the finding: a rule the control API applies
# and MCP does not is the same defect wearing a different hat. Same fixture, a
# partner credential holding mcp + manage_content and neither governed
# capability.
subtest 'an mcp partner holding manage_content is refused both paths' => sub {
    my $stub = "$docroot/users-stub.pl";
    open my $sfh, '>', $stub or die $!;
    print {$sfh} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r = eval { decode_json($in) } || {};
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1, webdav => 1 } });
STUB
    close $sfh;
    chmod 0755, $stub;

    open my $mc, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$mc} "mcp_enabled: true\n";
    close $mc;

    my $call = sub {
        my ( $tool, $args ) = @_;
        my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                params => { name => $tool, arguments => $args } } );
        my $out = run_script(
            'lazysite-mcp.pl',
            stdin => $body,
            env   => {
                DOCUMENT_ROOT       => $docroot,
                REQUEST_METHOD      => 'POST',
                CONTENT_LENGTH      => length($body),
                LAZYSITE_USERS_TOOL => $stub,
                HTTP_AUTHORIZATION  => 'Bearer partner:lzs_x',
            },
        );
        my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
        return ( defined $jb && length $jb ) ? ( eval { JSON::PP::decode_json($jb) } || {} ) : {};
    };

    my $read = $call->( 'read_file',
        { path => '/lazysite/forms/submissions/contact.jsonl' } );
    is( $read->{error}{code}, -32002, 'read_file refused' );
    unlike( encode_json($read), qr/SUBMISSION-BODY-MARKER/,
        'and no submitted content came back with the refusal' );

    my $write = $call->( 'write_file',
        { path => '/lazysite/nav.conf', content => "Hijacked|http://evil.example/\n" } );
    is( $write->{error}{code}, -32002, 'write_file refused' );

    open my $fh, '<', "$docroot/lazysite/nav.conf" or die $!;
    my $now = do { local $/; <$fh> };
    close $fh;
    unlike( $now, qr/Hijacked/, 'nav.conf was not rewritten' );
};

done_testing();
