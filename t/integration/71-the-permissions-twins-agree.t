#!/usr/bin/perl
# SM431: a token that can CREATE gated content can inspect and set the rule
# governing it, on the same surface. MCP's get/set_permissions sat under
# manage_content while the API's acl actions needed webdav - so the
# field-test account met refusals on one door and working tools on the
# other, the SM491 shape again. The gate is now webdav OR manage_content;
# per-file ownership rules are untouched.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/content");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\ncontrol_api_enabled: true\n";
close $cf;
open my $pf, '>', "$docroot/content/note.md" or die $!;
print {$pf} "---\ntitle: N\n---\nx\n";
close $pf;
# The API refuses every token on a site whose REAL auth files grant no
# manager (the unsecured-site guard reads groups-settings.json itself; the
# stub only answers verify-credential for the Bearer). Bootstrap through
# the real writer, as the tools tests do.
qx($^X \Q$root/tools/lazysite-users.pl\E --docroot \Q$docroot\E setup-manager pw123456789 2>/dev/null);

sub stub_with {
    my (%caps) = @_;
    my $stub = "$docroot/users-stub.pl";
    # PERL source, not JSON: the first draft interpolated encode_json output
    # ("api":1) into the stub's source, which does not compile, and the stub
    # died silently at every call - read back as Invalid credentials.
    my $pairs = join ', ', map { "$_ => $caps{$_}" } sort keys %caps;
    open my $sf, '>', $stub or die $!;
    print {$sf} "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { $pairs } });\n";
    close $sf;
    chmod 0755, $stub;
    return $stub;
}

sub api {
    my ( $stub, $qs, $payload ) = @_;
    my $body = encode_json( $payload || {} );
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $docroot,
        LAZYSITE_USERS_TOOL => $stub,
        # The API's token door is HTTP BASIC carrying user:lzs_secret - the
        # Bearer shape belongs to the MCP. Cross-wiring the two doors'
        # conventions cost this rig a round of 'Authentication required'.
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( 'tester:lzs_tok', '' ),
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => $qs,
        CONTENT_TYPE       => 'application/json',
        CONTENT_LENGTH     => length $body,
        REMOTE_ADDR        => '127.0.0.1',
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

subtest 'MANAGE_CONTENT ALONE REACHES THE PERMISSIONS DOOR NOW' => sub {
    my $stub = stub_with( api => 1, manage_content => 1 );
    # Path rides the QUERY STRING; the lists ride the body - SM306's split,
    # which this rig first got backwards and was refused for, correctly.
    my $set = api( $stub, 'action=acl-set&path=/content/note.md',
        { read => 'tester', write => 'tester' } );
    ok( $set->{ok}, 'acl-set allowed for the grant that created the content' )
        or diag explain $set;
    my $get = api( $stub, 'action=acl-get&path=/content/note.md', {} );
    ok( $get->{ok}, 'and acl-get reads it back' ) or diag explain $get;
    is( $get->{acl}{owner}, 'tester', 'the rule the token just wrote, visible to it' );
};

subtest 'webdav alone is REFUSED - SM570 closed the SM074 door' => sub {
    my $stub = stub_with( api => 1, webdav => 1 );
    my $get  = api( $stub, 'action=acl-get&path=/content/note.md', {} );
    ok( !$get->{ok} && ( $get->{error} // '' ) =~ /capability/i,
        'a webdav-only grant cannot write content, so it cannot govern it (SM570)' ) or diag explain $get;
};

subtest 'neither capability is still a refusal' => sub {
    my $stub = stub_with( api => 1, manage_nav => 1 );
    my $get  = api( $stub, 'action=acl-get&path=/content/note.md', {} );
    ok( !$get->{ok}, 'refused' );
    like( $get->{error} // '', qr/Insufficient capability|describe-capabilities/i,
        'with the standing refusal shape, which points at describe-capabilities' )
        or diag explain $get;
};

done_testing();
