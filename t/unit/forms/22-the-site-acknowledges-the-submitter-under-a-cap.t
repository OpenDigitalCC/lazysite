#!/usr/bin/perl
# SM877: a form can acknowledge the person who filled it in, and the caps are
# the feature.
#
# The smtp handler's `to` is fixed at configuration time, so a site could notify
# its owner and could not answer the visitor - every receipt, booking
# confirmation and consent record needs the other direction. The requester
# proposed inheriting the existing form rate limiting, and the filing checked it
# before accepting: `check_rate_limit` is keyed per SOURCE IP, so it caps how
# often one sender submits and says nothing about how many distinct destinations
# the site will mail. For an open relay that is the wrong axis, and the victim
# is the recipient - the party the per-IP limit does not protect.
#
# So the axes here are PER RECIPIENT and PER SITE, and this file holds what the
# design had to settle:
#
#   * a SEPARATE delivery, not a second `To:` - otherwise the operator's address
#     lands in a stranger's inbox.
#   * the operator's copy still goes when the acknowledgement does not. The site
#     got what it was told about; a visitor whose form worked is not shown a
#     failure because a courtesy message was capped.
#   * and it is NOT silent: the reason travels on the result, into the delivery's
#     audit record and the event log.
#   * a counter that will not open REFUSES rather than reading as "this has
#     never happened", which is this release's own lesson applied to a cap.
#   * the record holds a HASH of the recipient, never the address. A counter
#     needs "this one again", not who, and a file of every address a site has
#     acknowledged is a mailing list nobody agreed to.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Handlers ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

# A mock sendmail that APPENDS every message it is piped, so one run can be
# asked how many messages went and to whom.
sub mock_sendmail {
    my ( $dir, $out ) = @_;
    my $path = "$dir/sendmail";
    spit( $path,
              "#!$^X\n"
            . 'open my $w, ">>:raw", "' . $out . '" or exit 1;' . "\n"
            . 'local $/; print {$w} "--MESSAGE--\n", <STDIN>; close $w;' . "\n" );
    chmod 0755, $path;
    return $path;
}

my $OUT;

sub site {
    my (%h) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    $OUT = "$d/mail.out";
    my $mock = mock_sendmail( $d, $OUT );

    my %cfg = (
        id   => 'contact',
        type => 'smtp',
        from => 'web@example.org',
        to   => 'office@example.org',
        method        => 'sendmail',
        sendmail_path => $mock,
        %h,
    );
    my $conf = "handlers:\n";
    $conf .= "  - id: $cfg{id}\n";
    delete $cfg{id};
    $conf .= "    $_: $cfg{$_}\n" for sort keys %cfg;
    spit( "$d/lazysite/forms/handlers.conf", $conf );

    $Lazysite::Handlers::DOCROOT = $d;
    return $d;
}

sub deliver {
    my (%fields) = @_;
    return Lazysite::Handlers::deliver( 'contact', {%fields},
        source => 'form:contact', actor => '', ip => '10.0.0.1', origin => 'form' );
}

sub messages {
    my $t = slurp($OUT) // '';
    return grep { length } split /--MESSAGE--\n/, $t;
}

sub recipients {
    return map { /^To:\s*(\S+)/m ? $1 : '?' } messages();
}

