#!/usr/bin/perl
# SM943 ruling 1 (2026-10-09), the control API's door: "Audit is useful to see
# when a person or agent has made material behaviour changes, authentication
# events and errors. General site activity is of less interest and creates
# noise. Surfaces should be consistent."
#
# The API trail always skipped a successful read. What it also skipped was a
# REFUSED one: its audit block ran for POST only, and a token client reads over
# GET, so a read its handler refused (an unknown form, a bad version id) left no
# row - while the same refusal over MCP did. Driven against the running CGI with
# a real token:
#   - a read that succeeds writes no row;
#   - a read its handler refuses writes one `fail` row on the api origin -
#     form-submissions, the twin of read_form_submissions, among them;
#   - a write is audited as before.
# MCP's half is t/unit/mcp/28; t/lint/23 holds the two to one declaration.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(grant_caps repo_root site_tempdir);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

sub uapi {
    my ( $d, $p ) = @_;
    my $pid = open2( my $o, my $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: S\ncontrol_api_enabled: true\n";
close $cf;
uapi( $d, { action => 'add', username => 'rd', password => 'x-long-enough' } );
grant_caps( $d, 'rd', qw(api manage_content manage_nav manage_forms read_submissions) );
my $tok = uapi( $d, { action => 'token', username => 'rd' } )->{token};
ok( $tok, 'minted a token' ) or do { done_testing(); exit };

sub mapi {
    my ( $method, $query, $body ) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = $method;
    $ENV{QUERY_STRING}       = $query;
    $ENV{CONTENT_LENGTH}     = defined $body ? length($body) : 0;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "rd:$tok", '' );
    my $pid = open3( my $w, my $r, gensym, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $log = "$d/lazysite/logs/audit.log";
sub rows_since {
    my ($from) = @_;
    open my $fh, '<', $log or return ();
    my @l = <$fh>;
    close $fh;
    return @l[ $from .. $#l ];
}
sub mark { my @all = rows_since(0); return scalar @all }

# --- a read that succeeds is site activity: no row ------------------------
for my $q ( 'action=nav-read', 'action=git-history&path=/x.md', 'action=pages' ) {
    my ($a) = $q =~ /action=([a-z-]+)/;
    my $m   = mark();
    my $r   = mapi( 'GET', $q );
    ok( $r->{ok}, "$a succeeds" ) or diag encode_json($r);
    my @new = grep { /\| \Q$a\E \|/ } rows_since($m);
    is( scalar @new, 0, "a successful $a writes no audit row" ) or diag @new;
}

# --- a read its handler refuses is an error: one `fail` row, over GET ------
for my $c ( [ 'action=form-submissions&form=nope', 'form-submissions', qr/not-found/ ],
    [ 'action=git-show&path=/x.md&commit=zz', 'git-show', qr/Invalid version id/ ] )
{
    my ( $q, $a, $why ) = @$c;
    my $m = mark();
    my $r = mapi( 'GET', $q );
    ok( !$r->{ok}, "$a is refused" ) or diag encode_json($r);
    my @new = grep { /\| \Q$a\E \|/ } rows_since($m);
    is( scalar @new, 1, "the refused $a writes one audit row" );
    like( $new[0] // '', qr/\| fail \| api \|/, '...a fail row on the api origin' );
    like( $new[0] // '', $why,                  '...saying why it was refused' );
}

# --- a write is audited, as it always was ---------------------------------
{
    my $m = mark();
    my $r = mapi( 'POST', 'action=nav-save',
        encode_json( { items => [ { label => 'Home', url => '/' } ] } ) );
    ok( $r->{ok}, 'nav-save succeeds' ) or diag encode_json($r);
    my @new = grep { /\| nav-save \|/ } rows_since($m);
    is( scalar @new, 1, 'a write writes its audit row' );
    like( $new[0] // '', qr/\| ok \| api\b/, '...an ok row on the api origin' );
}

done_testing();
