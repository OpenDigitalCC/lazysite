#!/usr/bin/perl
# SM991 (ruled 2026-10-12, "Operators bypass, others bound"): the OPERATOR is a
# member of the operator group, and manage_users is user and group management.
#
# Reported beside SM979: a session holding only manage_users passed every
# capability gate on the manager - config-set answered 200 - because
# Acl::_is_operator answered yes for any manage_users holder. Ruled: manage_users
# grants user and group management only; an explicit operator group passes
# every capability gate and every file rule; everyone else is bound.
#
# The operator group is the group carrying the `manager` flag - the one
# setup-sysop makes (sysops, "Site operator"). THE UPGRADE: the store below,
# after __DATA__, is the bytes main's own `setup-sysop --user boss` wrote
# (b5ab1ce4, run from `git archive main`, tmp/sec-evidence/sm991-upgrade-fixture.out). Nothing
# migrates it; the account the bootstrap made is the operator on the new code.
#
# SM1057 (ruled 2026-10-12, "Require manage_content"): a content write in the
# manager needs manage_content before the file's rule is asked, so um and appr
# are refused by that gate; umw, holding manage_content too, is refused by the
# rule, which is what keeps manage_users from being the operator for files.
#
# Every refusal is read back from the docroot and the conf, not only the reply.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
my $s    = new_site( root => $root );
my $d    = $s->docroot;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

# The 0.15.x store, as the bootstrap wrote it.
my %file;
{
    local $/;
    my $all = <DATA>;
    while ( $all =~ /^=== (\S+)\n(.*?)(?=^=== |\z)/msg ) { $file{$1} = $2 }
}
ok( $file{'groups-settings.json'} && $file{groups}, 'the fixture holds the bootstrap\'s two group stores' );
spit( "$d/lazysite/auth/groups-settings.json", $file{'groups-settings.json'} );
spit( "$d/lazysite/auth/groups",               $file{groups} );
chmod 0660, "$d/lazysite/auth/groups-settings.json", "$d/lazysite/auth/groups";

$s->add_user('boss');     # the account setup-sysop made, already in sysops
$s->add_user('um');       # the shipped user-managers role: manage_users
$s->users( 'group-add', 'um', 'user-managers' );
$s->add_user('appr');     # a group made to approve: ui + manage_users only
$s->users( 'group-add', 'appr', 'approvers' );
$s->users( 'group-set', 'approvers', $_, 'on' ) for qw(ui manage_users);
$s->add_user('GeekRuthie');
$s->users( 'group-add', 'GeekRuthie', 'content-editors' );
$s->add_user('other');    # an account nobody here created

sub acl {
    my $cmd = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-acl.pl", @_,
        '--docroot', $d, '--actor', 'local';
    qx($cmd 2>&1);
    return $? >> 8;
}
make_path("$d/post");
my $POST = "---\ntitle: A\n---\nthe author's text\n";
spit( "$d/post/a.md", $POST );
is( acl( 'set', '/', '--write', 'GeekRuthie' ), 0, 'the site-wide rule names one author and no group' );
is( acl( 'set', 'post/a.md', '--owner', 'GeekRuthie', '--write', 'GeekRuthie' ), 0, 'the post has a rule its author owns' );

