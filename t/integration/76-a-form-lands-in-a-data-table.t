#!/usr/bin/perl
# SM569: a form handler of type `table` delivers an accepted submission as a
# row in a declared data table AND keeps the JSONL submissions store written
# alongside - the store the Submissions page, the audit trail and SM187's bulk
# delete depend on. A submission the table's types refuse leaves NO row, tells
# the visitor the submission failed, and leaves the JSONL copy marked
# _row_refused: the rejected-import shape.
#
# Driven through the real handler as a CGI subprocess, the way a visitor
# reaches it.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough);
use Lazysite::Data::Tables qw(apply_schema read_rows);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/$_") for qw(db/tables forms logs);
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/enquiries.yaml" or die $!;
print {$df} <<'YAML';
key: ref
fields:
  ref:
    type: text
  name:
    type: text
  wanted_on:
    type: date
YAML
close $df;
apply_schema( $docroot, 'enquiries' );

my $SECRET = 'b' x 64;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} $SECRET;
close $fs;
open my $hf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hf} <<'CONF';
handlers:
  - id: store
    type: table
    name: Enquiries table
    enabled: true
    table: enquiries
    fields: ref=ref,name=name,when=wanted_on
CONF
close $hf;
open my $fc, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$fc} "targets:\n  - handler: store\n";
close $fc;

my $ip = 0;

sub post {
    my ($body) = @_;
    my $bf = "$docroot/.body";
    open my $b, '>:raw', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        ( $ENV{PERL5OPT} ? ( PERL5OPT => $ENV{PERL5OPT} ) : () ),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.' . ( ++$ip ),
        HTTP_ACCEPT    => 'application/json',
    );
    my $out = qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

sub tokens {
    my $ts = time - 10;
    return ( $ts, hmac_sha256_hex( $ts, $SECRET ) );
}

sub rows { return read_rows( $docroot, 'enquiries', as => 'operator' )->{rows} || [] }

sub jsonl {
    open my $fh, '<', "$docroot/lazysite/forms/submissions/contact.jsonl" or return ();
    my @r = map { decode_json($_) } <$fh>;
    close $fh;
    return @r;
}

subtest 'an accepted submission is a row AND a stored record' => sub {
    my ( $ts, $tk ) = tokens();
    my $out = post("_form=contact&_ts=$ts&_tk=$tk&_hp=&ref=E1&name=Ada&when=2026-09-01");
    like( $out, qr/"ok":1/, 'the visitor is thanked' );

    my ($row) = grep { $_->{ref} eq 'E1' } @{ rows() };
    ok( $row, 'the row is in the table' );
    is( $row->{name},      'Ada',        'with the mapped value' );
    is( $row->{wanted_on}, '2026-09-01', 'coerced under the mapped column' );

    my ($rec) = grep { ( $_->{ref} // '' ) eq 'E1' } jsonl();
    ok( $rec, 'and the JSONL submissions store was written alongside' );
    ok( !$rec->{_row_refused}, 'not marked refused' );
};

subtest 'a submission the types refuse leaves no row, and says so' => sub {
    my ( $ts, $tk ) = tokens();
    my $out = post("_form=contact&_ts=$ts&_tk=$tk&_hp=&ref=E2&name=Bob&when=the+32nd");
    like( $out, qr/"ok":0/, 'the visitor is told the submission failed, not thanked' );

    my ($row) = grep { $_->{ref} eq 'E2' } @{ rows() };
    ok( !$row, 'no row landed' );

    my ($rec) = grep { ( $_->{ref} // '' ) eq 'E2' } jsonl();
    ok( $rec, 'the JSONL copy still records what the visitor sent' );
    ok( $rec->{_row_refused}, 'marked as a refused row - the rejected-import shape' )
        or diag explain $rec;
};

subtest 'the table it lands in is not published by landing there' => sub {
    # The capability choice the filing records: the table's rows stay governed
    # by the table's own declaration; `public` defaults CLOSED (SM519), so a
    # form cannot accidentally publish its submissions to a page binding.
    my $r = read_rows( $docroot, 'enquiries', as => 'page' );
    ok( !( $r->{ok} && @{ $r->{rows} || [] } ),
        'an anonymous page read of the submissions table gets nothing' )
        or diag explain $r;
};

done_testing();
