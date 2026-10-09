#!/usr/bin/perl
# SM976: every action addressed by a host or a content root asks the one domain
# rule, Lazysite::Manager::Common::caller_may_reach_domain.
#
# A domain-confined caller reaches only its own domains (ruled 2026-10-09). The
# gaps SM976 closed were all the same gap: an action took a `host`, and nothing
# between the request and the write asked whether the caller reached it - the
# domain verbs, MCP domain_set, the site packages for a cookie manager, the
# navigation on three surfaces. Each was found by probing, one at a time. This
# makes the next one a decision rather than a discovery.
#
# WHAT COUNTS AS ASKING. A sub "asks" when its body names the predicate, its
# refusal (domain_reach_refusal), or another sub that asks - found by closure
# over every sub in the files below, so a wrapper such as
# _refuse_unreachable_domain or Manager::Nav's action_nav_save counts only
# because its own body asks.
#
# WHAT IS CHECKED.
#   1. Control API: every action that declares a `host`, `content_root` or
#      `alias_of` parameter, or whose dispatch branch or handler reads one, asks
#      in its branch or in a sub the branch calls - or is on %EXCEPT below with
#      the reason. An exception that no longer takes a host, or that asks
#      anyway, fails: the list stays closed and true.
#   2. The actions in %MUST_ASK ask too, though no host is named: the
#      listings of per-domain objects, which filter, and the verbs addressed
#      by a site package's name or by the primary.
#   3. MCP: every tool whose inputSchema has a `host` or `content_root`
#      property asks in its block or in a sub the block calls; list_domains too.
#   4. WebDAV: each navigation branch of authorise() asks.
#   5. SM976 R1: every mutating control-API action is declared instance-wide
#      (refused to a domain-confined caller before dispatch, and for its MCP
#      twin), confined by a content path, addressed to a domain as above, or on
#      a closed list with the reason it is not an instance-wide write; and
#      MCP's own mutating tools likewise.
#   6. SM976 F2: every form and brief verb, on the control API and MCP, asks
#      the form or brief rule (Manager::Common::form_reach_refusal /
#      brief_reach_refusal, or the predicate a listing filters by), and the
#      WebDAV form-conf branch asks it too.
#   7. SM976 F1: every write path into lazysite/layouts asks the served-artifact
#      rule (Manager::Common::served_artifact_refusal): the file choke point's
#      guard, which every write verb consults, the multipart upload, and WebDAV.
#   8. SM976 Q15e: every content-write path asks the form-binding rule
#      (Manager::Common::form_bind_refusal) before it writes: the library
#      verbs that write a page, every path-confined mutating control-API action
#      and MCP tool, the site-package apply, and WebDAV's PUT, COPY and MOVE -
#      or is on a closed list with the reason no page newly binds a form.
#
# Files are named relative to the repository root, so the lint judges the same
# set from any checkout - including one under tmp/.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();

# Closed: action => why it does not ask. An entry must take a host and must
# not ask, or the lint fails.
#
# SM976 R4 (ruled 2026-10-09, "Use the shared rule"): EMPTY. data-table-save
# stood here while the data surface kept a reach rule of its own; it asks this
# one now, like every other action.
my %EXCEPT = ();

# No host named, and must ask all the same.
my %MUST_ASK = (
    'domains-list' => 'a row carries the content root, access groups and address of a domain',
    'remap-list'  => "a rule names a domain and where its visitors are sent",
    'backup-list' => 'a site package is a whole domain, and its name carries the host',
    'site-backup-download' => 'addressed by a package, whose manifest names its domain',
    'site-backup-delete'   => 'addressed by a package, whose manifest names its domain',
    'site-export-primary'  => 'packages the primary site',
);

my @FILES = ( 'lazysite-manager-api.pl', 'lazysite-mcp.pl', 'lazysite-dav.pl',
    map { s{\A\Q$root\E/}{}r } sort glob "$root/lib/Lazysite/Manager/*.pm" );

