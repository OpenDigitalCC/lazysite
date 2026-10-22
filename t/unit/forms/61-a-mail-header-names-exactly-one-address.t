#!/usr/bin/perl
# SM1017 (SM1010 F2): an address the site writes into a mail header is EXACTLY
# ONE ADDRESS - no , ; < > and no CR or LF - and anything else is refused.
#
# Three places hold the rule, and each is asked here:
#   * the definition, Lazysite::Mail::one_address;
#   * the one writer of the header, plugins/form-smtp.pl, which every message
#     passes through - it used to strip < > CR LF and send the rest, so
#     `x<b@example.org>` went to a different address and `root,b@example.org`
#     went to two;
#   * a handler's own configured address, so an operator's `to` cannot name two
#     recipients either.
use strict;
use warnings;
use Test::More;
use JSON::PP   ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(repo_root site_tempdir run_cmd run_child);
use Lazysite::Mail     ();
use Lazysite::Handlers ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

subtest 'the definition' => sub {
    for my $good ( 'ada@example.net', 'web@localhost', 'first.last+tag@sub.example.org' ) {
        my ( $a, $why ) = Lazysite::Mail::one_address($good);
        is( $a, $good, "'$good' is one address, returned unchanged" );
    }
    for my $case (
        [ 'root,b@example.org',            qr/more than one recipient/ ],
        [ 'root;b@example.org',            qr/more than one recipient/ ],
        [ 'a@example.net, b@example.org',  qr/more than one recipient/ ],
        [ 'x<b@example.org>',              qr/more than one recipient/ ],
        [ 'Ada <ada@example.net>',         qr/more than one recipient/ ],
        [ "a\@example.net\nBcc: b\@x.org", qr/line break/ ],
        [ "a\@example.net\r",              qr/line break/ ],
        [ 'a b@example.net',               qr/not an email address/ ],
        [ 'a@b@example.net',               qr/not an email address/ ],
        [ '"a"@example.net',               qr/not an email address/ ],
        [ 'no-at-sign',                    qr/not an email address/ ],
        [ '',                              qr/no address/ ],
        )
    {
        my ( $v, $re )  = @$case;
        my ( $a, $why ) = Lazysite::Mail::one_address($v);
        ( my $label = $v ) =~ s/\r/\\r/g;
        $label =~ s/\n/\\n/g;
        ok( !defined $a, "'$label' is refused" );
        like( $why, $re, "'$label': and the reason says which rule" );
    }
};

subtest 'the header writer refuses rather than repairs' => sub {
    my $script = repo_root() . '/plugins/form-smtp.pl';
    plan skip_all => "no $script" unless -f $script;
    my $d = site_tempdir();
    make_path("$d/lazysite/forms");
    my $out  = "$d/mail.out";
    my $mock = "$d/sendmail";
    spit( $mock, "#!$^X\nopen my \$w, '>>', '$out' or exit 1; local \$/; print {\$w} <STDIN>; close \$w;\n" );
    chmod 0755, $mock;

    my $send = sub {
        my ($to) = @_;
        local $ENV{DOCUMENT_ROOT} = $d;
        my $res = run_child( [ $^X, $script, '--pipe' ], stderr => 'inherit',
            stdin => JSON::PP::encode_json( {
                config => { to => $to, from => 'web@example.org', method => 'sendmail',
                    sendmail_path => $mock },
                form => { message => 'hello' } } ) )->{out};
        return JSON::PP::decode_json($res);
    };

    my $ok = $send->('ada@example.net');
    ok( $ok->{ok}, 'one address is sent' ) or diag explain $ok;
    like( slurp($out), qr/^To: ada\@example\.net$/m, 'to that address' );

    for my $bad ( 'root,b@example.org', 'x<b@example.org>' ) {
        unlink $out;
        my $r = $send->($bad);
        ok( !$r->{ok}, "'$bad' is refused by the writer" );
        like( $r->{error}, qr/To address is refused/, 'naming the header' );
        is( slurp($out), '', 'and nothing reached sendmail - not a repaired address either' );
    }
};

subtest "a handler's own address is held to the same rule" => sub {
    my ( $h, $why, $field ) = Lazysite::Handlers::validate_handler( {
            id => 'c', type => 'smtp', name => 'C', from => 'web@example.org',
            to => 'office,b@example.org' } );
    ok( !$h, 'a to naming two recipients is refused at save' );
    is( $field, 'to', 'on the field' );
    like( $why, qr/more than one recipient/, 'saying why' );
};

# An account's address reaches a To: header too (a setup link, a notice), and
# it can come from a form field - the account-request approval reads it from the
# submission - so the account store holds it to the same rule.
subtest "an account's address is held to the same rule" => sub {
    my $tool = repo_root() . '/tools/lazysite-users.pl';
    my $d    = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    my $run = sub { my $o = run_cmd( $^X, $tool, "--docroot", $d, @_ ); return ( $? >> 8, $o ) };
    my ($added) = $run->( 'add', 'ada', 'pw-123456789' );
    is( $added, 0, 'an account exists' );
    my ( $ok_code, $ok_out ) = $run->( 'set', 'ada', 'email', 'ada@example.net' );
    is( $ok_code, 0, 'one address is accepted' ) or diag $ok_out;
    my ( $code, $out ) = $run->( 'set', 'ada', 'email', 'root,ada@example.net' );
    isnt( $code, 0, 'an address naming two recipients is refused' );
    like( $out, qr/Invalid email address/, 'saying so' );
};

done_testing();
