#!/usr/bin/perl
# SM1413 (ruling 158): A NOTIFY HANDLER'S RECIPIENTS MAY NAME A GROUP.
#
# No one is mailed by default; people are mailed through a notify handler the
# form names, and the people a site keeps are its accounts, with the addresses
# the Users page manages. So {"groups":[...]} reaches each member account of each
# named group - nested membership as the group store resolves it - at the address
# its account record holds, once each; a member with no address is skipped and
# counted in the outbox record; the operator group may be named; every rule of
# the other sources holds (one message per address, once; the per-recipient cap;
# the audit row; the unsubscribe path); a group the store does not know is
# refused at save, naming it.
#
# Reverted (no groups source), the save of a groups rule is refused as "not a
# source" and nothing below is sent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(repo_root site_tempdir run_cmd);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

my $root = repo_root();
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://site.example\n" );
my $OUT = "$d/mail.out";
spit( "$d/sendmail", "#!$^X\nopen my \$w, '>>', '$OUT' or exit 1; local \$/; print {\$w} \"--MESSAGE--\\n\", <STDIN>; close \$w;\n" );
chmod 0755, "$d/sendmail";
spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $d/sendmail\n" );

# ann and bob are in site-owners; carl is too, with no address; dee is in
# finance, which is nested inside site-owners; eve is in nothing; opal is the
# operator, in the shipped operator group.
my $users = "$root/tools/lazysite-users.pl";
sub users { my $r = run_cmd( $^X, $users, '--docroot', $d, @_ ); return $r }
users( 'setup-sysop', 'pw-123456789', '--user', 'opal' );
for my $u (qw(ann bob carl dee eve)) {
    users( 'add', $u, 'pw-123456789' );
    users( 'set', $u, 'email', "$u\@example.net" ) unless $u eq 'carl';
}
users( 'set', 'opal', 'email', 'opal@example.net' );
users( 'group-create', 'site-owners' );
users( 'group-create', 'finance' );
users( 'group-add', $_, 'site-owners' ) for qw(ann bob carl);
users( 'group-add', 'dee', 'finance' );
users( 'group-nest', 'finance', 'site-owners' );
users( 'group-add', 'bob', 'finance' );    # in it twice over: still one message

$Lazysite::Handlers::DOCROOT = $d;

my ($OPERATORS) = do {
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
    require Lazysite::Auth::Settings;
    Lazysite::Auth::Settings::operator_groups();
};
ok( length( $OPERATORS // '' ), "the site has an operator group ($OPERATORS)" ) or BAIL_OUT('no operator group');

sub rule {
    my (%o) = @_;
    return { id => 'owners', type => 'notify', name => 'Owners', recipients => '[{"groups":["site-owners"]}]',
        unsubscribe_path => '/account', per_recipient_hour => 1, %o };
}

sub save {
    my $r = Lazysite::Handlers::action_handler_save( rule(@_), caps => { manage_notifications => 1 } );
    return $r;
}

sub messages { return grep { length } split /--MESSAGE--\n/, slurp($OUT) }
sub to_list  { return [ sort map { /^To: (\S+)/m ? $1 : '?' } messages() ] }

sub event {
    my $r = Lazysite::Handlers::deliver( $_[1] // 'owners', { name => 'Ada', topic => $_[0] // 'x' },
        origin => 'form', source => 'form:contact', actor => '' );
    die 'not queued: ' . JSON::PP->new->encode($r) unless $r->{ok} && $r->{queued};
    return $r->{queued};
}

subtest 'an unknown group is refused at save, naming it' => sub {
    my $r = save( recipients => '[{"groups":["site-owners","no-such-group"]}]' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    like( $r->{error} // '', qr/no group 'no-such-group'/, 'naming the group' );
    unlike( $r->{error} // '', qr/'site-owners'(?! *[,-])/, '  and not the one that exists' );
    my ( $h, $why ) = Lazysite::Handlers::validate_handler( rule( recipients => '[{"groups":["bad name"]}]' ) );
    like( $why // '', qr/group name/, 'a name that cannot be a group is refused by the grammar' );
};

subtest 'a group of members: each at its own address, once; nested; no address skipped and counted' => sub {
    my $r = save();
    ok( $r->{ok}, 'a rule naming an existing group saves' ) or diag explain $r;
    my $id = event('first');
    my $j  = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
    ok( $j->{ok}, 'the job ran' ) or diag explain $j;
    is_deeply( to_list(), [qw(ann@example.net bob@example.net dee@example.net)],
        'ann and bob directly, dee through the nested group, bob once; not eve, not carl' );
    my $audit = slurp("$d/lazysite/logs/audit.log");
    like( $audit, qr/notify:owners -> email \| [^\n]*ok \| daemon \| account ann/, 'one audit row per recipient' );
    unlike( $audit, qr/account carl/, 'carl, who has no address, is not audited as a refusal' );
    my $st = JSON::PP::decode_json( slurp("$d/lazysite/notify/status.json") );
    is( $st->{owners}{no_address}, 1, 'carl is counted in the rule\'s status' );
    is( $st->{owners}{sent},       3, 'beside the three sent' );
    my $view = Lazysite::Outbox::outbox_list( docroot => $d, id => $id );
    is( $view->{recipients}{counts}{email}{'no-address'}, 1, 'and in the event\'s outbox record' )
        or diag explain $view;
    like( ( messages() )[0], qr/^List-Unsubscribe: <https:\/\/site\.example\/cgi-bin\/lazysite-auth\.pl\?action=unsubscribe/m,
        'each message carries the unsubscribe link' );
};

subtest 'the per-recipient cap holds for group members' => sub {
    unlink $OUT;
    event('second');
    my $j = Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
    ok( $j->{ok}, 'the job ran' );
    is_deeply( to_list(), [], 'a cap of one an hour: the second event sends nothing now' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/held: the per-recipient cap \(1 an hour/,
        'it is held, as for any source' );
};

subtest 'the operator group may be named' => sub {
    unlink $OUT;
    my $r = save( id => 'ops', recipients => qq([{"groups":["$OPERATORS"]}]) );
    ok( $r->{ok}, "a rule naming $OPERATORS saves" ) or diag explain $r;
    event( 'third', 'ops' );
    Lazysite::Outbox::run( docroot => $d, actor => 'jobs' );
    is_deeply( to_list(), ['opal@example.net'], 'and reaches the operator (the other rule\'s held mail still waits)' );
};

done_testing();
