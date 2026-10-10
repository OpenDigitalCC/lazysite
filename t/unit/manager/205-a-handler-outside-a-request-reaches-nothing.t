#!/usr/bin/perl
# SM944 S21: the manager request context is fail-closed until a request sets it.
#
# The facts a manager-API request establishes about itself live in
# Lazysite::Manager::Common, so an area module reads them wherever it is loaded:
# in the manager API, which sets them, and in the daemon, MCP, WebDAV or a test,
# which never do. Before the context was shared it was the script's own `my`
# variables and nothing else could reach them; once shared, the value a reader
# sees before anything set it is a decision. An empty scope set means
# UNCONFINED to every reader, so "empty" would have handed a handler loaded
# outside a request the sysop's reach. This file is a plain perl process that
# never runs the script: what it sees is what any other loader sees.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(outside_all_scopes reset_request_context NO_REQUEST_CONTEXT _user_caps
    $auth_user $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR $action $path $body
    %USER_CAPS $REQUEST_IP);

my @PATHS = ( '', '/', 'index.md', 'sites/clienta/index.md', 'lazysite/auth/users', 'no request context',
    'sites', '/sites/clienta/' );

sub fail_closed {
    my ($when) = @_;
    is( $auth_user, '', "$when: nobody is asking" );
    ok( $token_auth, "$when: a token client, so never the cookie session that is the operator" );
    is_deeply( [ grep { $_ ne 'dav_scopes' } keys %token_caps ], [], "$when: the token holds no capability" );
    ok( scalar @REQUEST_SCOPES, "$when: the scope set is not empty (empty means unconfined)" );
    is_deeply( [ grep { !outside_all_scopes( \@REQUEST_SCOPES, $_ ) } @PATHS ], [],
        "$when: every path is outside the request's scopes" );
    is_deeply( [ grep { !outside_all_scopes( $token_caps{dav_scopes}, $_ ) } @PATHS ], [],
        "$when: and outside the token's own" );
    ok( $REQUEST_CONFINED, "$when: confined" );
    ok( defined $IS_OPERATOR && !$IS_OPERATOR, "$when: not the operator, and the memo is filled so nothing asks again" );
    is( $action, '',    "$when: no action" );
    is( $path,   undef, "$when: no path" );
    is( $body,   '',    "$when: no body" );
    is_deeply( \%USER_CAPS,            {}, "$when: no account's caps remembered (S22b)" );
    is_deeply( _user_caps($auth_user), {}, "$when: the request's user holds no capability" );
    is( $REQUEST_IP, undef, "$when: no visitor's address remembered (S31)" );
}

fail_closed('loaded, never set');
is( index( NO_REQUEST_CONTEXT(), "\0" ) >= 0, 1, 'the no-context scope holds a NUL, which no path or root can' );

# What the manager API sets for an operator request; then the reset it runs
# before its auth check, as a process that served one request would.
$auth_user        = 'boss';
$token_auth       = 0;
%token_caps       = ( manage_users => 1, dav_scopes => [] );
@REQUEST_SCOPES   = ();
$REQUEST_CONFINED = 0;
$IS_OPERATOR      = 1;
$action           = 'acl-set';
$path             = 'secret/page.md';
$body             = '{"read":["@everyone"]}';
%USER_CAPS        = ( boss => { manage_users => 1, ui => 1 } );
$REQUEST_IP       = '203.0.113.7';
reset_request_context();
fail_closed('after a request, reset');

# The modules long-lived processes load leave it as it is.
require Lazysite::Handlers;
require Lazysite::Manager::Files;
require Lazysite::Manager::Domains;
fail_closed('after loading the daemon\'s handlers and two manager modules');

