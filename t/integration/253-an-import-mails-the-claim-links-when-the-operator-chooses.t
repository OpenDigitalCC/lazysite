#!/usr/bin/perl
# SM1053 (n570), the first of what the core left unbuilt: "accounts get claim
# links (set their own password; mailed only if the operator chooses)". The
# apply takes `mail` - off unless the operator sends it - and mails each new
# account its own link at the address its row carries, through the site's one
# mail path (the Form SMTP extension, Lazysite::Notify::send_mail) and its
# per-hour bound (mail.per_hour in notify.conf). A send that fails, or that the
# bound refuses, is reported on its row and never stops the apply; every send
# asked for is audited.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL = qw(ui api manage_users manage_content);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\n"
        . "site_url: https://www.example.org\n" . "plugins:\n  - plugins/form-smtp.pl\n" );
my $d = $s->docroot;
$s->add_user( 'op', 'pw-op-0123456789' );
$s->grant( 'op', 'g-op', [qw(ui manage_users manage_content)], \@ALL );
$s->users( 'group-set', 'g-op', 'manager', 'on' );    # SM991: the operator

# The transport: a sendmail that keeps each message, and refuses one recipient.
my $box = "$d/mailbox";
make_path("$d/lazysite/forms");
open my $sm, '>', "$d/fake-sendmail" or die $!;
print {$sm} <<"PL";
#!$^X
my \$m = do { local \$/; <STDIN> };
exit 1 if \$m =~ /^To: bounce\\\@/m;
open my \$fh, '>>', '$box' or die;
print {\$fh} \$m, "\\n=====\\n";
PL
close $sm;
chmod 0755, "$d/fake-sendmail";
open my $sc, '>', "$d/lazysite/forms/smtp.conf" or die $!;
print {$sc} "method: sendmail\nsendmail_path: $d/fake-sendmail\nfrom: site\@example.org\n";
close $sc;
open my $nc, '>', "$d/lazysite/notify.conf" or die $!;
print {$nc} "mail.per_hour: 2\n";
close $nc;

