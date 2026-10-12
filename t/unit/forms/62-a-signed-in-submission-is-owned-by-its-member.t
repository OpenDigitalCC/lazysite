#!/usr/bin/perl
# SM1018 (SM1010 Q1, ruled 2026-10-12 as recommended): A FORM DELIVERY CARRIES
# THE VERIFIED SIGNED-IN ACCOUNT AS ITS ACTOR - context only, never a field.
#
# Before this the form handler verified the session cookie and used the answer
# as a boolean for the rate limit, then delivered with `actor => ''`. So a table
# handler declaring `row_policy: personal` wrote rows that belonged to NOBODY even
# when a member was signed in, and a notification rule could not tell who caused
# the event it was about. The SM402 line is kept for what SM402 was about: a name
# the CLIENT asserts (X-Remote-User) is never read, and a forged cookie is
# anonymous.
#
# Through the real CGI, end to end: a member's post, an anonymous post and a
# forged-cookie post land three rows; only the first is owned.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(repo_root site_tempdir env_passthrough run_cmd);
use Lazysite::Data::Tables qw(apply_schema read_rows);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
plan skip_all => "no $handler" unless -f $handler;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables", "$d/lazysite/auth" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nplugins:\n  - plugins/data.pl\n" );
spit( "$d/lazysite/db/tables/comments.yaml",
    "title: Comments\ntimestamps: true\nrow_policy: true\n"
        . "fields:\n  post:\n    type: text\n  comment:\n    type: text\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: comments\n    type: table\n    name: Comments\n"
        . "    table: comments\n    fields: post=post,comment=comment\n"
        . "    keep_copy: false\n    row_policy: personal\n" );
spit( "$d/lazysite/forms/comment.conf", "spam_dwell: off\ntargets:\n  - handler: comments\n" );
spit( "$d/lazysite/auth/.secret",       'a' x 64 );
spit( "$d/lazysite/forms/.secret",      'b' x 64 );
apply_schema( $d, 'comments' );
run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, 'add', 'zz9member', 'pw123456789-long-enough' );

sub cookie {
    my ( $user, $secret ) = @_;
    my $pay = "$user:" . time . ':';
    return "lazysite_auth=$pay:" . hmac_sha256_hex( $pay, $secret );
}

my $n = 0;

sub post {
    my ( $comment, %extra ) = @_;
    $n++;
    my $ts   = time - 10;
    my $tk   = hmac_sha256_hex( $ts, 'b' x 64 );
    my $body = "_form=comment&post=p1&comment=$comment&_hp=&_ts=$ts&_tk=$tk";
    my $bf   = "$d/.body";
    spit( $bf, $body );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => "203.0.113.$n",
        %extra,
    );
    return scalar qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
}

like( post( 'member', HTTP_COOKIE => cookie( 'zz9member', 'a' x 64 ) ), qr/"ok":1/, 'a member posts' );
like( post('anonymous'), qr/"ok":1/, 'an anonymous visitor posts' );
like( post( 'forged', HTTP_COOKIE => cookie( 'zz9member', 'f' x 64 ), HTTP_X_REMOTE_USER => 'zz9member' ),
    qr/"ok":1/, 'a forged cookie and a forged header post' );

my $rows = read_rows( $d, 'comments', as => 'operator' );
my %by   = map { $_->{comment} => $_ } @{ $rows->{rows} // [] };
is( scalar keys %by,         3,           'three rows' );
is( $by{member}{created_by}, 'zz9member', 'the member\'s row is owned by the member' )
    or diag explain \%by;
ok( !length( $by{anonymous}{created_by} // '' ), 'the anonymous row belongs to nobody' );
ok( !length( $by{forged}{created_by}    // '' ),
    'and so does the forged one - neither a bad signature nor a header names anyone' );

done_testing();
