#!/usr/bin/perl
# SM503: a data action's audit entry names the TABLE it acted on. The
# operator read their own trail and every data-* row targeted "/" - the
# dispatcher's path default, which no data action uses.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/db/tables");
make_path("$docroot/lazysite/logs");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/events.yaml" or die $!;
print {$df}
    "title: Events\nkey: slug\nfields:\n  slug:\n    type: text\n  name:\n    type: text\n";
close $df;

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

subtest 'query-carried: data-migrate audits the table' => sub {
    my $r = api_post( 'action=data-migrate&table=events', {} );
    ok( $r->{ok}, 'migrated' ) or diag explain $r;
    my $line = audit_line('data-migrate');
    like( $line, qr/\bevents\b/, 'the entry names the table' )
        or diag("line: $line");
    unlike( $line, qr/\s\/\s/, 'and not the dispatcher\'s "/"' );
};

subtest 'body-carried: data-row-save audits the table' => sub {
    my $r = api_post( 'action=data-row-save',
        { table => 'events', row => { slug => 'x' } } );
    ok( $r->{ok}, 'row saved' ) or diag explain $r;
    my $line = audit_line('data-row-save');
    like( $line, qr/\bevents\b/, 'the entry names the table' )
        or diag("line: $line");
};

subtest 'SM505: a row ADD names the row it created' => sub {
    my $r = api_post( 'action=data-row-save',
        { table => 'events', row => { slug => 'y' } } );
    ok( $r->{ok}, 'row added' ) or diag explain $r;
    my $line = audit_line('data-row-save');
    like( $line, qr/row=y\b/, 'detail names the assigned key' )
        or diag("line: $line");
};

subtest 'SM505: a body-only row EDIT names table and row' => sub {
    my $r = api_post( 'action=data-row-save',
        { table => 'events', key => 'y', row => { name => 'z' } } );
    ok( $r->{ok}, 'row updated' ) or diag explain $r;
    my $line = audit_line('data-row-save');
    like( $line, qr/\bevents\b/, 'body-only table still lands' );
    like( $line, qr/row=y\b/,    'and the row is named' );
};

subtest 'SM505: a body-only row DELETE names table and row' => sub {
    my $r = api_post( 'action=data-row-delete',
        { table => 'events', key => 'y' } );
    ok( $r->{ok}, 'row deleted' ) or diag explain $r;
    my $line = audit_line('data-row-delete');
    like( $line, qr/\bevents\b/, 'the entry names the table' );
    like( $line, qr/row=y\b/,    'and the row it removed' );
};

subtest 'a non-data action keeps its path target (the control)' => sub {
    my $r = api_post( 'action=save&path=/note.md',
        { content => "---\ntitle: N\n---\nx\n", mtime => undef } );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    # audit_line('save') would match inside 'data-row-save' (a hyphen is a
    # word boundary), so the control asserts the path directly: a path-target
    # action still records its path.
    open my $ah, '<', "$docroot/lazysite/logs/audit.log" or die $!;
    my @lines = <$ah>;
    close $ah;
    ok( ( grep { /note\.md/ } @lines ), 'path-target actions unchanged' )
        or diag( join '', @lines[ -4 .. -1 ] );
};

done_testing();
