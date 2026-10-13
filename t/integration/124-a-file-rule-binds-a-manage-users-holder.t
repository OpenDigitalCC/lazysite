#!/usr/bin/perl
# SM979 (ruled 2026-10-11, "New approve capability"): manage_users is account
# management, not a key to every file; approving an account request is a grant
# of its own; and group-reach says what a group can actually do.
#
# Reported from a members' area on 0.15.3: a group holding only manage_users,
# made to approve account requests, saved a new page at the site root and
# overwrote another author's post through `save`, past rules naming neither it
# nor its group (root `write @authors,@sysops`; the post `write
# GeekRuthie,@editors,@sysops`) - 200 both. `group-reach` said it could call
# nothing. Lazysite::Auth::Acl::_acl_denied bypassed every file rule for
# _is_operator(), which is true for any manage_users holder.
#
# Measured on main beside it (tmp/probe1.pl, .main.out): the same holder READ a
# gated file, REWROTE another owner's rule (acl-set) and MOVED their post; and
# an account holding only ui + read_submissions, which `save` refused, made a
# folder (mkdir) and put a file (file-upload) at the root the rule governs -
# those two asked no rule at all. A move and a copy asked the source's rule and
# never the target's.
#
# SM1057 (ruled 2026-10-12, "Require manage_content"): a content write in the
# manager now needs manage_content before the file's rule is asked, so the
# reported group (ui + manage_users) and the ui + read_submissions account are
# refused by that gate first. Each case asserts that refusal, and runs again as
# a twin holding manage_content as well (apprw, rsw), which passes the gate and
# is refused by the file's rule - the rule is what SM979 fixed, and stays tested.
#
# Every assertion reads the docroot afterwards, not only the reply, and every
# request carries the account's groups as the auth wrapper sends them
# (X-Remote-Groups), because @group entries match only through it.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root   = repo_root();
my $PLUGIN = "$root/plugins/form-handler.pl";
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $s = new_site( root => $root );
my $d = $s->docroot;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my @ALL = qw(ui manage_users read_submissions approve_accounts manage_content manage_config
    create_sub_users webdav api mcp);
$s->add_user('boss');          # the sysop: named in the rules, as the starter's are
$s->grant( 'boss', 'sysops', [qw(ui manage_users read_submissions manage_content manage_config)], \@ALL );
$s->add_user('appr');          # the reported group
$s->grant( 'appr', 'approvers', [qw(ui manage_users)], \@ALL );
$s->add_user('rs');            # a manager account the root rule does not name
$s->grant( 'rs', 'readers', [qw(ui read_submissions)], \@ALL );
$s->add_user('GeekRuthie');    # an author
$s->grant( 'GeekRuthie', 'authors', [qw(ui manage_content)], \@ALL );
$s->add_user('door');          # the new grant, alone
$s->grant( 'door', 'doorkeepers', [qw(ui approve_accounts)], \@ALL );
$s->add_user('ed');            # an editor, so @editors names somebody
$s->grant( 'ed', 'editors', [qw(ui manage_content)], \@ALL );
# SM1057: the twins that pass the manage_content gate, in groups no rule names.
$s->add_user('apprw');         # manage_users that also writes content
$s->grant( 'apprw', 'approvers-who-write', [qw(ui manage_users manage_content)], \@ALL );
$s->add_user('rsw');           # read_submissions that also writes content
$s->grant( 'rsw', 'readers-who-write', [qw(ui read_submissions manage_content)], \@ALL );

make_path( "$d/post", "$d/members", "$d/editors-only" );
my $POST = "---\ntitle: A\n---\nthe author's text\n";
spit( "$d/post/a.md",         $POST );
spit( "$d/members/m.md",      "---\ntitle: M\n---\nmembers only\n" );
spit( "$d/editors-only/e.md", "---\ntitle: E\n---\nx\n" );
sub acl {
    my $cmd = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-acl.pl", @_,
        '--docroot', $d, '--actor', 'local';
    my $out = qx($cmd 2>&1);
    return $? >> 8;
}
is( acl( 'set', '/', '--write', '@authors,@sysops' ), 0, 'the canary: the site-wide rule is set' );
is( acl( 'set', 'post/a.md', '--owner', 'GeekRuthie', '--write', 'GeekRuthie,@editors,@sysops' ), 0,
    'the post\'s rule is set' );
is( acl( 'set', 'members', '--read', '@authors,@sysops', '--write', '@authors,@sysops' ), 0,
    'a members-only folder is set' );
is( acl( 'set', 'editors-only', '--write', '@editors' ), 0, 'a folder only editors write' );

