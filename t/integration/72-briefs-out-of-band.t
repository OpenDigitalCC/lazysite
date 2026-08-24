#!/usr/bin/perl
# SM245: briefs move out of band, into a store the plugin owns. The record
# SM073 invented survives; the sidecar file does not - and with it goes
# every engine rule that existed only because a brief was a file in the
# content tree. What stays, deliberately: the extension-level DENIES.
# Deployed sites carry unmigrated sidecars, and the processor's .brief 404
# is what keeps a stray one unserved once the engine is in the static path
# (t/integration/35's own finding) - so those rules outlive the feature as
# legacy-file protection, and this file asserts that too.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/content");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $pf, '>', "$docroot/content/page.md" or die $!;
print {$pf} "---\ntitle: P\n---\nx\n";
close $pf;

sub cgi_env {
    return ( env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'author',
        LAZYSITE_AUTH_TRUSTED => 1,
        REMOTE_ADDR           => '127.0.0.1',
    );
}
sub api_get {
    my ($qs) = @_;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
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
    return eval { decode_json($out) } || { ok => 0, error => "unparseable: $out" };
}

subtest 'DISABLED MEANS DISABLED (ADR 0009, the SM469 clause)' => sub {
    my $r = api_get('action=brief-read&path=/content/page.md');
    ok( !$r->{ok}, 'a contract plugin executes nothing while disabled' );
    like( $r->{error} // '', qr/disabled|Plugin Manager/i, 'and says so' );
};

open my $ap, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$ap} "plugins:\n  - plugins/briefs.pl\n";
close $ap;

subtest 'the round trip: append, then read back, attributed and stamped' => sub {
    my $w = api_post( 'action=brief-append&path=/content/page.md',
        { entry => 'created the page for the launch' } );
    ok( $w->{ok}, 'append accepted' ) or diag explain $w;
    my $r = api_get('action=brief-read&path=/content/page.md');
    ok( $r->{ok} && $r->{exists}, 'read back' ) or diag explain $r;
    like( $r->{brief}, qr/created the page for the launch/, 'the entry' );
    like( $r->{brief}, qr/author/,                          'the author' );
    like( $r->{brief}, qr/\d{4}-\d{2}-\d{2}/,               'the date' );
    ok( -f "$docroot/lazysite/briefs/content/page.md",
        'held under lazysite/, engine-owned and never served' );
};

subtest 'MIGRATION: import, remove, idempotent, and never remove unimported' => sub {
    open my $sb, '>', "$docroot/content/old.md.brief" or die $!;
    print {$sb} "# Brief - old.md\nintent: legacy\n";
    close $sb;
    my $locked = "$docroot/content/locked.md.brief";
    open my $lb, '>', $locked or die $!;
    print {$lb} "unreachable\n";
    close $lb;
    chmod 0000, $locked;
    my $m = api_post( 'action=briefs-migrate', {} );
    ok( $m->{ok}, 'migration ran' ) or diag explain $m;
    is_deeply( $m->{imported}, ['content/old.md.brief'], 'the readable sidecar imported' );
    ok( !-e "$docroot/content/old.md.brief", 'and removed' );
    is( scalar @{ $m->{failed} }, 1, 'the unreadable one failed' );
    ok( -e $locked, 'AND WAS NOT REMOVED - never remove what was not imported' );
    chmod 0644, $locked;
    my $r = api_get('action=brief-read&path=/content/old.md');
    like( $r->{brief}, qr/legacy/, 'the imported record reads back under its file' );
    my $m2 = api_post( 'action=briefs-migrate', {} );
    is_deeply( $m2->{imported}, ['content/locked.md.brief'],
        'the second run imports only what the first could not - idempotent' );
    unlink $locked if -e $locked;

    # THE WRITE-FAILURE HALF of the hard rule, which the unreadable-sidecar
    # case cannot reach (its guard fires at the READ): a store that cannot be
    # written must leave the sidecar exactly where it was. The first sabotage
    # matrix proved this path untested - the unlink guard could be gutted and
    # nothing failed - so the case exists to make that sabotage bite.
    open my $wb, '>', "$docroot/content/unwritable.md.brief" or die $!;
    print {$wb} "must survive\n";
    close $wb;
    my $store_parent = "$docroot/lazysite/briefs/content";
    make_path($store_parent) unless -d $store_parent;
    chmod 0555, $store_parent;
    my $m3 = api_post( 'action=briefs-migrate', {} );
    chmod 0755, $store_parent;
    ok( -e "$docroot/content/unwritable.md.brief",
        'a sidecar whose import could not be WRITTEN is never removed' )
        or diag explain $m3;
    ok( ( grep { $_->{sidecar} eq 'content/unwritable.md.brief' } @{ $m3->{failed} || [] } ),
        'and is reported failed' );
    unlink "$docroot/content/unwritable.md.brief";
};

subtest 'THE DENIES OUTLIVE THE FEATURE - a stray sidecar is still unserved' => sub {
    open my $sb, '>', "$docroot/content/stray.md.brief" or die $!;
    print {$sb} "secret intent\n";
    close $sb;
    my $out = run_processor( $docroot, '/content/stray.md.brief' );
    like( $out, qr/Status:\s*404/, 'the processor still refuses .brief' )
        or diag( 'Deployed sites carry unmigrated sidecars; this 404 is what '
            . 'keeps one unserved once the engine is in the static path.' );
};

done_testing();