sub slurp { open my $fh, '<', "$root/$_[0]" or die "$_[0]: $!"; local $/; return scalar <$fh> }

# Code only: POD and everything after __END__ go, and so do comments, which
# name the predicate in prose.
sub code_of {
    my ($src) = @_;
    $src =~ s/^__(?:END|DATA)__\b.*//ms;
    $src =~ s/^=[a-zA-Z].*?^=cut\b[^\n]*//gms;
    $src =~ s/^\s*#.*$//gm;
    $src =~ s/(?<=[;{}),])\s*#.*$//gm;
    return $src;
}

my %CODE = map { $_ => code_of( slurp($_) ) } @FILES;

# Every top-level sub, by name.
my %BODY;
for my $f (@FILES) {
    # A one-line sub closes on its own line; any other at the next column-0 brace.
    while ( $CODE{$f} =~ /^sub\s+(\w+)\s*\{(?:([^\n]*)\}[ \t]*$|(.*?)^\})/msg ) {
        $BODY{$1} .= $2 // $3;
    }
}
ok( scalar( keys %BODY ) > 200, 'the subs of the manager surfaces were read' );

# The closure: which subs ask.
my %ASKS = map { $_ => 1 } qw(caller_may_reach_domain domain_reach_refusal);
ok( $BODY{caller_may_reach_domain}, 'the predicate is defined where it is looked for' );
for ( my $grew = 1; $grew; ) {
    $grew = 0;
    for my $s ( keys %BODY ) {
        next if $ASKS{$s};
        my $b = $BODY{$s};
        next unless grep { $b =~ /\b\Q$_\E\b/ } keys %ASKS;
        $ASKS{$s} = $grew = 1;
    }
}
# SM976 F2: the form and brief rules, by the same closure. A form or brief verb
# asks when its code names one of these, or a sub whose body does.
my %FB_ASKS = map { $_ => 1 } qw(form_reach_refusal caller_may_reach_form brief_reach_refusal caller_may_reach_brief);
ok( $BODY{$_}, "$_ is defined where it is looked for" ) for sort keys %FB_ASKS;
for ( my $grew = 1; $grew; ) {
    $grew = 0;
    for my $s ( keys %BODY ) {
        next if $FB_ASKS{$s};
        my $b = $BODY{$s};
        next unless grep { $b =~ /\b\Q$_\E\b/ } keys %FB_ASKS;
        $FB_ASKS{$s} = $grew = 1;
    }
}
sub fb_asks_in {
    my ($text) = @_;
    return 1 if grep { $text =~ /\b\Q$_\E\b/ } keys %FB_ASKS;
    return 0;
}
sub asks_in {
    my ($text) = @_;
    return 1 if grep { $text =~ /\b\Q$_\E\b/ } keys %ASKS;
    return 0;
}
# The subs a piece of code calls by name, with their bodies.
sub with_callees {
    my ($text) = @_;
    my %seen;
    my @called = grep { $BODY{$_} && !$seen{$_}++ } $text =~ /\b(\w+)\s*\(/g;
    return join "\n", $text, map { $BODY{$_} } @called;
}
my $TAKES_HOST = qr/\{\s*['"]?(?:host|content_root|alias_of)['"]?\s*\}/;

# --- 1, 2: the control API --------------------------------------------------
my $api = $CODE{'lazysite-manager-api.pl'};
my %BRANCH;
while ( $api =~ /^(?:if|elsif)\s*\(\s*\$action\s+eq\s+'([a-z0-9_-]+)'\s*\)\s*\{(.*?)(?=^(?:elsif|else)\b|^\}\s*$)/msg ) {
    $BRANCH{$1} .= $2;
}
ok( scalar( keys %BRANCH ) > 100, 'the dispatch branches were read' );

my %ACTION = %Lazysite::ControlApi::Actions::ACTION;
my ( @asked, @missing );
for my $a ( sort keys %ACTION ) {
    my $declared = grep { ( $_->{name} // '' ) =~ /\A(?:host|content_root|alias_of)\z/ }
        @{ $ACTION{$a}{params} || [] };
    my $branch = $BRANCH{$a};
    next unless defined $branch;
    my $code = with_callees($branch);
    next unless $declared || $code =~ $TAKES_HOST || $MUST_ASK{$a};
    if ( $EXCEPT{$a} ) {
        ok( !asks_in($code), "exception $a does not ask the rule (one that does leaves the list)" );
        next;
    }
    if   ( asks_in($code) ) { push @asked,   $a }
    else                    { push @missing, $a }
}
is_deeply( \@missing, [], 'every host-addressed control-API action asks the domain rule' )
    or diag( 'Each of these names a host or a content root and never asks '
        . 'Lazysite::Manager::Common::caller_may_reach_domain (directly or through a sub that '
        . 'does). Ask it, or add the action to %EXCEPT with the reason it may reach any domain.' );
for my $a ( sort keys %EXCEPT ) {
    ok( $BRANCH{$a} && ( with_callees( $BRANCH{$a} ) =~ $TAKES_HOST ), "exception $a still takes a host" );
}
for my $l ( sort keys %MUST_ASK ) {
    ok( ( grep { $_ eq $l } @asked ), "$l asks the rule: $MUST_ASK{$l}" );
}
cmp_ok( scalar @asked, '>=', 20, 'and the set it found is the size it should be' )
    or diag( 'Found: ' . join ', ', @asked );

# --- 3: MCP -------------------------------------------------------------------
my $mcp = $CODE{'lazysite-mcp.pl'};
my ($tools) = $mcp =~ /^my %TOOLS = \((.*?)^\);/ms;
ok( defined $tools, 'the MCP tool table was found' );
my %TOOL;
my @parts = split /^    ([a-z_]+) => \{\s*$/m, ( $tools // '' );
shift @parts;
while ( my ( $name, $block ) = splice @parts, 0, 2 ) { $TOOL{$name} = $block }
ok( scalar( keys %TOOL ) > 50, 'the MCP tools were read' );
my ( @mcp_asked, @mcp_missing );
for my $t ( sort keys %TOOL ) {
    my $props = $TOOL{$t} =~ /\b(?:host|content_root)\s*=>\s*\{/;
    next unless $props || $t eq 'list_domains';
    my $code = with_callees( $TOOL{$t} =~ s/\\&(\w+)/$1(/gr );
    if   ( asks_in($code) ) { push @mcp_asked,   $t }
    else                    { push @mcp_missing, $t }
}
is_deeply( \@mcp_missing, [], 'every MCP tool taking a host or content root asks the domain rule' );
cmp_ok( scalar @mcp_asked, '>=', 9, 'and the set it found is the size it should be' )
    or diag( 'Found: ' . join ', ', @mcp_asked );

# --- 4: WebDAV ------------------------------------------------------------------
my $auth      = $BODY{authorise} // '';
my $nav_gates = () = $auth =~ /manage_nav_for\(\s*\$user\s*\)/g;
my $nav_asks  = () = $auth =~ /return\s+_nav_reach_deny\(/g;
ok( $nav_gates >= 2, 'WebDAV authorise() gates the navigation files' );
is( $nav_asks, $nav_gates, 'and each navigation branch asks the domain rule' );
ok( $ASKS{_nav_reach_deny}, '...through a sub that asks it' );

# --- 5: instance-wide writes (SM976 R1) -----------------------------------------
#
# Ruled 2026-10-09, "Confined = no instance-wide": a domain-confined caller
# changes no instance-wide setting; it acts on its own domains only, through the
# actions addressed to a host. The closed list is `instance_wide => 1` in
# Lazysite::ControlApi::Actions, refused before dispatch on the control API and
# for the MCP twins (Manager::Common::instance_wide_refusal).
#
# EVERY MUTATING ACTION IS ACCOUNTED FOR, so a new one is a decision: it is
# declared instance-wide, or it is confined by a content path (`scoped`), or it
# asks the domain rule (sections 1-2's closure, which reaches the data surface's
# table actions too) or the form or brief rule (section 6's closure), or it
# is on %NOT_INSTANCE_WIDE below with the reason it is not an instance-wide
# write. An entry there that is held any other way fails:
# the list stays closed and true.
my %IW     = Lazysite::ControlApi::Actions::instance_wide();
my %SCOPED = Lazysite::ControlApi::Actions::scoped_actions();
my %MUT    = Lazysite::ControlApi::Actions::mutating();

my $OPERATOR_ONLY = 'needs manage_users on the cookie channel, which makes the caller the '
    . 'operator (Acl::_is_operator), and no token reaches it';
my %NOT_INSTANCE_WIDE = (
    'connector-call' => 'calls a connector an operator configured, which decides who may '
        . '(Connectors::may_call); it changes no setting',
    'key-revoke'              => $OPERATOR_ONLY,
    'session-revoke'          => $OPERATOR_ONLY,
    'user-revoke'             => $OPERATOR_ONLY,
    'notices-seen'            => "the caller's own read cursor (SM281)",
    'preview-grant' => "the caller's own preview cookie; nothing a visitor sees changes (SM649)",
    'preview-clear' => "the caller's own preview cookie; nothing a visitor sees changes (SM649)",
    'start-page-set' => "one account's own setting, through the users tool's actor rule",
    'regenerate-registries' => 'derived output, rebuilt from the content on the next request: '
        . 'the result is the same whoever asks, and no setting changes',
    'site-backup-upload' => 'stores a package; it changes a site only through site-backup-apply, '
        . 'which asks the domain rule',
    'theme-copy' => 'a new theme under a new name, served by nothing until a host-addressed '
        . 'activation (SM749)',
    'theme-upload' => 'installs a theme under a name not already installed (one that exists is '
        . 'refused), served by nothing until activated',
    'theme-delete' => 'a confined caller deletes only a theme it created (SM262 '
        . 'restrict_to_creator, asked below); a theme the primary or any domain serves is '
        . 'refused to everyone (SM177)',
);
my ( @iw_missing, @iw_stale );
for my $a ( sort keys %MUT ) {
    my $asks = $BRANCH{$a} ? ( asks_in( with_callees( $BRANCH{$a} ) ) || fb_asks_in( with_callees( $BRANCH{$a} ) ) ) : 0;
    my $held = $IW{$a} || $SCOPED{$a} || $asks;
    push @iw_stale,   $a if $NOT_INSTANCE_WIDE{$a} && $held;
    push @iw_missing, $a if !$held                 && !$NOT_INSTANCE_WIDE{$a};
}
is_deeply( \@iw_missing, [], 'every mutating action is instance-wide, path-confined, domain-addressed or excepted' )
    or diag( 'Declare it `instance_wide => 1` in Lazysite::ControlApi::Actions if it changes what '
        . 'the whole instance reads, or add it to %NOT_INSTANCE_WIDE with the reason it does not.' );
is_deeply( \@iw_stale, [], 'no %NOT_INSTANCE_WIDE entry is also held another way' );
ok( !grep( { !$MUT{$_} || $NOT_INSTANCE_WIDE{$_} } keys %IW ),
    'every instance-wide action mutates and is not also excepted' );
cmp_ok( scalar( keys %IW ), '>=', 28, 'and the closed list is the size it should be' );

# The gates. The control API refuses before its dispatch chain, reading the
# declaration; MCP refuses the twins, unless a twin taking a host was given one.
my ($gate) = $api =~ /(my %instance_wide = Lazysite::ControlApi::Actions::instance_wide\(\);.*?instance_wide_refusal\(\s*action => \$action\s*\).*?_refuse\()/s;
ok( $gate, 'the control API refuses an instance-wide action through instance_wide_refusal' );
my $first_branch = index( $api, "elsif ( \$action eq 'config-set' )" );
ok( $gate && $first_branch > 0 && index( $api, $gate ) < $first_branch, '...before the dispatch chain' );
ok( $mcp =~ /Lazysite::ControlApi::Actions::instance_wide\(\).*?Lazysite::ControlApi::Actions::mcp_twins\(\).*?instance_wide_refusal\(/s,
    'MCP refuses the twins of the instance-wide actions through instance_wide_refusal' );
my %twin = Lazysite::ControlApi::Actions::mcp_twins();
for my $a ( sort grep { $twin{$_} } keys %IW ) {
    ok( $TOOL{ $twin{$a} }, "$a: its MCP twin $twin{$a} is a tool the gate reaches" );
}

# The three that decide by the caller inside their branch: a confined manager
# deletes only its own themes, and sees and downloads no instance backup.
like( $BRANCH{'theme-delete'} // '', qr/caller_is_confined\(\)/, 'theme-delete restricts a confined caller' );
like( $BRANCH{'backup-list'} // '', qr/caller_is_confined\(\)/, 'backup-list hides instance backups from a confined caller' );
like( $BRANCH{'backup-download'} // '', qr/instance_wide_refusal\(/, 'backup-download refuses them' );

# MCP's own mutating tools (no control-API twin): content-path tools are held by
# the scope pass; the rest are here, closed.
my ($own) = $mcp =~ /^my %OWN_ANNOTATE = \((.*?)^\);/ms;
my %OWN_MUT = map { $_->[0] => 1 } grep { defined $_->[1] && !$_->[1] }
    map { [/^\s*([a-z_]+)\s*=>\s*\[\s*(\d)/] } grep { /=>\s*\[/ } split /\n/, ( $own // '' );
ok( scalar( keys %OWN_MUT ) >= 8, "MCP's own mutating tools were read" );
my %MCP_NOT_INSTANCE_WIDE = (
    create_theme => 'a new theme nothing serves; activate:true makes it the instance\'s, and '
        . 'that asks instance_wide_refusal in its block (below)',
    submit_feedback => 'a report to the operator; nothing on the live site changes',
);
my @mcp_iw_missing = grep {
    !( $TOOL{$_} && $TOOL{$_} =~ /path_aware\s*=>\s*1/ ) && !$MCP_NOT_INSTANCE_WIDE{$_}
} sort keys %OWN_MUT;
is_deeply( \@mcp_iw_missing, [], 'every MCP-only mutating tool is path-confined or accounted for' );
like( $TOOL{create_theme} // '', qr/activate\b.*?instance_wide_refusal\(/s, 'create_theme asks before activating' );

# --- 6: forms and briefs (SM976 F2) ----------------------------------------------
#
# Ruled 2026-10-09, "Confine both": a form verb reaches only a form bound on
# pages inside the caller's scope (an unbound form is the primary's); a brief
# verb only the brief of a page inside it, or of a row of a table that passes
# the data rule. Listings filter. briefs-migrate is instance-wide (section 5).
my @fb_actions = grep { /\A(?:form|brief)/ && !$IW{$_} } sort keys %ACTION;
cmp_ok( scalar @fb_actions, '>=', 16, 'the form and brief actions were found' );
my @fb_missing = grep { !( $BRANCH{$_} && fb_asks_in( with_callees( $BRANCH{$_} ) ) ) } @fb_actions;
is_deeply( \@fb_missing, [], 'every form and brief action on the control API asks the form or brief rule' )
    or diag( 'Ask Lazysite::Manager::Common::form_reach_refusal or brief_reach_refusal in the branch '
        . '(_refuse_unreachable_form / _refuse_unreachable_brief), or filter a listing by the predicate.' );
my @fb_tools = grep { /form|brief/ } sort keys %TOOL;
cmp_ok( scalar @fb_tools, '>=', 12, 'the MCP form and brief tools were found' );
my @fb_tool_missing = grep { !fb_asks_in( with_callees( $TOOL{$_} =~ s/\\&(\w+)/$1(/gr ) ) } @fb_tools;
is_deeply( \@fb_tool_missing, [], 'every MCP form and brief tool asks the form or brief rule' );
like( $auth, qr/return\s+_form_reach_deny\(/, 'WebDAV: the form-conf branch of authorise() asks the form rule' );
ok( $FB_ASKS{_form_reach_deny}, '...through a sub that asks it' );

# --- 7: a theme or layout another site serves (SM976 F1) ---------------------------
#
# Ruled 2026-10-09, "Yes, any served artifact": a domain-confined caller writes a
# theme or layout only if it is unused, or used only by domains inside its scope.
# Every write path into lazysite/layouts asks Manager::Common::served_artifact_refusal:
my $files_pm = $CODE{'lib/Lazysite/Manager/Files.pm'};
like( $BODY{_active_artifact_guard} // '', qr/\bserved_artifact_refusal\(/,
    'the file choke point\'s guard asks the served-artifact rule' );
for my $verb (qw(action_save action_save_binary action_delete action_mkdir action_move action_copy)) {
    like( $BODY{$verb} // '', qr/\b_active_artifact_guard\(/, "$verb consults the guard" );
}
like( $BODY{artifact_write_guard} // '', qr/\b_active_artifact_guard\(/, 'the public guard is the same guard' );
like( $BODY{action_file_upload} // '', qr/\bartifact_write_guard\(/,
    'the multipart upload asks the guard for every file it writes' );
like( $BODY{authorise_layout} // '', qr/served_artifact_refusal\(\s*\$rel,\s*scopes\s*=>/,
    'WebDAV asks the served-artifact rule with the account\'s scopes' );
like( $auth, qr/authorise_layout\(\s*\$rel,\s*\$is_write,\s*\$conf,\s*\$user,\s*\$scope\s*\)/,
    '...and authorise() hands it those scopes' );
like( $mcp, qr/\$Lazysite::Manager::Files::CALLER_SCOPES\s*=/,
    'MCP hands the choke point the grant\'s scopes before a tool runs' );

# --- 8: a page newly binding a form (SM976 Q15e) -----------------------------------
#
# Ruled 2026-10-09, "Refuse new binding": every content-write surface checks the
# written page's front matter `form:` against the caller's reach BEFORE writing;
# a page that newly names a form the caller does not reach is refused. One rule,
# Manager::Common::form_bind_refusal (form_bind_tree_refusal for a write that
# carries existing pages: a move, a copy, a package), asked by closure as the
# sections above ask theirs.
my %BIND_ASKS = map { $_ => 1 } qw(form_bind_refusal form_bind_tree_refusal);
ok( $BODY{$_}, "$_ is defined where it is looked for" ) for sort keys %BIND_ASKS;
like( $BODY{form_bind_tree_refusal} // '', qr/\bform_bind_refusal\(/, 'the tree rule is the page rule, per page' );
for ( my $grew = 1; $grew; ) {
    $grew = 0;
    for my $s ( keys %BODY ) {
        next if $BIND_ASKS{$s};
        my $b = $BODY{$s};
        next unless grep { $b =~ /\b\Q$_\E\b/ } keys %BIND_ASKS;
        $BIND_ASKS{$s} = $grew = 1;
    }
}
sub bind_asks_in {
    my ($text) = @_;
    return ( grep { $text =~ /\b\Q$_\E\b/ } keys %BIND_ASKS ) ? 1 : 0;
}

# 8a. The verbs that write a page, each asking before the statement that writes.
# verb => the write it must come before.
my %WRITER = (
    action_save             => qr/write_file_checked\(\s*\$full/,
    action_save_binary      => qr/open my \$fh, '>', \$tmp/,
    action_move             => qr/\brename\(\s*\$/,
    action_copy             => qr/copy\(\s*\$src_full, \$dst_full\s*\)/,
    action_migrate_to_local => qr/write_file_checked\(\s*\$md_full/,
    action_file_upload      => qr/open my \$fh, '>', \$tmp/,
    package_apply           => qr/_copy_tree\(\s*"\$stage\/content"/,
    do_put                  => qr/rename \$tmp, \$r->\{abs\}/,
    do_copy_move => qr/_remove_entry\(\s*\$dst->\{abs\}\s*\)\s*if \$dst_exists/,
);
for my $v ( sort keys %WRITER ) {
    my $body = $BODY{$v} // '';
    my $w    = $body =~ $WRITER{$v} ? $-[0] : -1;
    my ($ask) = sort { $a <=> $b } grep { defined } map { $body =~ /\b\Q$_\E\s*\(/ ? $-[0] : undef }
        grep { $_ ne $v } sort keys %BIND_ASKS;
    cmp_ok( $w, '>', -1, "$v: its write was found" );
    ok( defined $ask && $ask < $w, "$v asks the form-binding rule before it writes" );
}
ok( $BIND_ASKS{action_git_restore}, 'action_git_restore writes through action_save, which asks' );

# 8b. The control API: every path-confined mutating action, and the actions in
# %MUST_BIND, ask in their branch (or a sub it calls) - or are on the closed list
# with the reason no page newly binds a form. Instance-wide actions are refused
# to every confined caller with a scope (section 5), and a grant naming none
# reaches every form, so the rule has nothing to refuse there.
my %MUST_BIND = (
    'site-backup-apply' => "writes a package's pages under the target root",
);
my %NO_NEW_BINDING = (
    delete       => 'removes a page; removing a binding is unchanged (ruled)',
    mkdir        => 'makes a folder; no page',
    lock         => 'a lock record; no page text',
    'renew-lock' => 'a lock record; no page text',
    unlock       => 'a lock record; no page text',
    'acl-set' => 'an access rule; it moves a page between the docroot and the private store, '
        . 'both of which form_bindings reads, so no page newly names a form',
    'acl-remove'       => 'as acl-set',
    'cache-invalidate' => 'drops rendered output; no page text',
);
my ( @bind_missing, @bind_stale, @bind_seen );
for my $a ( sort grep { ( $SCOPED{$_} && $MUT{$_} && !$IW{$_} ) || $MUST_BIND{$_} } keys %ACTION ) {
    my $asks = $BRANCH{$a} ? bind_asks_in( with_callees( $BRANCH{$a} ) ) : 0;
    push @bind_stale,   $a if $NO_NEW_BINDING{$a} && $asks;
    push @bind_missing, $a if !$asks              && !$NO_NEW_BINDING{$a};
    push @bind_seen,    $a;
}
is_deeply( \@bind_missing, [], 'every content-writing control-API action asks the form-binding rule' )
    or diag( 'Ask Lazysite::Manager::Common::form_bind_refusal before the write (Manager::Files::'
        . 'form_bind_guard / form_bind_tree_guard), or add the action to %NO_NEW_BINDING with the reason '
        . 'no page newly binds a form.' );
is_deeply( \@bind_stale, [], 'no %NO_NEW_BINDING entry asks it anyway' );
cmp_ok( scalar @bind_seen, q(>=), 15, q(and the set it judged is the size it should be) )
    or diag( join q(, ), @bind_seen );
ok( $NO_NEW_BINDING{$_} && $SCOPED{$_} && $MUT{$_}, "$_ on the closed list is a path-confined mutating action" )
    for sort keys %NO_NEW_BINDING;
for my $a (qw(save copy move migrate-to-local git-restore file-upload site-backup-apply)) {
    ok( $BRANCH{$a} && bind_asks_in( with_callees( $BRANCH{$a} ) ), "$a asks the form-binding rule" );
}

# 8c. MCP: every path-aware tool that changes something, and site_apply.
my %MCP_MUST_BIND = ( site_apply => "applies a package's pages through package_apply" );
my %MCP_NO_NEW_BINDING = (
    delete_file      => 'removes a file; removing a binding is unchanged',
    delete_page      => 'removes a page; removing a binding is unchanged',
    invalidate_cache => 'drops rendered output; no page text',
    set_permissions  => 'as acl-set: moves a page between the trees form_bindings reads',
);
my %twin_of = map { $twin{$_} => $_ } grep { defined $twin{$_} } keys %twin;
my ( @mcp_bind_missing, @mcp_bind_stale, @mcp_bind_seen );
for my $t ( sort keys %TOOL ) {
    my $path_aware = $TOOL{$t} =~ /path_aware\s*=>\s*1/;
    my $ro         = $own =~ /^\s*\Q$t\E\s*=>\s*\[\s*(\d)/m ? $1 : undef;
    my $mutates = defined $ro ? !$ro : ( $twin_of{$t} && $MUT{ $twin_of{$t} } ) ? 1 : 0;
    next unless ( $path_aware && $mutates ) || $MCP_MUST_BIND{$t};
    my $asks = bind_asks_in( with_callees( $TOOL{$t} =~ s/\\&(\w+)/$1(/gr ) );
    push @mcp_bind_stale,   $t if $MCP_NO_NEW_BINDING{$t} && $asks;
    push @mcp_bind_missing, $t if !$asks                  && !$MCP_NO_NEW_BINDING{$t};
    push @mcp_bind_seen,    $t;
}
is_deeply( \@mcp_bind_missing, [], 'every content-writing MCP tool asks the form-binding rule' );
is_deeply( \@mcp_bind_stale, [], 'no MCP closed-list entry asks it anyway' );
cmp_ok( scalar @mcp_bind_seen, q(>=), 14, q(and the set it judged is the size it should be) )
    or diag( join q(, ), @mcp_bind_seen );
for my $t ( qw(write_file create_page replace_text upload_file move_file copy_file restore_version
    rename_page create_form site_apply) )
{
    ok( $TOOL{$t} && bind_asks_in( with_callees( $TOOL{$t} =~ s/\\&(\w+)/$1(/gr ) ),
        "MCP $t asks the form-binding rule" );
}
like( $mcp, qr/\$Lazysite::Manager::Files::CALLER_SCOPES\s*=/,
    'MCP hands the choke point the grant\'s scopes, which the binding guards ask with' );
like( $BODY{form_bind_guard} // q(), qr/form_bind_refusal\(.*?scopes\s*=>\s*\$CALLER_SCOPES/s, 'the page guard asks with them' );
like( $BODY{form_bind_tree_guard} // q(), qr/form_bind_tree_refusal\(.*?scopes\s*=>\s*\$CALLER_SCOPES/s, 'and the tree guard' );

# 8d. WebDAV: the write methods that put page text somewhere ask with the
# account's scopes; the rest are closed.
my ($dispatch) = $CODE{'lazysite-dav.pl'} =~ /(my \$code;\s*if\s*\(\s*\$method eq 'PROPPATCH'.*?Method not allowed)/s;
ok( $dispatch, 'the WebDAV write dispatch was found' );
my %DAV_NO_NEW_BINDING = (
    do_proppatch => 'dead properties; no page text',
    do_mkcol     => 'makes a collection; no page',
    do_delete    => 'removes a resource; removing a binding is unchanged',
);
my %dav_seen;
my @dav_verbs = grep { !$dav_seen{$_}++ } ( $dispatch // q() ) =~ /\b(do_\w+)\(/g;
cmp_ok( scalar @dav_verbs, q(>=), 5, 'the WebDAV write verbs were read' );
for my $v (@dav_verbs) {
    if ( $DAV_NO_NEW_BINDING{$v} ) {
        ok( !bind_asks_in( $BODY{$v} // '' ), "WebDAV $v is closed: $DAV_NO_NEW_BINDING{$v}" );
    }
    else { ok( $BIND_ASKS{$v}, "WebDAV $v asks the form-binding rule" ) }
}
like( $BODY{do_put} // '', qr/form_bind_refusal\(\s*\$a\{rel\},\s*\$text,\s*scopes\s*=>/,
    'WebDAV PUT asks with the account\'s scopes' );
like( $BODY{do_copy_move} // '', qr/form_bind_tree_refusal\(\s*\$src->\{abs\},\s*\$drel,\s*scopes\s*=>/,
    'WebDAV COPY and MOVE ask with them, of the destination' );

done_testing();
