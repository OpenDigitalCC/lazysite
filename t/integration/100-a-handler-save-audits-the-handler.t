#!/usr/bin/perl
# SM888 F4: a handler action's audit entry names the HANDLER it acted on.
#
# The dispatcher's audit target defaults to the request path, and a handler POST
# carries no path - so `handler-save` and `form-targets-save` recorded '/', the
# same shape SM503 fixed for data actions and N141B-C fixed for connectors and
# group changes. Those three families each got a branch; the handler family had
# none, and it is the one that decides WHICH code a form's submissions are
# handed to.
#
# DRIVEN, not read. t/unit/manager/158 asserts the shape of these branches in
# source because it covers cases needing a session; this one runs the real CGI
# and reads the audit log it wrote, which is what SM503's own test does. A
# source check would pass on a branch that is present and never reached.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/logs");
make_path("$docroot/lazysite/forms");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'op',
        LAZYSITE_AUTH_TRUSTED => 1,
        REMOTE_ADDR           => '127.0.0.1',
    );
}

sub api_get {
    my ($qs) = @_;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}

my $TOKEN;
sub api_post {
    my ( $qs, $payload ) = @_;
    $TOKEN //= api_get('action=csrf-token')->{token};
    my $body = encode_json( $payload || {} );
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length $body,
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || {};
}

sub audit_line {
    my ($action) = @_;
    open my $fh, '<', "$docroot/lazysite/logs/audit.log" or return '';
    my @l = grep { /\b\Q$action\E\b/ } <$fh>;
    close $fh;
    return $l[-1] // '';
}

# The audit entry is written whether or not the action succeeds, and what is
# under test is the SUBJECT it records - so the assertions below do not depend
# on the save being accepted. A refusal that names the handler is still a row an
# auditor can read; a success that names '/' is not.
subtest 'handler-save names the handler' => sub {
    api_post( 'action=handler-save',
        { id => 'notify-ops', type => 'email', name => 'Notify ops', enabled => 1 } );

    my $line = audit_line('handler-save');
    ok( length $line, 'an audit entry was written' ) or return;

    like( $line, qr/\bnotify-ops\b/, 'the entry names the handler' )
        or diag("line: $line");
    unlike( $line, qr(\s/\s), q{and not the dispatcher's "/"} )
        or diag( 'A handler decides which code a form\'s submissions are handed '
            . "to. A row that cannot say which handler changed cannot answer "
            . 'the question the trail exists for.' );
};

# form-targets-save spells its subject `form`, not `id` - sent an `id` it
# refuses with "form is required" BEFORE it audits, so a test that used the
# handler spelling here would prove nothing and look like a pass waiting to
# happen. Measured against the running API, not read off the dispatcher.
subtest 'form-targets-save names the form' => sub {
    api_post( 'action=form-targets-save',
        { form => 'contact', targets => [] } );

    my $line = audit_line('form-targets-save');
    ok( length $line, 'an audit entry was written' ) or return;

    like( $line, qr/\bcontact\b/, 'the entry names the form' )
        or diag("line: $line");
    unlike( $line, qr(\s/\s), q{and not the dispatcher's "/"} );
};

done_testing();
