#!/usr/bin/perl
# SM1148 (OOM Lab L-3): a form whose Odoo binding APPLIED but reported
# `apply-incomplete` (OOM's invariant O-4: the record WAS made, an invariant on
# it then failed) was sent to `outcome=undelivered`. The visitor was told the
# form had failed, and sent it again, making a duplicate.
#
# Now it is delivered, and the warning goes where an operator looks: the call
# record (kind apply-incomplete) and the delivery's audit line (its detail), and
# the event log. The visitor sees the same acknowledgement as any other delivery.
# A change that did NOT apply stays what it was: undelivered.
#
# Driven through the real form handler in a child process, with OOM's fake Odoo
# injected (t/lib/OdooInject.pm) and its apply's verdict set (OdooIncompleteApply).
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough);
use OdooTest   qw(oom_or_skip shop_ready bind odoo_site);

BEGIN { oom_or_skip() }

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my ( $d, undef ) = shop_ready();
my $SECRET = 'c' x 64;

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}
make_path( "$d/lazysite/forms", "$d/lazysite/auth", "$d/lazysite/logs" );
odoo_site($d);
put( "$d/lazysite/forms/.secret", $SECRET );
bind( $d, id => 'lead', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', fixed => 'basket_key=expo' );
put( "$d/lazysite/forms/expo.conf", "rate_limit: 0\ntargets:\n  - handler: lead\n" );

sub submit {
    my (%o) = @_;
    my $ts  = time - 10;
    my %f   = ( _form => 'expo', _hp => '', _ts => $ts, _tk => hmac_sha256_hex( $ts, $SECRET ),
        _page => '/expo', product => 2 );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    put( "$d/.body", $body );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        PERL5LIB       => "$root/t/lib:$root/lib",
        PERL5OPT       => '-MOdooInject -MOdooIncompleteApply',
        ODOO_FAKE_APPLY => $o{apply} // '',
        ( $o{json} ? ( HTTP_ACCEPT => 'application/json' ) : () ),
    );
    return qx($^X \Q$handler\E < \Q$d/.body\E 2>/dev/null) // '';
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

# a delivery that applied cleanly, for the baseline
my $raw = submit( json => 1 );
my ($j) = $raw =~ /(\{.*\})/s;
ok( decode_json($j)->{ok}, 'a clean apply is delivered (the baseline)' ) or diag $raw;

subtest 'applied with an invariant warning: delivered, the warning recorded' => sub {
    my $calls0 = scalar( () = slurp("$d/lazysite/odoo/calls.jsonl") =~ /\n/g );
    my $raw = submit( json => 1, apply => 'invariant' );
    my ($j) = $raw =~ /(\{.*\})/s;
    my $r = eval { decode_json($j) } || {};
    ok( $r->{ok}, 'the JSON answer is ok, not an error' ) or diag $raw;
    unlike( $raw, qr/not accepting|undelivered|could not be|failed/i, 'and says nothing of a failure' );

    my $nojs = submit( apply => 'invariant' );
    like( $nojs, qr/^Location: \S*outcome=ok(?:&|\s)/m, 'without JavaScript the redirect carries outcome=ok' ) or diag $nojs;
    unlike( $nojs, qr/outcome=undelivered/, 'never undelivered' );

    my $calls = slurp("$d/lazysite/odoo/calls.jsonl");
    my @inc   = grep { /"kind":"apply-incomplete"/ } split /\n/, $calls;
    cmp_ok( scalar @inc, '>=', 2, 'the call record keeps the warning for the operator: kind apply-incomplete' );
    like( $inc[0], qr/"outcome":"answered"/, 'as an answered call' );

    my $audit = slurp("$d/lazysite/logs/audit.log");
    like( $audit, qr/deliver \| form:expo -> lead \| [\d.]+ \| ok \| form \| [^|\n]*apply-incomplete/,
        'the delivery\'s audit line is ok, and its detail names the warning' );
};

subtest 'a change that did not apply is still not delivered' => sub {
    my $raw = submit( json => 1, apply => 'failed' );
    my ($j) = $raw =~ /(\{.*\})/s;
    my $r = eval { decode_json($j) } || {};
    ok( !$r->{ok}, 'the JSON answer is an error' ) or diag $raw;
    like( $r->{error} // '', qr/not accepting submissions/, 'the undelivered sentence' );
    like( submit( apply => 'failed' ), qr/outcome=undelivered/, 'and without JavaScript, outcome=undelivered' );
};

done_testing;