my $PAGE = "---\ntitle: X\n---\nx\n";
sub call { my ( $u, $act, %o ) = @_; return $s->call( $u, $act, groups => 1, %o ) }
sub save { my ( $u, $p, $c ) = @_; return call( $u, 'save', query => "action=save&path=$p", body => { content => $c // $PAGE } ) }
sub refused_write {
    my ( $r, $label ) = @_;
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'permission', "$label: refused by the file's rule" )
        or diag( explain $r );
    is( $s->last_status, 403, "$label: 403" );
}
# SM1057: refused before the rule, for want of manage_content.
sub refused_content_cap {
    my ( $r, $label ) = @_;
    ok( ManagerSession->refused_for_capability($r) && ( $r->{error} // '' ) =~ /manage_content/,
        "$label: refused for manage_content" )
        or diag( explain $r );
    is( $s->last_status, 403, "$label: 403" );
}

subtest 'the reported case: a manage_users holder writes no file its rule does not name' => sub {
    refused_content_cap( save( 'appr', 'new-appr.md' ), 'a new page at the root' );
    ok( !-e "$d/new-appr.md", 'and no page was made' );
    refused_content_cap( save( 'appr', 'post/a.md', "overwritten\n" ), "another author's post" );
    is( slurp("$d/post/a.md"), $POST, 'and the post is as its author left it' );

    refused_write( save( 'apprw', 'new-apprw.md' ), 'a new page at the root, with manage_content too' );
    ok( !-e "$d/new-apprw.md", 'and no page was made' );
    refused_write( save( 'apprw', 'post/a.md', "overwritten\n" ), "another author's post, with manage_content too" );
    is( slurp("$d/post/a.md"), $POST, 'and the post is as its author left it' );
};

subtest 'nor reaches one another way' => sub {
    my $r = call( 'appr', 'read', query => 'action=read&path=members/m.md' );
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'permission', 'a gated file is not read' ) or diag( explain $r );
    $r = call( 'appr', 'acl-set', query => 'action=acl-set&path=post/a.md', body => { write => 'appr' } );
    like( $r->{error} // '', qr/Only the owner may change permissions/, "another owner's rule is not rewritten" );
    my $store = decode_json( slurp("$d/lazysite/auth/acls.json") );
    is_deeply( $store->{'post/a.md'}{write}, [qw(GeekRuthie @editors @sysops)], 'the rule is unchanged' );
    $r = call( 'appr', 'acl-remove', query => 'action=acl-remove&path=post/a.md', body => {} );
    like( $r->{error} // '', qr/Only the owner may remove permissions/, "nor removed" );
    $store = decode_json( slurp("$d/lazysite/auth/acls.json") );
    ok( $store->{'post/a.md'}, 'and the rule is still there' );
    for my $u (qw(appr apprw)) {
        my $refused = $u eq 'appr' ? \&refused_content_cap : \&refused_write;
        $refused->( call( $u, 'move', query => 'action=move&path=post/a.md&to=post/b.md', body => {} ),
            "another author's post moved ($u)" );
        ok( -e "$d/post/a.md" && !-e "$d/post/b.md", 'and it did not move' );
        $refused->( call( $u, 'delete', query => 'action=delete&path=post/a.md', body => {} ),
            "another author's post deleted ($u)" );
        ok( -e "$d/post/a.md", 'and it is there' );
    }
};

subtest 'every file write asks the rule of the path it writes' => sub {
    my $B  = 'XyZb0undary';
    my $mp = "--$B\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\n1\r\n"
        . "--$B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.md\"\r\n"
        . "Content-Type: text/markdown\r\n\r\nreplaced by upload\r\n--$B--\r\n";
    my $upload = sub {
        my ($u) = @_;
        return call( $u, 'file-upload', query => 'action=file-upload&path=post', raw => $mp,
            content_type => "multipart/form-data; boundary=$B" );
    };

    # SM1057: ui + read_submissions holds no manage_content, so the gate refuses first.
    refused_content_cap( call( 'rs', 'mkdir', query => 'action=mkdir&path=rsdir', body => {} ), 'mkdir' );
    ok( !-e "$d/rsdir", 'no folder was made' );
    refused_content_cap( call( 'rs', 'copy', query => 'action=copy&path=post/a.md&to=rs-copy.md', body => {} ),
        'a copy to a path the rule does not let it write' );
    ok( !-e "$d/rs-copy.md", 'no copy was made' );
    my $r = $upload->('rs');
    refused_content_cap( $r, 'an upload over a file the rule does not let it write' );
    is( scalar @{ $r->{saved} || [] }, 0, 'and saves nothing' ) or diag( explain $r );
    is( slurp("$d/post/a.md"), $POST, 'the file is as its author left it' );

    # The twin with manage_content passes the gate; the rule refuses each write.
    refused_write( call( 'rsw', 'mkdir', query => 'action=mkdir&path=rsdir', body => {} ), 'mkdir' );
    ok( !-e "$d/rsdir", 'no folder was made' );
    refused_write( call( 'rsw', 'copy', query => 'action=copy&path=post/a.md&to=rs-copy.md', body => {} ),
        'a copy to a path the rule does not let it write' );
    ok( !-e "$d/rs-copy.md", 'no copy was made' );
    $r = $upload->('rsw');
    is( scalar @{ $r->{saved} || [] }, 0, 'an upload over a file the rule does not let it write saves nothing' )
        or diag( explain $r );
    like( ( $r->{errors} || [ {} ] )->[0]{error} // '', qr/write access/, 'and says why, per file' );
    is( slurp("$d/post/a.md"), $POST, 'the file is as its author left it' );

    my $own = save( 'GeekRuthie', 'mine.md' );
    ok( $own->{ok}, 'the canary: an author writes at the root' ) or diag( explain $own );
    refused_write( call( 'GeekRuthie', 'move', query => 'action=move&path=mine.md&to=editors-only/mine.md', body => {} ),
        'a move into a folder whose rule names somebody else' );
    ok( -e "$d/mine.md" && !-e "$d/editors-only/mine.md", 'and it stayed where it was' );
    refused_write( call( 'GeekRuthie', 'copy', query => 'action=copy&path=mine.md&to=editors-only/copy.md', body => {} ),
        'a copy into that folder' );
    ok( !-e "$d/editors-only/copy.md", 'and no copy was made' );
};

subtest 'whoever a rule names still writes' => sub {
    my $r = save( 'boss', 'new-boss.md' );
    ok( $r->{ok}, 'a sysop the root rule names (@sysops) makes a page' ) or diag( explain $r );
    $r = save( 'boss', 'post/a.md', "---\ntitle: A\n---\nedited by a sysop\n" );
    ok( $r->{ok}, 'and edits a post whose rule names @sysops' ) or diag( explain $r );
    $r = save( 'GeekRuthie', 'post/a.md', $POST );
    ok( $r->{ok}, 'the post\'s owner writes it' ) or diag( explain $r );
    is( slurp("$d/post/a.md"), $POST, 'and the file holds what she wrote' );
    $r = call( 'GeekRuthie', 'mkdir', query => 'action=mkdir&path=drafts-of-mine', body => {} );
    ok( $r->{ok} && -d "$d/drafts-of-mine", 'an author makes a folder where the rule names her group' );
};

# --- (b) approve_accounts ----------------------------------------------------

make_path("$d/lazysite/forms");
my $SECRET = 'test-secret-approve-124';
spit( "$d/lazysite/forms/.secret", "$SECRET\n" );
spit( "$d/lazysite/forms/handlers.conf", "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n    path: lazysite/forms/submissions\n" );
spit( "$d/lazysite/forms/register.conf", "targets:\n  - handler: jsonl\naccount_email: email\n" );
spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: jsonl\n" );

my $ip = 0;
sub post {
    my ( $form, %f ) = @_;
    $ip++;
    my $ts   = time() - 10;
    my $body = join '&', map { "$_->[0]=$_->[1]" } (
        [ _form => $form ], [ _ts => $ts ], [ _tk => hmac_sha256_hex( $ts, $SECRET ) ],
        [ _hp   => '' ],    map { [ $_ => $f{$_} ] } sort keys %f );
    spit( "$d/post.txt", $body );
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = length $body;
    local $ENV{DOCUMENT_ROOT}  = $d;
    local $ENV{REMOTE_ADDR}    = "10.8.$ip.1";
    local $ENV{HTTP_ACCEPT}    = 'application/json';
    qx($^X \Q$PLUGIN\E < \Q$d/post.txt\E 2>/dev/null);
    return;
}
sub accounts {
    open my $fh, '<', "$d/lazysite/auth/users" or return ();
    my @u = map { ( split /:/ )[0] } grep { /\S/ } <$fh>;
    close $fh;
    return sort @u;
}
post( 'register', name => 'Ada', email => 'ada@example.org' );
post( 'register', name => 'Bea', email => 'bea@example.org' );
post( 'contact',  name => 'Cy',  email => 'cy@example.org', message => 'private+note' );
my $REG = 'lazysite/forms/submissions/register.jsonl';
my $CON = 'lazysite/forms/submissions/contact.jsonl';
ok( -s "$d/$REG" && -s "$d/$CON", 'the canary: the real handler stored both forms' )
    or BAIL_OUT('the form handler did not store the fixture');

sub rows_of { my ( $u, $q ) = @_; return call( $u, 'form-submissions', query => "action=form-submissions&$q" ) }

subtest 'approve_accounts alone approves an account request' => sub {
    my $l = rows_of( 'door', "file=$REG" );
    ok( $l->{ok} && @{ $l->{rows} || [] } == 2, 'it reads the account requests' ) or diag( explain $l );
    my ($ada) = grep { ( $_->{email} // '' ) eq 'ada@example.org' } @{ $l->{rows} || [] };
    my $one = call( 'door', 'form-submission', query => "action=form-submission&file=$REG&id=$ada->{_id}" );
    ok( $one->{ok}, 'one request, by id, is readable too (the notice link)' ) or diag( explain $one );
    my $r = call( 'door', 'form-submission-approve', body => { file => $REG, id => $ada->{_id} } );
    ok( $r->{ok}, 'and approves one' ) or diag( explain $r );
    is( $r->{user}, 'ada', 'into the account the address makes' );
    ok( ( grep { $_ eq 'ada' } accounts() ), 'which exists in the store' );
};

subtest 'and reaches nothing else' => sub {
    my $l = rows_of( 'door', "file=$CON" );
    ok( ManagerSession->refused_for_capability($l), "another form's submissions are refused" )
        or diag( explain $l );
    is( $s->last_status, 403, '403' );
    like( $l->{error} // '', qr/read_submissions/, 'naming the grant that reads every form' );
    unlike( encode($l), qr/private/, 'and nothing of the row is in the answer' );
    $l = rows_of( 'door', 'form=contact' );
    ok( ManagerSession->refused_for_capability($l), 'by form name as well' ) or diag( explain $l );
    my $one = call( 'door', 'form-submission', query => "action=form-submission&file=$CON&id=0123456789abcdef" );
    ok( ManagerSession->refused_for_capability($one), 'and one row of it' ) or diag( explain $one );

    my $fl = call( 'door', 'form-list' );
    is_deeply( [ map { $_->{name} } @{ $fl->{forms} || [] } ], ['register'],
        'form-list shows it the form that requests accounts and no other' ) or diag( explain $fl );
    my $all = call( 'rs', 'form-list' );
    is_deeply( [ sort map { $_->{name} } @{ $all->{forms} || [] } ], [qw(contact register)],
        'the canary: read_submissions still lists every form' );

    my @before = accounts();
    my $r      = call( 'door', 'users', query => 'action=users',
        body => { action => 'account-approve', username => 'mallory', email => 'm@example.org' } );
    ok( !$r->{ok}, 'the Users API\'s account-approve, which takes any name, is not reached' )
        or diag( explain $r );
    is_deeply( [ accounts() ], \@before, 'and no account was made' );
    refused_content_cap( save( 'door', 'door.md' ), 'a file write' );    # SM1057
    ok( !-e "$d/door.md", 'and no file was made' );
    $r = call( 'door', 'config-set', query => 'action=config-set', body => { key => 'site_name', value => 'x' } );
    ok( ManagerSession->refused_for_capability($r), 'a capability-gated action (config-set)' )
        or diag( explain $r );
};

subtest 'a group that approved before still does' => sub {
    my $l     = rows_of( 'boss', "file=$REG" );
    my ($bea) = grep { ( $_->{email} // '' ) eq 'bea@example.org' } @{ $l->{rows} || [] };
    my $r = call( 'boss', 'form-submission-approve', body => { file => $REG, id => $bea->{_id} } );
    ok( $r->{ok}, 'manage_users + read_submissions approves, as it did' ) or diag( explain $r );
    $r = rows_of( 'boss', "file=$CON" );
    ok( $r->{ok}, 'and reads every form' ) or diag( explain $r );
    my $none = call( 'rs', 'form-submission-approve', body => { file => $REG, id => $bea->{_id} } );
    ok( ManagerSession->refused_for_capability($none), 'read_submissions alone still approves nothing' )
        or diag( explain $none );
};

# --- (c) group-reach ---------------------------------------------------------

subtest 'group-reach says what a group can do' => sub {
    my $u = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-users.pl", '--docroot', $d;
    my $out = qx($u group-reach approvers 2>&1);
    # SM991: manage_users is no longer the operator; group-reach says what it is.
    like( $out, qr/manage_users: user and group management only/,
        'manage_users is reported as user and group management, not the operator' ) or diag($out);
    like( $out, qr/files\s+by rule/,        'and its files as decided by the rules' );
    like( $out, qr/write named in 0 rules/, 'naming none for this group' );
    like( $out, qr/a site-wide write rule governs every path here/, 'and the site-wide rule' );

    $out = qx($u group-reach authors 2>&1);
    like( $out, qr{write named in 2 rules: / \(site-wide\), members}, 'a group the rules name is listed by path' )
        or diag($out);
    like( $out, qr{read\s+named in 1 rule: members}, 'read rules as well' );
    unlike( $out, qr/operator:/, 'and a group without manage_users is no operator' );

    $out = qx($u group-reach doorkeepers 2>&1);
    like( $out, qr/approve_accounts/, 'the new grant is held and named' ) or diag($out);
    like( $out, qr/Approve \(an account\)/, 'with what it unlocks' );
};

sub encode { return JSON::PP->new->canonical->encode( $_[0] ) }

done_testing();
