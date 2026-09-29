#!/usr/bin/perl
# SM485: a notice can name an account, and reach that person by mail if they
# asked for it.
#
# Measured before this was built: `notify()` built its record from a fixed key
# list, so a `to` passed by a caller was DROPPED SILENTLY - every notice was a
# site-wide broadcast and the bell was the only endpoint that could be reached
# without a chat server.
#
# RULED 2026-09-29, and each clause is a subtest below: opt-in per account (the
# person decides), the Form SMTP extension as the transport with a refusal that
# NAMES it when it is off, a broadcast delivered to nobody by mail, and the
# per-site hourly bound kept.
#
# WHY THERE IS NO PER-RECIPIENT CAP, which is the one place this departs from
# SM877: that cap exists because a form acknowledgement goes to an address a
# visitor typed. A notice can only reach an account that already exists, at the
# address its own record holds, having opted in - so there is no address here
# that the site did not already have.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Notify ();

my $d = site_tempdir();
make_path( "$d/lazysite/logs", "$d/lazysite/auth", "$d/lazysite/forms" );

# The transport is replaced at its seam, the way t/unit/lib/26 replaces the XMPP
# one - so what is under test is the DECIDING, not somebody's mail server.
my @sent;
{
    no warnings 'redefine', 'once';
    $Lazysite::Notify::MAIL_SENDER = sub {
        my ( $docroot, $script, $addr, $subject, $text ) = @_;
        push @sent, { addr => $addr, subject => $subject, text => $text };
        return 1;
    };
}

sub write_conf {
    my (%kv) = @_;
    open my $fh, '>', "$d/lazysite/notify.conf" or die $!;
    print {$fh} "$_: $kv{$_}\n" for sort keys %kv;
    close $fh;
}

sub write_settings {
    my ($h) = @_;
    open my $fh, '>', "$d/lazysite/auth/user-settings.json" or die $!;
    print {$fh} JSON::PP->new->canonical->encode($h);
    close $fh;
}

sub site_conf {
    my ($body) = @_;
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $body;
    close $fh;
}

# The SMTP extension: present, listed, and configured. Each of the three is
# taken away on its own further down, because a refusal has to name the RIGHT
# one of them.
site_conf("site_name: T\nextensions:\n  - plugins/form-smtp.pl\n");
open my $sc, '>', "$d/lazysite/forms/smtp.conf" or die $!;
print {$sc} "method: sendmail\nfrom: site\@example.com\n";
close $sc;

write_settings( {
        ada => { email => 'ada@example.com', notify_email => JSON::PP::true() },
        bob => { email => 'bob@example.com' },                      # never asked
        cyd => { notify_email => JSON::PP::true() },                # asked, no address
} );
write_conf( 'route.submission' => 'bell,email' );

sub send_notice {
    @sent = ();
    return Lazysite::Notify::notify( $d, { type => 'submission', @_ } );
}