# SM944 S22: a real handler. The remap actions read the context from Common;
# loaded here, with a site that has a domain and a rule for it (made through
# the manager API, as an operator would), they refuse every host and list no
# rule - and the same calls with an operator's context see both, so it is the
# context that refuses, not the fixture.
subtest 'the remap handlers, loaded outside a request, reach no domain' => sub {
    require ManagerSession;
    require Lazysite::Manager::Remap;
    my $s   = ManagerSession::new_site( root => repo_root() );
    my @ALL = qw(ui manage_domains manage_users manage_config);
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', \@ALL, \@ALL );
    open my $cf, '>>', $s->docroot . '/lazysite/lazysite.conf' or die $!;
    print {$cf} "extensions:\n  - plugins/remap.pl\n";
    close $cf;
    my $d = $s->call( 'boss', 'domain-add',
        body => { host => 'mine.example.org', content_root => 'sites/mine',
            site_url => 'https://mine.example.org', site_name => 'mine' } );
    ok( $d->{ok}, 'set up a domain' ) or diag( $d->{error} // '' );
    my $w = $s->call( 'boss', 'remap-save',
        body => { host => 'mine.example.org', rules => [ { prefix => '/web', destination => 'https://b.example.com' } ] } );
    ok( $w->{ok}, '...and a rule for it' ) or diag( $w->{error} // '' );

    no warnings 'once';
    $Lazysite::Manager::Remap::DOCROOT = $s->docroot; # what an entry point that loads it would set:
    $Lazysite::Manager::Plugins::DOCROOT = $s->docroot; # where the site is - never who is asking
    $Lazysite::Manager::Domains::DOCROOT = $s->docroot;
    $Lazysite::Manager::Common::DOCROOT  = $s->docroot;
    my $rule = [ { prefix => '/x', destination => 'https://elsewhere.example.com' } ];

    my $l = Lazysite::Manager::Remap::_remap_list();
    is_deeply( $l->{rules}, [], 'remap-list lists no rule' ) or diag explain $l;
    my $r = Lazysite::Manager::Remap::_remap_save( { host => 'mine.example.org', rules => $rule } );
    is( $r->{kind} // '', 'forbidden', 'remap-save refuses the registered domain' ) or diag explain $r;
    $r = Lazysite::Manager::Remap::_remap_save( { host => 'unregistered.example.net', rules => $rule } );
    is( $r->{kind} // '', 'forbidden', '...and an unregistered host' ) or diag explain $r;

    # The operator's context, as the script sets it.
    $token_auth     = 0;
    %token_caps     = ();
    @REQUEST_SCOPES = ();
    $l              = Lazysite::Manager::Remap::_remap_list();
    is( scalar @{ $l->{rules} || [] }, 1, 'with an operator\'s context the same call lists the rule' );
    reset_request_context();
    is_deeply( Lazysite::Manager::Remap::_remap_list()->{rules}, [], '...and reset, none again' );
};

# SM944 S22b: the users-tool client and the caps memo, moved into Common. Loaded
# here they still reach the users tool (the client is not identity-gated: it
# answers what it is asked), the request's user - nobody - holds no capability,
# and a caps answer the memo kept for one request is gone after the reset, so
# a pooled worker re-reads the account store for the next.
subtest 'the caps memo, loaded outside a request, answers nothing and is emptied by the reset' => sub {
    require ManagerSession;
    my $s = ManagerSession::new_site( root => repo_root() );
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', [qw(ui manage_users)], [qw(ui manage_users)] );
    no warnings 'once';
    local $Lazysite::Manager::Common::DOCROOT = $s->docroot;
    local $ENV{LAZYSITE_USERS_TOOL} = repo_root() . '/tools/lazysite-users.pl';
    is_deeply( _user_caps($auth_user), {}, 'the request\'s user, nobody, holds no capability' );
    is_deeply( \%USER_CAPS,            {}, '...and asking remembers nothing' );
    my $caps = _user_caps('boss');
    ok( $caps->{manage_users}, 'a named account\'s caps come from the users tool through the moved client' )
        or diag explain $caps;
    ok( exists $USER_CAPS{boss}, '...and are remembered for the rest of the request' );
    reset_request_context();
    is_deeply( \%USER_CAPS, {}, 'the reset forgets them' );
};

# SM944 S23: the notices gate and the start-page actions, moved into Notices and
# StartPage. Outside a request the gate refuses (a token client holding nothing
# - it used to pass every token) and the start page has no subject (nobody - it
# used to answer for account ''), so neither reads nor writes; with a request's
# context set they answer, and after the reset they refuse again.
subtest 'the notices gate and the start-page actions, loaded outside a request, refuse' => sub {
    require ManagerSession;
    require Lazysite::Manager::Notices;
    require Lazysite::Manager::StartPage;
    my $s = ManagerSession::new_site( root => repo_root() );
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', [qw(ui manage_users notifications)], [qw(ui manage_users notifications)] );
    no warnings 'once';
    local $Lazysite::Manager::Common::DOCROOT    = $s->docroot;
    local $Lazysite::Manager::StartPage::DOCROOT = $s->docroot;
    local $Lazysite::Manager::Notices::DOCROOT   = $s->docroot;
    local $ENV{LAZYSITE_USERS_TOOL} = repo_root() . '/tools/lazysite-users.pl';

    my $g = Lazysite::Manager::Notices::_notices_gate();
    is( $g->{kind} // '', 'forbidden', 'the notices gate refuses' ) or diag explain $g;
    my $r = Lazysite::Manager::StartPage::action_start_page(undef);
    is( $r->{kind} // '', 'forbidden', 'start-page refuses: no account is asking' ) or diag explain $r;
    $r = Lazysite::Manager::StartPage::action_start_page('boss');
    is( $r->{kind} // '', 'forbidden', '...and for a named account, which needs manage_users' );
    $r = Lazysite::Manager::StartPage::action_start_page_set( undef, 'manager:files' );
    is( $r->{kind} // '', 'forbidden', 'start-page-set refuses' );
    $r = Lazysite::Manager::StartPage::action_start_page_set( 'boss', 'manager:files' );
    is( $r->{kind} // '', 'forbidden', '...for a named account too' );
    is( ( ManagerSession::call( $s, 'boss', 'start-page' ) || {} )->{current}, '', 'and nothing was set' );

    # boss's own request, as the script sets it for a cookie session.
    $auth_user  = 'boss';
    $token_auth = 0;
    %token_caps = ();
    ok( !defined Lazysite::Manager::Notices::_notices_gate(), 'with boss\'s context the gate passes' );
    $r = Lazysite::Manager::StartPage::action_start_page(undef);
    ok( $r->{ok} && $r->{username} eq 'boss', '...and start-page answers for boss' ) or diag explain $r;
    # A token holding notifications, as the dispatcher lets through.
    $token_auth = 1;
    %token_caps = ( notifications => 1 );
    ok( !defined Lazysite::Manager::Notices::_notices_gate(), 'a token holding notifications passes' );
    reset_request_context();
    is( ( Lazysite::Manager::Notices::_notices_gate() || {} )->{kind} // '', 'forbidden', 'reset: the gate refuses again' );
    is( Lazysite::Manager::StartPage::action_start_page(undef)->{kind} // '', 'forbidden', '...and start-page' );
};

# SM944 S24: the preview verbs, moved into Manager::Preview after the ruled (b)
# and (c). Outside a request preview-grant minted a signed cookie for account ''
# and, on a site with no auth secret, created one; preview shelled the processor
# for any path. Now both refuse, minting, creating and running nothing; (d)
# preview-clear is unchanged - it only expires the caller's own cookies. With a
# request's context set they answer, and after the reset they refuse again.
subtest 'the preview verbs, loaded outside a request, act for nobody' => sub {
    require Lazysite::Manager::Preview;
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    require File::Path;
    File::Path::make_path( "$d/lazysite/layouts/plain", "$d/cgi" );
    my $spit = sub { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh };
    $spit->( "$d/lazysite/layouts/plain/layout.tt", "x\n" );
    # A stand-in processor that leaves a mark when it is run.
    $spit->( "$d/cgi/lazysite-processor.pl", "open my \$m, '>', '$d/ran' or die; close \$m;\n"
            . "print qq(Status: 200 OK\\r\\nContent-Type: text/html\\r\\n\\r\\nRENDERED);\n" );
    local $ENV{LAZYSITE_PROCESSOR}           = "$d/cgi/lazysite-processor.pl";
    local $ENV{LAZYSITE_LOG_LEVEL}           = 'ERROR';
    local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
    no warnings 'once';
    local $Lazysite::Manager::Preview::DOCROOT      = $d;    # what the dispatcher sets
    local $Lazysite::Manager::Preview::LAZYSITE_DIR = "$d/lazysite";

    # What a call prints, as the CGI would send it.
    my $printed = sub {
        my ($code) = @_;
        my $buf = '';
        open my $save, '>&', \*STDOUT or die $!;
        close STDOUT;
        open STDOUT, '>', \$buf or die $!;
        $code->();
        close STDOUT;
        open STDOUT, '>&', $save or die $!;
        return $buf;
    };
    my $grant = sub { Lazysite::Manager::Preview::action_preview_grant( { layout => 'plain', theme => '' } ) };
    my $preview = sub { Lazysite::Manager::Preview::action_preview('/index.md') };

    my $out = $printed->($grant);
    like( $out, qr/^Status: 403 Forbidden/, 'preview-grant refuses' );
    like( $out, qr/no account is asking/,   '...saying why' );
    unlike( $out, qr/Set-Cookie/, '...and mints no cookie' );
    ok( !-e "$d/lazysite/auth/.secret", '...and creates no auth secret on a site that has none' );
    my $r = $preview->();
    is( $r->{kind} // '', 'forbidden', 'preview refuses' ) or diag explain $r;
    ok( !-e "$d/ran", '...and runs no processor' );
    $out = $printed->( \&Lazysite::Manager::Preview::action_preview_clear );
    like( $out, qr/^Status: 200 OK.*Set-Cookie: lzs_preview=;[^\r\n]*Max-Age=0/s,
        'preview-clear, unchanged (d), only expires the cookies' );

    # boss's own request, as the script sets it for a cookie session.
    $auth_user = 'boss';
    $out       = $printed->($grant);
    like( $out, qr/Set-Cookie: lzs_preview=v1:\d+:plain::boss:/, 'with boss\'s context the grant mints for boss' );
    is( $preview->()->{html} // '', 'RENDERED', '...and preview renders' );
    reset_request_context();
    unlink "$d/ran";
    unlike( $printed->($grant), qr/Set-Cookie/, 'reset: the grant refuses again' );
    is( $preview->()->{kind} // '', 'forbidden', '...and preview' );
    ok( !-e "$d/ran", '...running nothing' );
};

# SM944 S25: the describe area, moved into Manager::Describe after the ruled (a)
# and (b). Outside a request describe-capabilities answered ok:1 for account ''
# (the capability map, the site's docs index, every action's effects) and
# actions-list answered ok:1 with the actions a grant of nothing may call. Now
# both refuse; (d) site_capabilities is unchanged - a site fact any signed-in
# caller reads through whoami, no account, no write - and still answers. With
# an account they answer, and after the reset they refuse again.
subtest 'the describe actions, loaded outside a request, describe nothing' => sub {
    require ManagerSession;
    require Lazysite::Manager::Describe;
    my $s = ManagerSession::new_site( root => repo_root(),
        conf => "control_api_enabled: true\nplugins:\n  - plugins/form-smtp.pl\n" );
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', [qw(ui api manage_content)], [qw(ui api manage_content)] );
    no warnings 'once';
    local $Lazysite::Manager::Describe::DOCROOT = $s->docroot;  # what the dispatcher sets
    local $Lazysite::Manager::Plugins::DOCROOT  = $s->docroot;
    local $Lazysite::Manager::Common::DOCROOT   = $s->docroot;
    local $ENV{LAZYSITE_USERS_TOOL} = repo_root() . '/tools/lazysite-users.pl';
    local $ENV{LAZYSITE_LOG_LEVEL}  = 'ERROR';

    my $r = Lazysite::Manager::Describe::action_describe_capabilities($auth_user);
    is( $r->{kind} // '', 'forbidden', 'describe-capabilities refuses: no account is asking' ) or diag explain $r;
    ok( !exists $r->{docs} && !exists $r->{actions}, '...handing over no docs index and no actions' );
    $r = Lazysite::Manager::Describe::action_actions_list($auth_user);
    is( $r->{kind} // '', 'forbidden', 'actions-list refuses' ) or diag explain $r;
    ok( !exists $r->{actions}, '...listing nothing' );
    is_deeply( Lazysite::Manager::Describe::site_capabilities(), ['email-send'],
        'site_capabilities, unchanged (d), still answers the site\'s enabled plugins\' provides' );

    # boss's own request, as the dispatcher passes the account.
    $auth_user = 'boss';
    $r         = Lazysite::Manager::Describe::action_describe_capabilities($auth_user);
    ok( $r->{ok} && ( $r->{holds}{account} // '' ) eq 'boss', 'with boss\'s context the map describes boss' )
        or diag explain $r;
    $r = Lazysite::Manager::Describe::action_actions_list($auth_user);
    ok( $r->{ok} && ( $r->{account} // '' ) eq 'boss', '...and actions-list lists boss\'s actions' );
    reset_request_context();
    is( Lazysite::Manager::Describe::action_describe_capabilities($auth_user)->{kind} // '', 'forbidden',
        'reset: describe-capabilities refuses again' );
    is( Lazysite::Manager::Describe::action_actions_list($auth_user)->{kind} // '', 'forbidden', '...and actions-list' );
};

# SM944 S26: the services, version and stats area, moved into Manager::Services
# after the ruled (c). Outside a request analyse_visitors ran the stats plugin
# and returned its export with nobody asking; now it refuses and runs nothing.
# (d) version, the transports' state and channel-services are unchanged - site
# facts any signed-in caller reads, no account, no write, no tool run - and
# still answer. With an account the analysis runs, and after the reset it
# refuses again.
subtest 'the services area, loaded outside a request, runs no stats tool' => sub {
    require Lazysite::Manager::Services;
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    mkdir "$d/lazysite";
    my $spit = sub { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh };
    $spit->( "$d/lazysite/lazysite.conf", "site_name: T\ncontrol_api_enabled: true\n" );
    $spit->( "$d/lazysite/.install-state.json", '{"version":"9.8.7","installed_at":"2026-10-10"}' );
    # A stand-in stats tool that leaves a mark when it is run.
    $spit->( "$d/stats-stub.pl", "open my \$m, '>', '$d/ran' or die; close \$m;\n"
            . "print '{\"ok\":1,\"top_pages\":[{\"path\":\"/secret-campaign\",\"hits\":42}]}';\n" );
    local $ENV{LAZYSITE_STATS_TOOL} = "$d/stats-stub.pl";
    local $ENV{LAZYSITE_LOG_LEVEL}  = 'ERROR';
    no warnings 'once';
    local $Lazysite::Manager::Services::DOCROOT      = $d;    # what the dispatcher sets
    local $Lazysite::Manager::Services::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Plugins::DOCROOT       = $d;

    my $r = Lazysite::Manager::Services::action_analyse_visitors( window => 7 );
    is( $r->{kind} // '', 'forbidden', 'analyse_visitors refuses: no account is asking' ) or diag explain $r;
    ok( !exists $r->{top_pages}, '...handing over no stats' );
    ok( !-e "$d/ran",            '...and runs no stats tool' );

    # (d), unchanged: the site facts answer.
    is( Lazysite::Manager::Services::action_version()->{version} // '', '9.8.7',
        'version, unchanged (d), still answers the install\'s version' );
    my $on = Lazysite::Manager::Services::_service_state();
    ok( $on->{api} && !$on->{mcp}, '_service_state, unchanged (d), still answers which transports are on' )
        or diag explain $on;
    $r = Lazysite::Manager::Services::action_channel_services();
    ok( $r->{ok} && ref $r->{services} eq 'HASH' && ref $r->{grants} eq 'HASH',
        'channel-services, unchanged (d), still answers the switches and the capability sentences' )
        or diag explain [ sort keys %$r ];

    # boss's own request, as the script sets it.
    $auth_user = 'boss';
    $r         = Lazysite::Manager::Services::action_analyse_visitors( window => 7 );
    is( $r->{top_pages}[0]{path} // '', '/secret-campaign', 'with boss\'s context the analysis runs' )
        or diag explain $r;
    ok( -e "$d/ran", '...through the stats tool' );
    unlink "$d/ran";
    reset_request_context();
    is( Lazysite::Manager::Services::action_analyse_visitors( window => 7 )->{kind} // '', 'forbidden',
        'reset: analyse_visitors refuses again' );
    ok( !-e "$d/ran", '...running nothing' );
};

# SM944 S28: the site backup and export area, moved into Manager::SiteBackup
# after site-backup-upload took the established fail-closed pattern. Outside a
# request the upload stored a package with nobody asking; now it refuses. The
# other verbs refused already - the context's reset leaves a token confined to
# a scope no root lies in, so the domain rule (SM976) reaches nothing - and
# still do: nothing is built, read, streamed, deleted, snapshotted or applied.
# With the operator's context they answer, and after the reset they refuse
# again.
subtest 'the site backup verbs, loaded outside a request, touch no package' => sub {
    require ManagerSession;
    require Lazysite::Manager::SiteBackup;
    my $s   = ManagerSession::new_site( root => repo_root() );
    my $d   = $s->docroot;
    my @ALL = qw(ui manage_domains manage_content);
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', \@ALL, \@ALL );
    my $r = $s->call( 'boss', 'domain-add',
        body => { host => 'mine.example.org', content_root => 'sites/mine', site_name => 'mine' } );
    ok( $r->{ok}, 'set up a domain' ) or diag( $r->{error} // '' );
    $r = $s->call( 'boss', 'site-backup-create', body => { host => 'mine.example.org' } );
    my $pkg = $r->{name} // '';
    ok( $r->{ok} && -f "$d/lazysite/backups/$pkg", '...and a package of it' ) or diag explain $r;
    my $packages = sub { my @p = glob "$d/lazysite/backups/lazysite-site-*.tar.gz"; scalar @p };
    my $snapshots = sub { my @p = glob "$d/lazysite/backups/*prerestore*"; scalar @p };
    my $had       = $packages->();

    no warnings 'once';
    # What the dispatcher sets: where the site is - never who is asking.
    local $Lazysite::Manager::SiteBackup::DOCROOT      = $d;
    local $Lazysite::Manager::SiteBackup::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Domains::DOCROOT         = $d;
    local $Lazysite::Manager::SitePackage::DOCROOT     = $d;
    local $Lazysite::Manager::Upload::DOCROOT          = $d;
    local $Lazysite::Manager::Upload::LAZYSITE_DIR     = "$d/lazysite";
    local $Lazysite::Manager::Backups::DOCROOT         = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR    = "$d/lazysite";
    $Lazysite::Manager::Common::DOCROOT = $d;
    local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
    my $B = 'xYzBoundary205';
    my $mp = "--$B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"p.tar.gz\"\r\n"
        . "Content-Type: application/gzip\r\n\r\nGZBYTES\r\n--$B--\r\n";
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$B";

    my $outside = sub {
        my ($when) = @_;
        my %r = (
            'site-backup-create' => Lazysite::Manager::SiteBackup::action_site_backup_create('mine.example.org'),
            'site-export-primary' => Lazysite::Manager::SiteBackup::action_site_export_primary(),
            'site-backup-inspect' => Lazysite::Manager::SiteBackup::action_site_backup_inspect($pkg),
            'site-backup-delete' => Lazysite::Manager::SiteBackup::action_site_backup_delete($pkg),
            'site-backup-upload' => Lazysite::Manager::SiteBackup::action_site_backup_upload($mp),
            'site-backup-apply' => Lazysite::Manager::SiteBackup::action_site_backup_apply(
                { name => $pkg, host => 'mine.example.org' } ),
        );
        my $out = '';
        {
            open my $h, '>', \$out or die;
            my $old = select $h;
            $r{'site-backup-download'} = Lazysite::Manager::SiteBackup::action_site_backup_download($pkg);
            select $old;
        }
        for my $v ( sort keys %r ) {
            is( $r{$v}{kind} // '', 'forbidden', "$when: $v refuses" ) or diag explain $r{$v};
        }
        ok( !exists $r{'site-backup-inspect'}{manifest}, "$when: ...inspect handing over no manifest" );
        is( $out,           '',   "$when: ...download streaming nothing" );
        is( $packages->(),  $had, "$when: ...no package built, stored or deleted" );
        is( $snapshots->(), 0,    "$when: ...and no safety snapshot taken" );
        ok( Lazysite::Manager::SiteBackup::_package_scope_refusal("$d/lazysite/backups/$pkg"),
            "$when: the backup-list filter hides the package" );
    };
    $outside->('outside a request');

    # boss's own request, as the script sets it for a cookie session.
    $auth_user        = 'boss';
    $token_auth       = 0;
    %token_caps       = ();
    @REQUEST_SCOPES   = ();
    $REQUEST_CONFINED = 0;
    $IS_OPERATOR      = 1;
    $r                = Lazysite::Manager::SiteBackup::action_site_backup_inspect($pkg);
    ok( $r->{ok} && ref $r->{manifest} eq 'HASH', 'with boss\'s context inspect reads the manifest' )
        or diag explain $r;
    $r = Lazysite::Manager::SiteBackup::action_site_backup_upload($mp);
    ok( $r->{ok}, '...and an upload is stored' ) or diag explain $r;
    unlink "$d/lazysite/backups/$r->{name}" if $r->{ok};
    reset_request_context();
    $outside->('reset');
};

# SM944 S27: the domain actions, moved into Manager::Domains after domain-check
# took the established fail-closed pattern (ruled 2026-10-10, "Read Common's
# value"). Outside a request domain-check ran its outbound DNS/TLS probe with
# nobody asking; now it refuses and probes nothing. domains-list and
# _instance_id are unchanged: the list already showed no row there (the domain
# rule's filter) and the instance id is a site fact. With the operator's context
# they answer; after the reset - with Domains' own log copy of the account still
# naming the last request's, as the dispatcher leaves it - the check refuses
# again.
subtest 'the domain actions, loaded outside a request, probe no host' => sub {
    require Lazysite::Manager::Domains;
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/sites";
    mkdir "$d/sites/a";
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\nsite_url: https://primary.example\n"
        . "alias_hosts: a.example\nalias.a.example.content_root: sites/a\n";
    close $fh;
    my $probed = 0;
    no warnings qw(once redefine);
    local *Lazysite::Manager::Domains::domain_check = sub { $probed++; return { ok => 1, host => $_[0] } };
    local *Lazysite::Manager::Domains::instance_public_ips = sub { return () };
    local $Lazysite::Manager::Domains::DOCROOT      = $d;    # what the dispatcher sets
    local $Lazysite::Manager::Domains::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Common::DOCROOT       = $d;
    local $ENV{LAZYSITE_LOG_LEVEL}                  = 'ERROR';

    my $r = Lazysite::Manager::Domains::action_domain_check('a.example');
    is( $r->{kind} // '', 'forbidden', 'domain-check refuses: no account is asking' ) or diag explain $r;
    is( $probed, 0,                    '...and probes nothing' );
    $r = Lazysite::Manager::Domains::action_domains_list();
    ok( $r->{ok}, 'domains-list, unchanged, answers' ) or diag explain $r;
    is_deeply( $r->{domains}, [], '...listing no domain (the domain rule\'s filter)' );
    like( Lazysite::Manager::Domains::_instance_id(), qr/\A[0-9a-f]{32}\z/,
        '_instance_id, unchanged, still answers the install\'s marker' );

    # boss's own request, as the script sets it for a cookie session.
    $auth_user                             = 'boss';
    $token_auth                            = 0;
    %token_caps                            = ();
    @REQUEST_SCOPES                        = ();
    $REQUEST_CONFINED                      = 0;
    $IS_OPERATOR                           = 1;
    $Lazysite::Manager::Domains::auth_user = 'boss';
    $r = Lazysite::Manager::Domains::action_domain_check('a.example');
    ok( $r->{ok} && $probed == 1, 'with boss\'s context the check probes' ) or diag explain $r;
    is_deeply( [ map { $_->{host} } @{ Lazysite::Manager::Domains::action_domains_list()->{domains} } ],
        [ '(default)', 'a.example' ], '...and domains-list lists the domains' );
    reset_request_context();
    is( $Lazysite::Manager::Domains::auth_user, 'boss', 'reset: Domains\' log copy still names boss' );
    is( Lazysite::Manager::Domains::action_domain_check('a.example')->{kind} // '', 'forbidden',
        '...and the check refuses all the same' );
    is( $probed, 1, '...probing nothing' );
    $Lazysite::Manager::Domains::auth_user = '';
};

# SM944 S30: the configuration and language area, moved into Manager::Config
# after config-set took the established fail-closed pattern. Outside a request
# config-set wrote site_name into lazysite.conf with nobody asking; now it
# refuses and the conf is unchanged. config-read, lang-status, the language
# context and the conf reader are site facts and still answer. With boss's
# context the key is set, and after the reset config-set refuses again.
subtest 'the configuration verbs, loaded outside a request, write no setting' => sub {
    require Lazysite::Manager::Config;
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/sites";
    mkdir "$d/sites/fr";
    my $conf = "site_name: T\nsite_url: https://primary.example\nlang: en\nlang_group: g\n"
        . "alias_hosts: fr.example\nalias.fr.example.content_root: sites/fr\n"
        . "alias.fr.example.lang: fr\nalias.fr.example.lang_group: g\n";
    my $read = sub { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return scalar <$fh> };
    {
        open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
        print {$fh} $conf;
        close $fh;
    }
    no warnings 'once';
    local $Lazysite::Manager::Config::DOCROOT      = $d;    # what the dispatcher sets
    local $Lazysite::Manager::Config::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Common::DOCROOT      = $d;
    local $ENV{LAZYSITE_LOG_LEVEL}                 = 'ERROR';

    my $r = Lazysite::Manager::Config::action_config_set( 'site_name', 'Nobody' );
    is( $r->{kind} // '', 'forbidden', 'config-set refuses: no account is asking' ) or diag explain $r;
    is( $read->(), $conf,              '...and the conf is unchanged' );

    # Unchanged: the site facts answer.
    $r = Lazysite::Manager::Config::action_config_read();
    is( $r->{config}{site_name} // '', 'T', 'config-read, unchanged, still answers the site\'s settings' )
        or diag explain $r;
    $r = Lazysite::Manager::Config::action_lang_status();
    ok( $r->{ok} && ( $r->{group} // '' ) eq 'g', 'lang-status, unchanged, still answers the language set' )
        or diag explain $r;
    is( ( Lazysite::Manager::Config::_language_context( {} ) || {} )->{language}{lang_group} // '', 'g',
        '_language_context, unchanged, still answers the set' );
    is( Lazysite::Manager::Config::_conf_text(), $conf, '_conf_text, unchanged, still reads the conf' );

    # boss's own request, as the script sets it.
    $auth_user = 'boss';
    $r         = Lazysite::Manager::Config::action_config_set( 'site_name', 'Boss' );
    ok( $r->{ok}, 'with boss\'s context the key is set' ) or diag explain $r;
    like( $read->(), qr/^site_name: Boss$/m, '...in the conf' );
    reset_request_context();
    is( Lazysite::Manager::Config::action_config_set( 'site_name', 'Nobody' )->{kind} // '', 'forbidden',
        'reset: config-set refuses again' );
    like( $read->(), qr/^site_name: Boss$/m, '...writing nothing' );
};

# SM944 S29: the page PDF area, moved into Manager::PagePdf after page-pdf took
# the established fail-closed pattern. Outside a request it loaded the pandoc
# plugin and converted a public page for account ''; now it refuses before the
# plugin loads. With boss's context the page is streamed - the plugin loaded in
# package main, where its converter is looked for - and after the reset it
# refuses again. md-to-pdf is a stand-in on PATH (no network).
subtest 'the page PDF render, loaded outside a request, converts nothing' => sub {
    require Lazysite::Manager::PagePdf;
    require TestHelper;
    my $d = TestHelper::site_tempdir( plugins => 1 );
    ( my $t = $d ) =~ s{/site/public_html\z}{};
    mkdir "$d/lazysite";
    mkdir "$d/docs";
    mkdir "$t/bin";
    my $spit = sub { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh };
    $spit->( "$d/docs/page.md", "---\ntitle: Page\n---\n\nBody\n" );
    $spit->( "$t/bin/md-to-pdf", "#!/bin/sh\necho ran >> '$t/ran'\nprintf '%%PDF-1.4 stand-in' > out.pdf\nexit 0\n" );
    chmod 0755, "$t/bin/md-to-pdf";
    no warnings 'once';
    local $Lazysite::Manager::PagePdf::DOCROOT = $d;    # what the dispatcher sets
    local $Lazysite::Manager::Common::DOCROOT  = $d;
    local $ENV{PATH}                           = "$t/bin:$ENV{PATH}";
    local $ENV{LAZYSITE_LOG_LEVEL}             = 'ERROR';
    my $pdf = sub {
        open my $save, '>&', \*STDOUT    or die;
        open STDOUT,   '>',  "$t/stdout" or die;
        my $r = Lazysite::Manager::PagePdf::action_page_pdf('docs/page.md');
        open STDOUT, '>&', $save       or die;
        open my $fh, '<',  "$t/stdout" or die;
        local $/;
        return ( $r, scalar <$fh> // '' );
    };

    my ( $r, $printed ) = $pdf->();
    is( $r->{kind} // '', 'forbidden', 'page-pdf refuses: no account is asking' ) or diag explain $r;
    is( $printed, '',                  '...printing nothing' );
    ok( !-e "$t/ran", '...md-to-pdf did not run' );

    # boss's own request, as the script sets it (an unbound cookie manager).
    $auth_user      = 'boss';
    @REQUEST_SCOPES = ();
    ( $r, $printed ) = $pdf->();
    ok( $r->{ok} && $r->{streamed}, 'with boss\'s context the page is streamed' ) or diag explain $r;
    like( $printed, qr/\r\n\r\n%PDF-1\.4 stand-in\z/, '...the PDF, and nothing after it' );
    ok( main->can('convert'), '...its converter loaded in package main' );
    reset_request_context();
    unlink "$t/ran";
    is( ( $pdf->() )[0]{kind} // '', 'forbidden', 'reset: page-pdf refuses again' );
    ok( !-e "$t/ran", '...converting nothing' );
};

done_testing();