sub api {
    my ( $action, $body, $query ) = @_;
    return $s->call( 'op', $action, ( defined $body ? ( body => $body ) : () ),
        query => $query // "action=$action" );
}
sub mails { open my $fh, '<', $box or return (); local $/; return split /\n=====\n/, scalar <$fh> }
sub audit { open my $fh, '<', "$d/lazysite/logs/audit.log" or return (); return <$fh> }

sub stage {
    my (@rows) = @_;
    my $r = api( 'accounts-import-stage', { accounts => \@rows } );
    ok( $r->{ok}, 'staged' ) or diag( $r->{error} // '' );
    return $r->{id};
}

subtest 'without the choice, nothing is mailed' => sub {
    my $id = stage( { username => 'q1', email => 'q1@example.org' } );
    my $r  = api( 'accounts-import-apply', { id => $id, confirm => $id } );
    ok( $r->{ok}, 'applied' ) or diag( $r->{error} // '' );
    is( scalar( my @none = mails() ), 0, 'no mail went out' );
    my ($q1) = @{ $r->{created} || [] };
    ok( !exists $q1->{mailed} && !exists $q1->{mail_error}, '...and the row says nothing about mail' );
    ok( !( grep { /accounts-import-mail/ } audit() ), '...or the trail' );

    # A boolean has four states: "false" is a string Perl calls true.
    $id = stage( { username => 'q2', email => 'q2@example.org' } );
    $r  = api( 'accounts-import-apply', { id => $id, confirm => $id, mail => 'false' } );
    ok( $r->{ok}, 'applied with mail => "false"' );
    is( scalar( my @still = mails() ), 0, '...and that is no' );
};

subtest 'with it, each new account is mailed its own link' => sub {
    my $id = stage(
        { username => 'm1', email => 'm1@example.org' },
        { username => 'm2' },
        { username => 'm3', email => 'bounce@example.org' },
        { username => 'm4', email => 'm4@example.org' },
        { username => 'm5', email => 'm5@example.org' } );
    my $r = api( 'accounts-import-apply', { id => $id, confirm => $id, mail => JSON::PP::true() } );
    ok( $r->{ok}, 'applied: a mail that did not go never fails the apply' ) or diag( $r->{error} // '' );
    is( scalar @{ $r->{created} || [] }, 5, 'all five created' );
    my %c = map { $_->{username} => $_ } @{ $r->{created} || [] };

    ok( $c{m1}{mailed}, 'm1: mailed' );
    my @m = mails();
    is( scalar @m, 2, 'two messages went out (m1, m4)' );
    my ($to_m1) = grep { /^To: m1\@example\.org$/m } @m;
    ok( $to_m1, 'one to m1, at the address its row carried' );
    like( $to_m1 // '', qr{https://www\.example\.org/claim\?u=m1&c=\w+}, '...carrying m1\'s own claim link' );
    like( $to_m1 // '', qr/Subject: Set your password/, '...as a setup link' );
    unlike( join( '', @m ), qr{claim\?u=m2}, 'no other account\'s link went to anyone' );

    like( $c{m2}{mail_error} // '', qr/no address/, 'm2: no address, said on its row' );
    like( $c{m3}{mail_error} // '', qr/not accepted/, 'm3: the transport refused it, said on its row' );
    ok( $c{m4}{mailed}, 'm4: mailed' );
    like( $c{m5}{mail_error} // '', qr/cap/, 'm5: the per-hour bound reached, said on its row' );
    like( $c{m5}{mail_error} // '', qr/mail\.per_hour/, '...naming the setting' );
    like( $c{m5}{claim_url} // '', qr{/claim}, '...and its link is still the operator\'s to send' );
    is( $r->{mail}{sent},     2, 'the summary: two sent' );
    is( $r->{mail}{not_sent}, 3, '...three not' );

    my @a = grep { /accounts-import-mail/ } audit();
    is( scalar @a, 5, 'one audit row per send asked for' );
    ok( ( grep { /\bm1\b/ && /\| ok \|/ } @a ), '...m1 ok' ) or diag(@a);
    ok( ( grep { /\bm3\b/ && /\| fail \|/ } @a ), '...m3 failed' ) or diag(@a);
    ok( !( grep { /example\.org/ } @a ), '...naming no address (SM877)' ) or diag(@a);
    ok( ( grep { /accounts-import-apply/ && /handed to the mail transport 2, not handed over 3/ } audit() ), 'the apply row counts the mail, as handed to the transport' ) or diag( audit() );
    # SM1111: "mailed" meant "handed to the transport" - a site whose sendmail
    # delivers nothing still read "mailed 3, not mailed 0". The reply says so.
    like( $r->{change}, qr/handed to the mail transport 2, not handed over 3/, 'the reply says handed to the mail transport' );
    unlike( $r->{change}, qr/\bmailed\b/, '...and does not say mailed' );
    like( $r->{mail}{meaning} // '', qr/handed to the mail transport.*not (?:a )?confirm/i, '...and says that is not delivery' );
    ok( ( grep { /\bm1\b/ && /claim link handed to the mail transport/ } @a ), 'the trail row says handed over, too' ) or diag(@a);
};

subtest 'a site that cannot send says so on each row' => sub {
    unlink "$d/lazysite/forms/smtp.conf";
    my $id = stage( { username => 'n1', email => 'n1@example.org' } );
    my $r  = api( 'accounts-import-apply', { id => $id, confirm => $id, mail => JSON::PP::true() } );
    ok( $r->{ok}, 'applied' );
    my ($n1) = @{ $r->{created} || [] };
    like( $n1->{mail_error} // '', qr/SMTP settings/, 'n1: no SMTP settings, said on its row' );
};

done_testing;