sub last_notice {
    open my $fh, '<', "$d/lazysite/logs/notices.jsonl" or return {};
    my @l = <$fh>;
    close $fh;
    return decode_json( $l[-1] // '{}' );
}

subtest 'A NOTICE NAMES AN ACCOUNT, and the record keeps it' => sub {
    ok( send_notice( message => 'an enquiry arrived', to => 'ada' ), 'notify succeeded' );
    my $rec = last_notice();
    is( $rec->{to}, 'ada', 'the addressee is stored' )
        or diag( 'Before SM485 the record was built from a fixed key list and `to` '
            . 'was dropped silently - the caller could not tell.' );
    is( $rec->{message}, 'an enquiry arrived', 'alongside the message' );
};

subtest 'AND REACHES THAT PERSON, at the address their account holds' => sub {
    send_notice( message => 'an enquiry arrived', to => 'ada' );
    is( scalar @sent, 1, 'one mail' ) or return;
    is( $sent[0]{addr}, 'ada@example.com',
        'to the address on the account, which the notice never supplied' );
    like( $sent[0]{text}, qr/an enquiry arrived/, 'carrying the message' );
    like( $sent[0]{subject}, qr/\[T\]/, 'subject names the site' );
};

subtest 'A BROADCAST REACHES NOBODY BY MAIL' => sub {
    # The ruling: it is a bell item, and a list of every account's address is a
    # different feature from a notification one.
    my @logged;
    no warnings 'redefine', 'once';
    local *Lazysite::Notify::log_event = sub { push @logged, join ' ', @_[ 2 .. $#_ ] };

    ok( send_notice( message => 'something happened' ), 'the notice is still made' );
    is( scalar @sent, 0, 'and no mail goes anywhere' )
        or diag( 'A broadcast has no addressee; mailing "everyone" would mean '
            . 'building the address list this filing refused to build.' );
    my $rec = last_notice();
    ok( !exists $rec->{to}, 'the record carries no addressee' );
    ok( $rec->{message}, 'but it is in the bell, which is the record' );

    # AND IT IS REFUSED AS A BROADCAST, not as a lookup that failed.
    #
    # Sabotage earned this assertion. Removing the broadcast guard changed
    # nothing observable, because _mail_recipient refuses an empty login anyway -
    # so the test could not tell the two apart and would have passed on a build
    # that had lost the guard. The behaviour is the same; the REASON a sysop
    # reads is not, and "there is no account ''" would send them looking for a
    # missing account instead of telling them broadcasts do not go by mail.
    like( join( ' ', @logged ), qr/broadcast/i,
        'the reason says it is a broadcast, not that an account is missing' );
    unlike( join( ' ', @logged ), qr/there is no account/,
        'which is what the lookup would have said if the guard were gone' );
};

subtest 'THE PERSON DECIDES: no opt-in, no mail' => sub {
    send_notice( message => 'for bob', to => 'bob' );
    is( scalar @sent, 0, 'bob has an address but never asked' )
        or diag( 'Opt-in is the ruling. A site turning the route on must not '
            . 'start mailing people who did not ask for it.' );
    # THE DISCRIMINATOR: the same run mails ada, so the silence above is the
    # opt-in and not a broken rig.
    send_notice( message => 'for ada', to => 'ada' );
    is( scalar @sent, 1, 'while ada, who did ask, still gets hers' );
};

subtest 'an account that asked but has no address, and one that does not exist' => sub {
    send_notice( message => 'for cyd', to => 'cyd' );
    is( scalar @sent, 0, 'opted in with no address on the account sends nothing' );
    send_notice( message => 'for nobody', to => 'nosuchperson' );
    is( scalar @sent, 0, 'and an account that does not exist sends nothing' );
};

subtest 'THE ROUTE IS THE SITE HALF, and off by default' => sub {
    # Both switches are real and different: the site says which TYPES may leave
    # by mail, the person says whether THEY want mail. Neither implies the other.
    write_conf();    # no route.* at all - the shipped default for every type
    send_notice( message => 'an enquiry arrived', to => 'ada' );
    is( scalar @sent, 0, 'no type is routed to email by default' )
        or diag( 'Every default_route in the registry is bell or bell,xmpp, so '
            . 'an upgrade cannot start a site mailing anybody.' );
    write_conf( 'route.submission' => 'bell,email' );
    send_notice( message => 'an enquiry arrived', to => 'ada' );
    is( scalar @sent, 1, 'and it sends once the site routes it there' );
};

subtest 'THE REFUSAL NAMES THE EXTENSION, and names which thing is wrong' => sub {
    # Three separate ways the transport can be unavailable, and a sysop reading
    # the log needs to be told which - "mail failed" would send them to the
    # wrong place twice out of three times.
    my @logged;
    no warnings 'redefine', 'once';
    # Patched in NOTIFY's namespace, not Util's: `use Lazysite::Util qw(log_event)`
    # aliases the sub into Notify at compile time, so replacing the original
    # leaves the alias pointing at the old one and captures nothing. The first
    # version of this subtest did that and read as "the refusal says nothing".
    local *Lazysite::Notify::log_event = sub { push @logged, join ' ', @_[ 2 .. $#_ ] };

    # (a) switched off in the conf
    site_conf("site_name: T\n");
    @logged = ();
    send_notice( message => 'x', to => 'ada' );
    is( scalar @sent, 0, 'switched off: nothing sent' );
    like( join( ' ', @logged ), qr/switched off/i,
        'and the reason says the extension is off' );

    # (b) on, but never configured
    site_conf("site_name: T\nextensions:\n  - plugins/form-smtp.pl\n");
    rename "$d/lazysite/forms/smtp.conf", "$d/lazysite/forms/smtp.conf.away" or die $!;
    @logged = ();
    send_notice( message => 'x', to => 'ada' );
    is( scalar @sent, 0, 'unconfigured: nothing sent' );
    like( join( ' ', @logged ), qr/no settings yet/i,
        'and the reason says to save the SMTP settings' );
    rename "$d/lazysite/forms/smtp.conf.away", "$d/lazysite/forms/smtp.conf" or die $!;

    # (c) and the one that is not the extension's fault at all
    @logged = ();
    send_notice( message => 'x', to => 'bob' );
    like( join( ' ', @logged ), qr/has not asked/i,
        'an opt-in refusal does not blame the extension' );
};

subtest 'THE PER-SITE HOURLY BOUND' => sub {
    unlink "$d/lazysite/logs/notice-mail.jsonl";
    write_conf( 'route.submission' => 'bell,email', 'mail.per_hour' => 3 );
    my $delivered = 0;
    for ( 1 .. 5 ) {
        send_notice( message => "notice $_", to => 'ada' );
        $delivered += scalar @sent;
    }
    is( $delivered, 3, 'three go, the rest are held' )
        or diag( 'Unbounded should be a decision, not the default - this is what '
            . 'stops a loop in a caller mailing all night.' );

    # AN UNREADABLE RECORD REFUSES rather than counting as zero. A cap that
    # cannot count has not established that there is room.
    my $f = "$d/lazysite/logs/notice-mail.jsonl";
  SKIP: {
        skip 'running as root, which can read a 0000 file', 2 if $> == 0;
        chmod 0000, $f or die $!;
        send_notice( message => 'after the record went unreadable', to => 'ada' );
        is( scalar @sent, 0, 'a record that will not open holds the send' );
        chmod 0644, $f or die $!;
        ok( 1, 'and the file is restored for the next test' );
    }
};

subtest 'a `to` that sanitises away stays a broadcast rather than becoming one silently' => sub {
    unlink "$d/lazysite/logs/notice-mail.jsonl";
    write_conf( 'route.submission' => 'bell,email' );
    send_notice( message => 'addressed to punctuation', to => '!!!' );
    my $rec = last_notice();
    ok( !exists $rec->{to}, 'the unusable addressee is not stored' );
    is( scalar @sent, 0, 'and nothing is mailed' )
        or diag( 'Promoting a broken `to` to a broadcast would show one account\'s '
            . 'notice to everyone holding the bell.' );
};

done_testing();