sub call { my ( $u, $act, %o ) = @_; return $s->call( $u, $act, groups => 1, %o ) }
sub save {
    my ( $u, $p, $c ) = @_;
    return call( $u, 'save', query => "action=save&path=$p", body => { content => $c } );
}
sub config_set {
    my ( $u, $v ) = @_;
    return call( $u, 'config-set', query => 'action=config-set', body => { key => 'site_name', value => $v } );
}
sub conf_has { my ($v) = @_; return ( slurp("$d/lazysite/lazysite.conf") // '' ) =~ /^site_name:\s*\Q$v\E\s*$/m ? 1 : 0 }

subtest 'the upgrade: the group the bootstrap made is the operator group' => sub {
    my $gs = JSON::PP::decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    ok( $gs->{sysops}{manager}, 'sysops carries the flag the bootstrap wrote' );
    my $r = config_set( 'boss', 'Upgraded' );
    ok( $r->{ok}, 'its member passes a capability gate (config-set)' ) or diag( explain $r );
    ok( conf_has('Upgraded'), 'and the conf says so' );
    $r = save( 'boss', 'by-boss.md', "---\ntitle: B\n---\nb\n" );
    ok( $r->{ok}, 'and writes a file whose rule does not name it' ) or diag( explain $r );
    ok( -f "$d/by-boss.md", 'the file is there' );
    $r = save( 'boss', 'post/a.md', "---\ntitle: A\n---\nedited by the operator\n" );
    ok( $r->{ok} && slurp("$d/post/a.md") =~ /edited by the operator/, "and overwrites an author's post" )
        or diag( explain $r );
    spit( "$d/post/a.md", $POST );
};

subtest 'the operator passes a gate its own group has switched off' => sub {
    $s->users( 'group-set', 'sysops', 'manage_config', 'off' );
    my $r = config_set( 'boss', 'Still' );
    ok( $r->{ok} && conf_has('Still'), 'config-set: the operator is not asked for the capability' )
        or diag( explain $r );
    $r = $s->call( 'boss', 'config-set', groups => '', query => 'action=config-set',
        body => { key => 'site_name', value => 'StoreOnly' } );
    ok( $r->{ok} && conf_has('StoreOnly'), 'the store says so with no groups header in play' )
        or diag( explain $r );
    $s->users( 'group-set', 'sysops', 'manage_config', 'on' );
};

for my $who (qw(um appr)) {
    subtest "the reported case: manage_users alone ($who) is user and group management" => sub {
        my $r = config_set( $who, "By $who" );
        ok( ManagerSession->refused_for_capability($r), 'config-set is refused for the capability' )
            or diag( explain $r );
        is( $s->last_status, 403, 'answers 403' );
        ok( !conf_has("By $who"), 'and the conf is unchanged' );

        # SM1057: it holds no manage_content, so the content-write gate refuses
        # before the file's rule; the rule is asked below for a holder that has it.
        $r = save( $who, "by-$who.md", "---\ntitle: X\n---\nx\n" );
        ok( ManagerSession->refused_for_capability($r) && ( $r->{error} // '' ) =~ /manage_content/,
            'a write is refused for manage_content' )
            or diag( explain $r );
        ok( !-e "$d/by-$who.md", 'and no file was made' );
        $r = save( $who, 'post/a.md', "overwritten\n" );
        ok( !$r->{ok}, "another author's post is not overwritten" );
        is( slurp("$d/post/a.md"), $POST, 'it is as its author left it' );

        $r = call( $who, 'acl-get', query => 'action=acl-get&path=post/a.md' );
        ok( $r->{ok} && ( $r->{acl}{owner} // '' ) eq 'GeekRuthie', "and reads another owner's rule (SM464, kept by name)" )
            or diag( explain $r );

        $r = call( $who, 'users', query => 'action=users', body => { action => 'claim-create', username => 'other' } );
        ok( $r->{ok} && ( $r->{claim} // '' ) =~ /^lzc_/,
            'it still manages an account it did not create (a setup link)' ) or diag( explain $r );
    };
}

# SM1057: manage_users with manage_content passes the content-write gate; it is
# still no operator, so the file's rule binds it.
$s->add_user('umw');
$s->users( 'group-add', 'umw', 'user-managers-who-write' );
$s->users( 'group-set', 'user-managers-who-write', $_, 'on' ) for qw(ui manage_users manage_content);
subtest 'manage_users with manage_content is bound by the file rule' => sub {
    my $r = save( 'umw', 'by-umw.md', "---\ntitle: X\n---\nx\n" );
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'permission', 'a write outside its rules is refused' )
        or diag( explain $r );
    is( $s->last_status, 403, 'answers 403' );
    ok( !-e "$d/by-umw.md", 'and no file was made' );
    $r = save( 'umw', 'post/a.md', "overwritten\n" );
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'permission', "another author's post is not overwritten" )
        or diag( explain $r );
    is( slurp("$d/post/a.md"), $POST, 'it is as its author left it' );
};

subtest 'nor does manage_users make itself the operator' => sub {
    my %try = (
        'join the operator group' => { action => 'group-add', username => 'um', group => 'sysops' },
        'reset the operator\'s password' => { action => 'passwd', username => 'boss', password => 'taken-over-1' },
        'mint the operator a setup link' => { action => 'claim-create', username => 'boss' },
        'mint the operator a credential' => { action => 'token', username => 'boss' },
        'take the operator out of it' => { action => 'group-remove', username => 'boss', group => 'sysops' },
        'unflag the operator group' => { action => 'group-settings-set', group => 'sysops', key => 'manager', value => 'off' },
        'nest its own group in it' => { action => 'group-nest', sub => 'user-managers', parent => 'sysops' },
    );
    my $before = slurp("$d/lazysite/auth/users");
    for my $what ( sort keys %try ) {
        my $r = call( 'um', 'users', query => 'action=users', body => $try{$what} );
        ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'forbidden', "$what: refused" ) or diag( explain $r );
    }
    is( slurp("$d/lazysite/auth/users"), $before, 'no credential changed' );
    my %g = map { /^([^:]+):\s*(.*)$/ ? ( $1 => $2 ) : () } split /\n/, slurp("$d/lazysite/auth/groups");
    is( $g{sysops}, 'boss', 'the operator group holds the operator and nobody else' );
    my $gs = JSON::PP::decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    ok( $gs->{sysops}{manager}, 'and keeps its flag' );
    my $r = config_set( 'um', 'After' );
    ok( ManagerSession->refused_for_capability($r), 'and um is still refused config-set' );
};

subtest 'the operator still changes the operator group' => sub {
    my $r = call( 'boss', 'users', query => 'action=users',
        body => { action => 'claim-create', username => 'boss' } );
    ok( $r->{ok}, 'the operator mints its own setup link' ) or diag( explain $r );
};

subtest 'group-reach names the operator group and what manage_users grants' => sub {
    my $u = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-users.pl", '--docroot', $d;
    my $out = qx($u group-reach sysops 2>&1);
    like( $out, qr/this group is the OPERATOR group/, 'sysops is reported as the operator group' ) or diag($out);
    $out = qx($u group-reach approvers 2>&1);
    like( $out, qr/manage_users: user and group management only/, 'manage_users is reported as what it is' )
        or diag($out);
    like( $out, qr/operator group: sysops/, 'and the operator group is named' );
    unlike( $out, qr/this group is the OPERATOR/, 'approvers is not it' );
};

done_testing();

__DATA__
=== groups-settings.json
{
   "agent-ai" : {
      "assignable" : 1,
      "description" : "An AI assistant that builds and maintains the site: content, navigation, forms, themes and layouts, over MCP and the control API.",
      "label" : "Web developer (AI agent)",
      "seeded" : 1
   },
   "analysts" : {
      "assignable" : 1,
      "description" : "Reads analytics and the audit trail. Changes nothing.",
      "label" : "Analyst",
      "seeded" : 1
   },
   "app-developers" : {
      "assignable" : 1,
      "description" : "An AI assistant building data-backed apps over MCP: content plus typed data tables and authoring briefs.",
      "label" : "App developer (AI agent)",
      "seeded" : 1
   },
   "cap-analytics" : {
      "analytics" : 1,
      "assignable" : 0,
      "description" : "Sanitised, IP-anonymised visitor analytics, including which signed-in accounts visited.",
      "label" : "Capability: analytics",
      "seeded" : 1
   },
   "cap-audit" : {
      "assignable" : 0,
      "audit" : 1,
      "description" : "The append-only audit trail. INSTANCE-WIDE and NOT scoped by the grant reading it: entries name the actor and carry a raw source IP, the sysop's own sessions among them (SM618).",
      "label" : "Capability: audit trail",
      "seeded" : 1
   },
   "cap-audit-switch" : {
      "assignable" : 0,
      "audit_switch" : 1,
      "description" : "Switch the audit trail off and on. Needs Site config as well. Every switch is itself recorded, and no role holds this by default.",
      "label" : "Capability: audit trail switch",
      "seeded" : 1
   },
   "cap-content" : {
      "assignable" : 0,
      "description" : "Pages, navigation and forms. The everyday authoring set.",
      "label" : "Capability: content",
      "manage_content" : 1,
      "manage_forms" : 1,
      "manage_nav" : 1,
      "seeded" : 1
   },
   "cap-data" : {
      "assignable" : 0,
      "description" : "Typed data tables and authoring briefs - the app-building set.",
      "label" : "Capability: data",
      "manage_briefs" : 1,
      "manage_data" : 1,
      "seeded" : 1
   },
   "cap-design" : {
      "assignable" : 0,
      "description" : "Themes and layouts - how the site looks, site-wide.",
      "label" : "Capability: design",
      "manage_layouts" : 1,
      "manage_themes" : 1,
      "seeded" : 1
   },
   "cap-people" : {
      "assignable" : 0,
      "create_sub_users" : 1,
      "delegate_sub_user_creation" : 1,
      "description" : "Accounts, groups and sub-users, plus the operator notification bell. Hands over who may do anything at all.",
      "label" : "Capability: people",
      "manage_users" : 1,
      "notifications" : 1,
      "seeded" : 1
   },
   "cap-services" : {
      "assignable" : 0,
      "description" : "The WebDAV, MCP, OAuth, control-API and token-exchange switches. Decides whether the remote surfaces answer at all, for everyone already connected.",
      "label" : "Capability: services",
      "manage_services" : 1,
      "seeded" : 1
   },
   "cap-site" : {
      "assignable" : 0,
      "description" : "Domains, site packages, configuration and plugins. Changes what the whole site is, not what is on it.",
      "label" : "Capability: site settings",
      "manage_config" : 1,
      "manage_domains" : 1,
      "seeded" : 1
   },
   "cap-tidy" : {
      "assignable" : 0,
      "description" : "Clearing away what is recoverable. `purge` is deliberately NOT here: destroying the last copy is a separate decision (SM587/SM591).",
      "housekeeping" : 1,
      "label" : "Capability: housekeeping",
      "seeded" : 1
   },
   "ch-agent" : {
      "assignable" : 0,
      "description" : "MCP - the self-describing tool surface an AI assistant connects to. Carries the authoring verbs (create_page, rename_page, validate_page) that the control API does not.",
      "label" : "Channel: AI agent",
      "mcp" : 1,
      "seeded" : 1
   },
   "ch-files" : {
      "assignable" : 0,
      "description" : "WebDAV - direct file access to the content tree.",
      "label" : "Channel: file access",
      "seeded" : 1,
      "webdav" : 1
   },
   "ch-script" : {
      "api" : 1,
      "assignable" : 0,
      "description" : "The control API and WebDAV - for scripts and pipelines. Read, history, ACLs and registries; no authoring verbs.",
      "label" : "Channel: scripts",
      "seeded" : 1,
      "webdav" : 1
   },
   "ch-ui" : {
      "assignable" : 0,
      "description" : "The manager web interface - for a person at a keyboard.",
      "label" : "Channel: manager UI",
      "seeded" : 1,
      "ui" : 1
   },
   "content-editors" : {
      "assignable" : 1,
      "description" : "Writes and edits pages, navigation and forms, in the manager. Cannot change how the site looks or who may use it.",
      "label" : "Website editor",
      "seeded" : 1
   },
   "design-team" : {
      "assignable" : 1,
      "description" : "Themes and layouts, in the manager. Cannot edit content.",
      "label" : "Designer",
      "seeded" : 1
   },
   "lead-readers" : {
      "assignable" : 1,
      "description" : "Reads form submissions over the API and nothing else - the least-privilege grant for processing enquiries.",
      "label" : "Lead reader",
      "read_submissions" : 1,
      "seeded" : 1
   },
   "mcp-ai" : {
      "assignable" : 1,
      "description" : "The same work as the web developer role, over MCP alone - for a partner that should hold no control-API access.",
      "label" : "Web developer (MCP only)",
      "seeded" : 1
   },
   "members" : {
      "assignable" : 1,
      "description" : "An example organisational group, shipped so a new site has one to look at. It grants nothing on its own. Rename it, re-use it, or delete it.",
      "label" : "Site members",
      "seeded" : 1
   },
   "site-admins" : {
      "assignable" : 1,
      "description" : "Runs the site day to day: content, design, settings and housekeeping, in the manager. Not people, and not purge.",
      "label" : "Site administrator",
      "seeded" : 1
   },
   "sysops" : {
      "analytics" : 1,
      "assignable" : 1,
      "audit" : 1,
      "audit_switch" : 1,
      "create_sub_users" : 1,
      "delegate_sub_user_creation" : 1,
      "delete_submissions" : 1,
      "description" : "The site owner. Holds every capability except the remote api/mcp channels (manager groups are interactive-only), and may CONFER any capability - including the ones it does not hold - so narrowing what it holds never costs it the ability to delegate.",
      "feedback" : 1,
      "grantable" : [
         "analytics",
         "api",
         "audit",
         "audit_switch",
         "create_sub_users",
         "delegate_sub_user_creation",
         "delete_submissions",
         "feedback",
         "housekeeping",
         "manage_briefs",
         "manage_config",
         "manage_connectors",
         "manage_content",
         "manage_data",
         "manage_domains",
         "manage_forms",
         "manage_layouts",
         "manage_nav",
         "manage_services",
         "manage_themes",
         "manage_users",
         "mcp",
         "notifications",
         "purge",
         "read_submissions",
         "run_jobs",
         "ui",
         "webdav",
         "write_data"
      ],
      "housekeeping" : 1,
      "label" : "Site operator",
      "manage_briefs" : 1,
      "manage_config" : 1,
      "manage_connectors" : 1,
      "manage_content" : 1,
      "manage_data" : 1,
      "manage_domains" : 1,
      "manage_forms" : 1,
      "manage_layouts" : 1,
      "manage_nav" : 1,
      "manage_services" : 1,
      "manage_themes" : 1,
      "manage_users" : 1,
      "manager" : 1,
      "notifications" : 1,
      "purge" : 1,
      "read_submissions" : 1,
      "run_jobs" : 1,
      "seeded" : 1,
      "ui" : 1,
      "webdav" : 1,
      "write_data" : 1
   },
   "user-managers" : {
      "assignable" : 1,
      "description" : "Manages accounts and groups in the manager. Holds no content or design capability of its own.",
      "label" : "User manager",
      "seeded" : 1
   }
}
=== groups
cap-analytics: analysts, agent-ai, mcp-ai
cap-audit: analysts
cap-content: content-editors, agent-ai, mcp-ai, app-developers, site-admins
cap-data: app-developers
cap-design: design-team, agent-ai, mcp-ai, site-admins
cap-people: user-managers
cap-services: site-admins
cap-site: site-admins
cap-tidy: site-admins
ch-agent: agent-ai, mcp-ai, app-developers
ch-files: content-editors, design-team, site-admins
ch-script: agent-ai, lead-readers
ch-ui: content-editors, design-team, site-admins, user-managers, analysts
sysops: boss