subtest 'nothing changes for a handler that does not ask for it' => sub {
    site();
    my $r = deliver( name => 'Ada', email => 'ada@example.net' );
    ok( $r->{ok}, 'delivered' ) or diag explain $r;
    ok( !length( $r->{note} // '' ), 'and there is nothing to report' );
    is_deeply( [ recipients() ], ['office@example.org'],
        'one message, to the operator - the submitter is not written to' );
};

subtest 'with the field named, the submitter gets their own separate message' => sub {
    my $d = site( mail_the_submitter_field => 'email' );
    my $r = deliver( name => 'Ada', email => 'ada@example.net' );
    ok( $r->{ok}, 'delivered' ) or diag explain $r;
    ok( !length( $r->{note} // '' ), 'with nothing to report' );

    # `sort recipients()` is not this: Perl reads the bare name as the
    # comparison routine and sorts an empty list. The block form says which is
    # meant.
    my @to = sort { $a cmp $b } recipients();
    is_deeply( \@to, [ 'ada@example.net', 'office@example.org' ],
        'TWO messages, one each' );

    # The separate-delivery requirement, as a property rather than a count: no
    # message is ADDRESSED to both, or the operator's address reaches a
    # stranger's inbox. The operator's own copy does of course quote the
    # submitted address as a field value, which is the point of the copy - so
    # the assertion is on the envelope, not on the body.
    for my $m ( messages() ) {
        my @headers = ( $m =~ /^To:\s*(.+)$/mg );
        is( scalar @headers, 1, 'one To: header' );
        ok( !( $headers[0] =~ /ada/ && $headers[0] =~ /office/ ),
            'and it names one recipient, not both' );
    }

    my $rec = slurp("$d/lazysite/forms/submitter-mail.jsonl") // '';
    my @lines = grep { length } split /\n/, $rec;
    is( scalar @lines, 1, 'one line in the counter' );
    unlike( $rec, qr/ada\@example\.net/,
        'and the counter holds no address - a hash counts, a list mails' );
    my $row = JSON::PP::decode_json( $lines[0] );
    ok( $row->{t} && $row->{d}, 'a timestamp and a key' );
};

subtest 'the per-recipient cap refuses the second, and the operator still gets theirs' => sub {
    site( mail_the_submitter_field => 'email', submitter_per_destination_hour => 1 );

    my $first = deliver( email => 'ada@example.net' );
    ok( $first->{ok} && !length( $first->{note} // '' ), 'the first goes' );

    my $second = deliver( email => 'ada@example.net' );
    ok( $second->{ok}, 'the submission still succeeds' )
        or diag( 'A visitor whose form worked must not be shown a failure '
            . 'because a courtesy message was capped.' );
    like( $second->{note}, qr/per-recipient cap/, 'and says the cap stopped it' );
    like( $second->{note}, qr/\b1\b/,             'naming the cap' );
    like( $second->{note}, qr/submitter_per_destination_hour/,
        'and the setting that raises it' );

    my @to = recipients();
    is( scalar( grep { $_ eq 'office@example.org' } @to ), 2,
        'the operator got both notifications' );
    is( scalar( grep { $_ eq 'ada@example.net' } @to ), 1,
        'and the submitter got exactly one' );
};

subtest 'the per-site axis is wired, and is not the per-recipient one' => sub {
    site( mail_the_submitter_field => 'email',
        submitter_per_destination_hour => 99, submitter_per_site_hour => 1 );

    ok( !length( deliver( email => 'one@example.net' )->{note} // '' ), 'the first goes' );
    my $second = deliver( email => 'two@example.net' );    # a DIFFERENT recipient
    like( $second->{note}, qr/per-site cap/,
        'a different address is still refused by the site axis' )
        or diag( 'If only the per-recipient axis were counted, an attacker '
            . 'would use a different address each time.' );
    like( $second->{note}, qr/submitter_per_site_hour/, 'naming that setting' );
};

subtest 'refuse rather than guess when the field cannot give an address' => sub {
    for my $case (
        [ 'absent', {},                      qr/has no field 'email'/ ],
        [ 'empty',  { email => '' },         qr/is empty/ ],
        [ 'junk',   { email => 'not-an-at' }, qr/not an email address/ ],
        )
    {
        my ( $label, $fields, $re ) = @$case;
        my $d = site( mail_the_submitter_field => 'email' );
        my $r = deliver( %$fields, name => 'Ada' );
        ok( $r->{ok}, "$label: the submission still succeeds" );
        like( $r->{note}, $re, "$label: and the note says why nobody was written to" );
        is_deeply( [ recipients() ], ['office@example.org'],
            "$label: only the operator was written to" );
        ok( !-e "$d/lazysite/forms/submitter-mail.jsonl",
            "$label: and nothing was counted" );
    }
};

subtest 'a counter that will not open refuses the acknowledgement' => sub {
    plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;

    my $d = site( mail_the_submitter_field => 'email' );
    my $rec = "$d/lazysite/forms/submitter-mail.jsonl";
    spit( $rec, '' );
    chmod 0000, $rec;

    my $r = deliver( email => 'ada@example.net' );
    ok( $r->{ok}, 'the submission still succeeds' );
    like( $r->{note}, qr/cannot tell how much of its per-recipient cap/,
        'and the acknowledgement is refused because the cap cannot be honoured' )
        or diag( 'An unreadable counter reading as zero would switch the cap '
            . 'off at exactly the moment something is wrong.' );
    like( $r->{note}, qr/nothing was sent/, 'saying plainly that nothing went' );
    is_deeply( [ recipients() ], ['office@example.org'],
        'the submitter was not written to' );

    chmod 0644, $rec;
};

subtest 'the note is not silent: it reaches the audit trail and the log' => sub {
    my $d = site( mail_the_submitter_field => 'email', submitter_per_destination_hour => 0 );
    my $r = deliver( email => 'ada@example.net' );
    like( $r->{note}, qr/cap/, 'the note is there' );

    my $trail = slurp("$d/lazysite/logs/audit.log") // '';
    like( $trail, qr/\| ok \|/, 'the delivery is recorded as ok - it did happen' );
    like( $trail, qr/cap/,
        'and the detail field carries what did not happen' )
        or diag( 'A partial recorded nowhere is the silence this release spent '
            . 'its time removing.' );
};

done_testing();
